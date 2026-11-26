#!/usr/bin/env bash
# work.sh: stale work, for the upkeep survey. Read-only.
#
#   bash work.sh [--repo <owner/repo>]
#
# Prints four sections, each a `## <name>` line, a tab-separated header and
# one row per item (or `skipped: <reason>` when a source can't be read):
#
#   open-prs        every open PR, most idle first: days since its last
#                   activity, draft, GitHub's mergeable and merge state, the
#                   issues it closes (its closing references, plus any
#                   `Closes #<n>` in its body outside code spans and fences,
#                   which a PR into a branch other than the default never
#                   gets as a reference), labels, and
#                   whether a session still drives it (below).
#   branches        branches on GitHub with no open PR (none in the full open
#                   list, as well as among the 20 associations read per
#                   branch): none ever, or only merged or closed ones (a branch
#                   left behind), `prs-truncated` when it has more than 20, and
#                   the open PRs based on each (`base_of`): deleting a branch
#                   an open PR is based on closes that PR.
#   local-branches  branches in the main checkout whose upstream is gone
#                   (pruned, or, when origin is the surveyed repo, an origin
#                   branch GitHub no longer has, which a clone that never
#                   pruned still tracks), or that have no upstream and no PR.
#   worktrees       every linked worktree: its branch, days since its last
#                   commit, uncommitted paths, and its branch's PR.
#
# A PR's session is the best match in `claude agents --json --all` (this
# machine user's sessions) among rows launched from the main checkout or a
# worktree under it, whose name carries `#<n>` or `<n>:` for the PR or an
# issue it closes: `running` (the row has a process), `resumable` (no process,
# and a state of working, blocked, done or stopped), `unplaced` (any other
# state), `none`. Where `claude agents` isn't there or fails, the column reads
# `?` and the section says why.
#
# Needs gh, git and jq. UPKEEP_NOW (epoch seconds) stands in for the clock,
# for tests.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

repo=""
while [ $# -gt 0 ]; do
	case "$1" in
	--repo) [ $# -ge 2 ] || upkeep_die "--repo needs a value"; repo=$2; shift 2 ;;
	*) upkeep_die "unknown argument: $1 (usage: work.sh [--repo <owner/repo>])" ;;
	esac
done
upkeep_need gh git jq
repo=$(upkeep_repo "$repo") || exit 2
default=$(upkeep_default_branch "$repo") || exit 2
now=${UPKEEP_NOW:-$(date +%s)}
main=$(upkeep_main_checkout)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/upkeep-work.XXXXXX") || upkeep_die "can't make a temp directory"
trap 'rm -rf "$tmp"' EXIT

# Every PR's head branch, once, for the branch and worktree sections.
all_prs_ok=yes
gh pr list -R "$repo" --state all -L 5000 --json number,state,headRefName >"$tmp/all-prs.json" 2>"$tmp/err" ||
	all_prs_ok=no

# --- open-prs ---------------------------------------------------------------
sessions_note=""
printf '[]\n' >"$tmp/agents.json"
if [ -z "$main" ]; then
	sessions_note="no main checkout found, so no session matched"
	sessions="?"
elif ! command -v claude >/dev/null 2>&1; then
	sessions_note="claude isn't on PATH"
	sessions="?"
elif claude agents --json --all >"$tmp/agents.raw" 2>/dev/null && jq -e 'type == "array"' "$tmp/agents.raw" >/dev/null 2>&1; then
	cp "$tmp/agents.raw" "$tmp/agents.json"
	sessions=yes
else
	sessions_note="claude agents --json --all failed or printed no list"
	sessions="?"
fi

