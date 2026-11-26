#!/usr/bin/env bash
# backlog.sh: the open-issue backlog, for the upkeep survey. Read-only.
#
#   bash backlog.sh [--repo <owner/repo>]
#
# Prints two sections, each a `## <name>` line, a tab-separated header and
# one row per item (or `skipped: <reason>`):
#
#   open-issues           every open issue, most idle first: days since its
#                         last activity, its age, comment count, labels, the
#                         PRs that close it (GitHub's closing references, with
#                         their state), other PRs that mention it (another
#                         repo's as `owner/repo#n`), and flags:
#                           merged-but-open  a PR that closes it has merged
#                           open-pr          a PR that closes it is open
#                           mentioned-by-merged  a merged PR of this repo
#                                            mentions it without closing it
#                                            (overtaken?)
#                           no-pr            no PR closes or mentions it
#                           refs-truncated   more than 20 closing PRs or 100
#                                            cross-references, so the lists
#                                            are cut short (never no-pr)
#                           catch-all        its title reads like a holding
#                                            pen (ideas, parked, backlog, ...)
#   possible-duplicates   pairs of open issues whose titles share most of
#                         their words (Jaccard >= 0.34 over words of three or
#                         more letters, scope prefix and stop words dropped,
#                         at least three words shared), most alike first.
#
# Needs gh and jq. Reads GitHub's GraphQL API (one paginated query), so a
# cloud session, whose proxy refuses GraphQL, gets `skipped:` lines.
# UPKEEP_NOW (epoch seconds) stands in for the clock, for tests.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

repo=""
while [ $# -gt 0 ]; do
	case "$1" in
	--repo) [ $# -ge 2 ] || upkeep_die "--repo needs a value"; repo=$2; shift 2 ;;
	*) upkeep_die "unknown argument: $1 (usage: backlog.sh [--repo <owner/repo>])" ;;
	esac
done
upkeep_need gh jq
repo=$(upkeep_repo "$repo") || exit 2
now=${UPKEEP_NOW:-$(date +%s)}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/upkeep-backlog.XXXXXX") || upkeep_die "can't make a temp directory"
trap 'rm -rf "$tmp"' EXIT

if ! gh api graphql --paginate -f owner="${repo%%/*}" -f name="${repo#*/}" -f query='
	query($owner:String!,$name:String!,$endCursor:String){
	  repository(owner:$owner,name:$name){
	    issues(states:OPEN,first:50,after:$endCursor){
	      pageInfo{ hasNextPage endCursor }
	      nodes{ number title createdAt updatedAt
	        labels(first:20){ nodes{ name } }
	        comments{ totalCount }
	        closedByPullRequestsReferences(first:20,includeClosedPrs:true){
	          pageInfo{ hasNextPage }
	          nodes{ number state repository{ nameWithOwner } } }
	        timelineItems(itemTypes:[CROSS_REFERENCED_EVENT],first:100){
	          pageInfo{ hasNextPage }
	          nodes{ ... on CrossReferencedEvent{ source{ __typename
	            ... on PullRequest{ number state repository{ nameWithOwner } } } } } } } } } }' \
	>"$tmp/issues.json" 2>"$tmp/err"; then
	reason="GitHub GraphQL read failed: $(head -1 "$tmp/err")"
	upkeep_skip open-issues "$reason"
	upkeep_skip possible-duplicates "$reason"
	exit 0
fi

jq -s '[.[].data.repository.issues.nodes[]]' "$tmp/issues.json" >"$tmp/nodes.json"

upkeep_section open-issues "issue	idle_days	age_days	comments	labels	closing_prs	other_prs	flags	title"
jq -r --argjson now "$now" --arg repo "$repo" '
	def days($t): (($now - ($t | fromdateiso8601)) / 86400) | floor;
	def where: .repository.nameWithOwner // $repo;
	def mine: where | ascii_downcase == ($repo | ascii_downcase);
	def name: (if mine then "" else where end) + "#\(.number)";
	def prs: map("\(name) \(.state | ascii_downcase)") | if . == [] then "-" else join(",") end;
	map((.closedByPullRequestsReferences.nodes // []) as $closing
		| ((.closedByPullRequestsReferences.pageInfo.hasNextPage // false)
		   or (.timelineItems.pageInfo.hasNextPage // false)) as $cut
		| ([.timelineItems.nodes[]?.source | select(.__typename == "PullRequest")
		    | select(name as $k | any($closing[]; name == $k) | not)]
		   | unique_by(name)) as $other
		| {issue: .number, idle: days(.updatedAt), age: days(.createdAt),
		   comments: .comments.totalCount,
		   labels: ([.labels.nodes[]?.name] | if . == [] then "-" else join(",") end),
		   closing: ($closing | prs), other: ($other | prs),
		   flags: ([
		     (if any($closing[]; .state == "MERGED") then "merged-but-open" else empty end),
		     (if any($closing[]; .state == "OPEN") then "open-pr" else empty end),
		     (if any($other[]; .state == "MERGED" and mine) then "mentioned-by-merged" else empty end),
		     (if $cut then "refs-truncated" elif $closing == [] and $other == [] then "no-pr" else empty end),
		     (if (.title | test("\\b(ideas?|parked|backlog|wish ?list|someday|misc|catch[- ]?all|follow[- ]?ups|parking lot)\\b"; "i"))
		      then "catch-all" else empty end)
		   ] | if . == [] then "-" else join(",") end),
		   title})
	| sort_by(-.idle, .issue)[]
	| ["#\(.issue)", .idle, .age, .comments, .labels, .closing, .other, .flags, .title] | @tsv' "$tmp/nodes.json"

upkeep_section possible-duplicates "issue_a	issue_b	similarity	shared_words	title_a	title_b"
jq -r '
	["the", "and", "for", "with", "from", "into", "that", "this", "when", "its", "not", "are", "has",
	 "have", "but", "can", "all", "any", "one", "use", "add", "make", "let", "via", "per", "out", "own",
	 "new", "now", "too", "also", "only", "each", "than", "then", "them", "they", "their", "what",
	 "which", "who", "why", "how", "does", "don", "doesn", "isn", "won", "should", "would", "could",
	 "instead", "before", "after", "without", "every", "same", "more", "less", "just", "still"] as $stop
	| def words: sub("^[^:]{1,40}:\\s+"; "") | ascii_downcase
		| [scan("[a-z0-9][a-z0-9_.-]*[a-z0-9]")] | map(select(length >= 3 and (. as $w | $stop | index([$w]) | not))) | unique;
	map({n: .number, t: .title, w: (.title | words)}) as $a
	| [range(0; $a | length) as $i | range($i + 1; $a | length) as $j
		| $a[$i] as $x | $a[$j] as $y
		| ([$x.w[] | select(. as $w | $y.w | index([$w]))]) as $shared
		| (($x.w + $y.w) | unique | length) as $union
		| select(($shared | length) >= 3 and $union > 0)
		| {a: $x.n, b: $y.n, s: (($shared | length) / $union), shared: $shared, ta: $x.t, tb: $y.t}
		| select(.s >= 0.34)]
	| sort_by(-.s, .a, .b)[]
	| ["#\(.a)", "#\(.b)", ((.s * 100 | round) / 100), (.shared | join(",")), .ta, .tb] | @tsv' "$tmp/nodes.json"
