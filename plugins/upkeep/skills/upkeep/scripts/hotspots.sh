#!/usr/bin/env bash
# hotspots.sh: code hot spots by evidence, for the upkeep survey. Read-only.
#
#   bash hotspots.sh [--repo <owner/repo>] [--ref <ref>] [--days <n>]
#                    [--fix-pattern <ERE>] [--top <n>]
#
# Counts, over the last <n> days (default 90) of the default branch as the
# clone last fetched it (<ref>, default origin/HEAD, else HEAD):
#
#   files   per file, most review fixes first, the top <n> (default 20):
#           fix_commits  commits in the window that fixed review findings
#                        (below), touching the file;
#           commits      every commit in the window touching it;
#           prs          PRs merged in the window that touched it;
#           threads      review threads opened on it in those PRs (repeated
#                        findings land here);
#           restacks     force-pushes of those PRs, summed (restacks, rebases
#                        and rewrites: where conflicts cost the most);
#           open_prs     open PRs touching it now (where the next conflicts
#                        come from).
#   prs     per PR merged in the window, most review fixes first, the top 15:
#           its commits, fix commits, review threads and force-pushes.
#
# A review fix is a commit whose subject matches --fix-pattern, an extended
# regex (a repo whose review-fix commits carry a flag, such as this
# marketplace's `CRC`). Without one, it is a commit its PR's author made after
# the PR opened: matched to the default branch's commits by author date and
# subject, which rebase and fast-forward merges keep (a squash merge leaves
# one commit, so its fixes count in `prs` only).
#
# The PR columns read GitHub's GraphQL API (one paginated search); where that
# fails (a cloud session's proxy refuses GraphQL), they read `?` and a note
# says why. Needs gh, git and jq.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

repo=""
ref=""
days=90
top=20
fix_pattern=""
while [ $# -gt 0 ]; do
	case "$1" in
	--repo) [ $# -ge 2 ] || upkeep_die "--repo needs a value"; repo=$2; shift 2 ;;
	--ref) [ $# -ge 2 ] || upkeep_die "--ref needs a value"; ref=$2; shift 2 ;;
	--days) [ $# -ge 2 ] && upkeep_days_ok "$2" || upkeep_die "--days needs a whole number of days"; days=$2; shift 2 ;;
	--top) [ $# -ge 2 ] && upkeep_days_ok "$2" || upkeep_die "--top needs a whole number"; top=$2; shift 2 ;;
	--fix-pattern) [ $# -ge 2 ] && [ -n "$2" ] || upkeep_die "--fix-pattern needs a regex"; fix_pattern=$2; shift 2 ;;
	*) upkeep_die "unknown argument: $1" ;;
	esac
done
upkeep_need gh git jq awk
repo=$(upkeep_repo "$repo") || exit 2
if [ -z "$ref" ]; then
	ref=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || ref=HEAD
fi
git rev-parse -q --verify "$ref^{commit}" >/dev/null || upkeep_die "not a commit: $ref"
since=$(upkeep_since "$days")
since_day=${since%%T*}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/upkeep-hotspots.XXXXXX") || upkeep_die "can't make a temp directory"
trap 'rm -rf "$tmp"' EXIT
export UPKEEP_FIX="$fix_pattern"
if [ -n "$fix_pattern" ]; then mode="subjects matching $fix_pattern"; else mode="commits made after their PR opened"; fi
printf 'note: read at %s (%s), window since %s; review fixes are %s\n' \
	"$ref" "$(git rev-parse --short "$ref")" "$since" "$mode"

# Commits in the window: one `C <author date>\t<subject>` line each, then
# its files.
TZ=UTC git -c core.quotePath=false log "$ref" --since="$since" --no-merges --date=format-local:%Y-%m-%dT%H:%M:%SZ \
	--format='C %ad	%s' --name-only >"$tmp/log" 2>/dev/null ||
	upkeep_die "git log failed at $ref"

# Merged PRs in the window, from GitHub.
gql=yes
if gh api graphql --paginate -f q="repo:$repo is:pr is:merged merged:>=$since_day" -f query='
	query($q:String!,$endCursor:String){
	  search(query:$q,type:ISSUE,first:20,after:$endCursor){
	    pageInfo{ hasNextPage endCursor }
	    nodes{ ... on PullRequest{ number title createdAt
	      files(first:100){ nodes{ path } }
	      reviewThreads(first:100){ nodes{ path } }
	      timelineItems(itemTypes:[HEAD_REF_FORCE_PUSHED_EVENT]){ totalCount }
	      commits(first:100){ nodes{ commit{ messageHeadline authoredDate } } } } } } }' \
	>"$tmp/prs.json" 2>"$tmp/err"; then
	jq -s '[.[].data.search.nodes[] | select(.number != null)]' "$tmp/prs.json" >"$tmp/nodes.json"
	jq -r '.[] | .number as $n | .files.nodes[]? | [$n, .path] | @tsv' "$tmp/nodes.json" >"$tmp/pr-files"
	jq -r '.[] | .number as $n | .reviewThreads.nodes[]? | select(.path != null) | [$n, .path] | @tsv' "$tmp/nodes.json" >"$tmp/pr-threads"
	jq -r '.[] | [.number, .timelineItems.totalCount, (.reviewThreads.nodes | length), .title] | @tsv' "$tmp/nodes.json" >"$tmp/pr-meta"
	# One row per PR commit: PR, author date, after-open flag, headline (a
	# long subject's headline ends in an ellipsis).
	jq -r '.[] | .number as $n | (.createdAt | fromdateiso8601) as $opened
		| .commits.nodes[]?.commit
		| [$n, .authoredDate, (if (.authoredDate | fromdateiso8601) > $opened then 1 else 0 end), .messageHeadline] | @tsv' \
		"$tmp/nodes.json" >"$tmp/pr-commits"