open_ok=no
if gh pr list -R "$repo" --state open -L 500 \
	--json number,title,isDraft,updatedAt,mergeable,mergeStateStatus,baseRefName,headRefName,labels,closingIssuesReferences,body \
	>"$tmp/open-prs.json" 2>"$tmp/err"; then
	open_ok=yes
	upkeep_section open-prs "pr	idle_days	draft	mergeable	merge_state	base	head	closes	labels	session	title"
	jq -r --argjson now "$now" --arg dir "$main" --arg sessions "$sessions" --slurpfile agents "$tmp/agents.json" '
		def cls: if .pid != null then "running"
			elif ((.state // "") | IN("working", "blocked", "done", "stopped")) then "resumable"
			else "unplaced" end;
		def rank: {"running": 3, "resumable": 2, "unplaced": 1}[.] // 0;
		def names($n): (.name // "") as $s
			| ($s | test("#" + ($n | tostring) + "([^0-9]|$)"))
			  or ($s | test("(^|[^0-9A-Za-z#])" + ($n | tostring) + ":"));
		($agents[0] | map(select(.cwd == $dir or ((.cwd // "") | startswith($dir + "/"))))) as $mine
		| map(. as $pr
			| (([.closingIssuesReferences[]?.number]
			    + [(.body // "") | gsub("```[\\s\\S]*?(```|$)"; "") | gsub("~~~[\\s\\S]*?(~~~|$)"; "") | gsub("`[^`]*`"; "")
			       | scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\\s+#([0-9]+)\\b") | .[0] | tonumber])
			   | unique) as $closes
			| ([$pr.number] + $closes) as $ids
			| ([$mine[] | select(. as $row | any($ids[]; . as $i | $row | names($i))) | cls]
			   | sort_by(rank) | last // "none") as $session
			| {pr: .number,
			   idle: ((($now - (.updatedAt | fromdateiso8601)) / 86400) | floor),
			   draft: (if .isDraft then "draft" else "-" end),
			   mergeable: (.mergeable // "?"), state: (.mergeStateStatus // "?"),
			   base: .baseRefName, head: .headRefName,
			   closes: (if $closes == [] then "-" else ($closes | map("#" + tostring) | join(",")) end),
			   labels: ([.labels[]?.name] | if . == [] then "-" else join(",") end),
			   session: (if $sessions == "yes" then $session else "?" end),
			   title})
		| sort_by(-.idle, .pr)[]
		| [("#" + (.pr | tostring)), .idle, .draft, .mergeable, .state, .base, .head, .closes, .labels, .session, .title]
		| @tsv' "$tmp/open-prs.json"
	[ -n "$sessions_note" ] && printf 'note: session column unknown: %s\n' "$sessions_note"
else
	upkeep_skip open-prs "gh pr list failed: $(head -1 "$tmp/err")"
fi

# --- branches ---------------------------------------------------------------
owner=${repo%%/*}
name=${repo#*/}
if gh api graphql --paginate -f owner="$owner" -f name="$name" -f query='
	query($owner:String!,$name:String!,$endCursor:String){
	  repository(owner:$owner,name:$name){
	    refs(refPrefix:"refs/heads/",first:100,after:$endCursor){
	      pageInfo{ hasNextPage endCursor }
	      nodes{ name target{ ... on Commit{ committedDate } }
	        associatedPullRequests(first:20,states:[OPEN,MERGED,CLOSED]){
	          pageInfo{ hasNextPage } nodes{ number state } } } } } }' \
	>"$tmp/refs.json" 2>"$tmp/err"; then
	upkeep_section branches "branch	idle_days	kind	prs	base_of"
	if [ "$open_ok" = yes ]; then open_file="$tmp/open-prs.json"; else printf 'null\n' >"$tmp/no-open.json"; open_file="$tmp/no-open.json"; fi
	jq -rs --argjson now "$now" --arg default "$default" --slurpfile open "$open_file" '
		. as $pages
		| ($open[0]) as $open
		| [$pages[].data.repository.refs.nodes[]]
		| map(select(.name != $default)
			| (.associatedPullRequests.nodes // []) as $prs
			| select(all($prs[]; .state != "OPEN"))
			# An open PR past the 20 associations read still counts: the full
			# open list is the check.
			| select(.name as $b | $open == null or (any($open[]; .headRefName == $b) | not))
			| {branch: .name,
			   idle: (if .target.committedDate then (($now - (.target.committedDate | fromdateiso8601)) / 86400 | floor) else "?" end),
			   kind: (if (.associatedPullRequests.pageInfo.hasNextPage // false) then "prs-truncated"
			          elif $prs == [] then "no-pr"
			          elif all($prs[]; .state == "MERGED") then "merged-pr"
			          elif any($prs[]; .state == "MERGED") then "merged-and-closed-prs"
			          else "closed-pr" end),
			   prs: ($prs | map("#\(.number) \(.state | ascii_downcase)") | if . == [] then "-" else join(",") end),
			   base_of: (.name as $b | if $open == null then "?" else
			     ([$open[] | select(.baseRefName == $b) | "#\(.number)"] | if . == [] then "-" else join(",") end) end)})
		| sort_by(.kind, (if (.idle | type) == "number" then -.idle else 0 end))[]
		| [.branch, .idle, .kind, .prs, .base_of] | @tsv' "$tmp/refs.json"
	jq -rs '.[].data.repository.refs.nodes[].name' "$tmp/refs.json" >"$tmp/github-branches"
	# GitHub's branches stand for origin's only when origin is this repo.
	origin_repo=$(git remote get-url origin 2>/dev/null |
		sed -E -e 's#^(https?://|ssh://)?([^@/]*@)?github\.com[:/]##' -e 's#\.git$##' -e 's#/+$##' | tr 'A-Z' 'a-z')
	if [ "$origin_repo" = "$(printf '%s' "$repo" | tr 'A-Z' 'a-z')" ]; then github_branches=yes; else github_branches=no; fi
else
	upkeep_skip branches "GitHub GraphQL read failed: $(head -1 "$tmp/err")"
	: >"$tmp/github-branches"
	github_branches=no
fi

# --- local-branches ---------------------------------------------------------
if [ -z "$main" ]; then
	upkeep_skip local-branches "no main checkout found"
else
	git worktree list --porcelain 2>/dev/null | awk '/^branch refs\/heads\// { print substr($0, 19) }' >"$tmp/checked-out"
	git -C "$main" for-each-ref --format='%(refname:short)	%(upstream)	%(upstream:track)	%(committerdate:unix)' refs/heads >"$tmp/local" 2>/dev/null
	upkeep_section local-branches "branch	idle_days	upstream	pr	checked_out"
	if [ "$all_prs_ok" = yes ]; then pr_file="$tmp/all-prs.json"; else printf 'null\n' >"$tmp/no-prs.json"; pr_file="$tmp/no-prs.json"; fi
	# An upstream on origin that GitHub no longer has is gone, even where the
	# clone never pruned its remote-tracking ref.
	jq -Rr --argjson now "$now" --arg default "$default" --slurpfile prs "$pr_file" --rawfile out "$tmp/checked-out" \
		--rawfile gh "$tmp/github-branches" --arg known "$github_branches" '
		($out | split("\n") | map(select(. != ""))) as $co
		| ($gh | split("\n") | map(select(. != ""))) as $on_github
		| split("\t") as [$b, $up, $track, $ct]
		| select($b != $default)
		| (if $prs[0] == null then "?" else
			([$prs[0][] | select(.headRefName == $b)] | sort_by(.state == "OPEN", .number) | last
			 | if . == null then "none" else "#\(.number) \(.state | ascii_downcase)" end) end) as $pr
		| (if $up == "" then "none" elif ($track | test("gone")) then "gone"
		   elif $known == "yes" and ($up | startswith("refs/remotes/origin/"))
		        and (($up | ltrimstr("refs/remotes/origin/")) as $name | any($on_github[]; . == $name) | not)
		   then "gone" else "tracking" end) as $u
		| select($u == "gone" or ($u == "none" and $pr == "none"))
		| [$b, ((($now - ($ct | tonumber)) / 86400) | floor), $u, $pr, (if any($co[]; . == $b) then "yes" else "no" end)]
		| @tsv' "$tmp/local"
	[ "$all_prs_ok" = yes ] || printf 'note: pr column unknown: gh pr list failed\n'
fi

# --- worktrees --------------------------------------------------------------
if [ -z "$main" ]; then
	upkeep_skip worktrees "no main checkout found"
else
	upkeep_section worktrees "path	branch	idle_days	dirty	pr	flags"
	git worktree list --porcelain 2>/dev/null | awk '
		function emit() { if (path != "" && n > 1) printf "%s\t%s\t%s\t%s\n", path, head, branch, flags }
		/^worktree / { emit(); n++; path = substr($0, 10); head = ""; branch = "-"; flags = "" ; next }
		/^HEAD / { head = substr($0, 6); next }
		/^branch refs\/heads\// { branch = substr($0, 19); next }
		/^detached/ { flags = flags "detached," ; next }
		/^locked/ { flags = flags "locked,"; next }
		/^prunable/ { flags = flags "prunable,"; next }
		END { emit() }' >"$tmp/worktrees"
	while IFS='	' read -r wt_path wt_head wt_branch wt_flags; do
		[ -n "$wt_path" ] || continue
		if [ -d "$wt_path" ]; then
			dirty=$(git --no-optional-locks -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
		else
			dirty="?"
			wt_flags="${wt_flags}missing,"
		fi
		ct=$(git -C "$main" log -1 --format=%ct "$wt_head" 2>/dev/null)
		case "$wt_path" in "$main"/*) shown=${wt_path#"$main"/} ;; *) shown=$wt_path ;; esac
		printf '%s\t%s\t%s\t%s\t%s\n' "$shown" "$wt_branch" "${ct:-}" "$dirty" "${wt_flags%,}"
	done <"$tmp/worktrees" >"$tmp/worktree-rows"
	if [ "$all_prs_ok" = yes ]; then pr_file="$tmp/all-prs.json"; else printf 'null\n' >"$tmp/no-prs.json"; pr_file="$tmp/no-prs.json"; fi
	jq -Rr --argjson now "$now" --slurpfile prs "$pr_file" '
		split("\t") as [$p, $b, $ct, $dirty, $flags]
		| (if $prs[0] == null then "?" elif $b == "-" then "-" else
			([$prs[0][] | select(.headRefName == $b)] | sort_by(.state == "OPEN", .number) | last
			 | if . == null then "none" else "#\(.number) \(.state | ascii_downcase)" end) end) as $pr
		| [$p, $b, (if $ct == "" then "?" else ((($now - ($ct | tonumber)) / 86400) | floor) end), $dirty, $pr,
		   (if $flags == "" then "-" else $flags end)]
		| @tsv' "$tmp/worktree-rows"
	[ "$all_prs_ok" = yes ] || printf 'note: pr column unknown: gh pr list failed\n'
fi