else
	gql=no
	printf 'note: PR columns unknown: GitHub GraphQL read failed: %s\n' "$(head -1 "$tmp/err")"
	: >"$tmp/pr-files"; : >"$tmp/pr-threads"; : >"$tmp/pr-meta"; : >"$tmp/pr-commits"
fi

if gh pr list -R "$repo" --state open -L 500 --json number,files >"$tmp/open.json" 2>/dev/null; then
	jq -r '.[] | .number as $n | .files[]?.path | [$n, .] | @tsv' "$tmp/open.json" >"$tmp/open-files"
	open_ok=yes
else
	: >"$tmp/open-files"
	open_ok=no
	printf 'note: open_prs unknown: gh pr list failed\n'
fi

# Which of the window's commits are review fixes: by subject with a pattern,
# else by matching a PR commit made after the PR opened.
awk -F '\t' -v gql="$gql" -v commits="$tmp/pr-commits" '
	function isfix(date, subj,   k, h) {
		if (ENVIRON["UPKEEP_FIX"] != "") return subj ~ ENVIRON["UPKEEP_FIX"]
		if (gql != "yes") return -1
		for (k = 1; k <= nfix[date]; k++) {
			h = fix[date, k]; sub(/…$/, "", h)
			if (substr(subj, 1, length(h)) == h) return 1
		}
		return 0
	}
	FILENAME == commits { if ($3 == 1) { nfix[$2]++; fix[$2, nfix[$2]] = $4 } next }
	/^C / { d = substr($1, 3); s = substr($0, length($1) + 2); f = isfix(d, s); next }
	NF { printf "%s\t%s\n", $0, f }' "$tmp/pr-commits" "$tmp/log" >"$tmp/file-commits"

upkeep_section files "fix_commits	commits	prs	threads	restacks	open_prs	path"
awk -F '\t' -v gql="$gql" -v open_ok="$open_ok" -v t="$tmp" '
	FILENAME == t "/pr-meta" { fp[$1] = $2; next }
	FILENAME == t "/pr-files" { if (!(($1, $2) in seen)) { seen[$1, $2] = 1; prs[$2]++; rs[$2] += fp[$1]; all[$2] = 1 } next }
	FILENAME == t "/pr-threads" { th[$2]++; all[$2] = 1; next }
	FILENAME == t "/open-files" { op[$2]++; all[$2] = 1; next }
	{ c[$1]++; all[$1] = 1; if ($2 == 1) fx[$1]++; else if ($2 == -1) unk = 1 }  # file-commits
	END {
		for (p in all)
			printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\n",
				(unk ? "?" : fx[p] + 0), c[p] + 0,
				(gql == "yes" ? prs[p] + 0 : "?"), (gql == "yes" ? th[p] + 0 : "?"),
				(gql == "yes" ? rs[p] + 0 : "?"), (open_ok == "yes" ? op[p] + 0 : "?"), p
	}' "$tmp/pr-meta" "$tmp/pr-files" "$tmp/pr-threads" "$tmp/open-files" "$tmp/file-commits" |
	sort -t '	' -k1,1nr -k4,4nr -k2,2nr -k7,7 | head -n "$top"

upkeep_section prs "pr	commits	fix_commits	threads	restacks	title"
if [ "$gql" = yes ]; then
	awk -F '\t' -v commits="$tmp/pr-commits" '
		FILENAME == commits { n[$1]++; h = $4
			if (ENVIRON["UPKEEP_FIX"] != "") { if (h ~ ENVIRON["UPKEEP_FIX"]) f[$1]++ } else if ($3 == 1) f[$1]++
			next }
		{ printf "#%s\t%d\t%d\t%d\t%d\t%s\n", $1, n[$1] + 0, f[$1] + 0, $3, $2, $4 }' "$tmp/pr-commits" "$tmp/pr-meta" |
		sort -t '	' -k3,3nr -k5,5nr -k1,1 | head -n 15
else
	printf 'skipped: GitHub GraphQL read failed\n'
fi
