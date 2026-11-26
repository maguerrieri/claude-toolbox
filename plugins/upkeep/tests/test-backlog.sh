#!/usr/bin/env bash
# Tests for skills/upkeep/scripts/backlog.sh: the open-issue flags and the
# duplicate pairs. gh is a stub serving two GraphQL pages. Runs under macOS
# /bin/bash 3.2 too:
#
#   bash plugins/upkeep/tests/test-backlog.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../skills/upkeep/scripts/backlog.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

now=1795000000
export UPKEEP_NOW=$now
ago() { jq -nr --argjson s "$((now - $1 * 86400))" '$s | todate'; }

mkdir "$tmp/bin" "$tmp/fx"
issue() { # issue <n> <title> <updated days ago> <created days ago> <closing json> <xref json>
	jq -nc --argjson n "$1" --arg t "$2" --arg u "$(ago "$3")" --arg c "$(ago "$4")" \
		--argjson closing "$5" --argjson xref "$6" '{number: $n, title: $t, createdAt: $c, updatedAt: $u,
		labels: {nodes: []}, comments: {totalCount: 2},
		closedByPullRequestsReferences: {nodes: $closing},
		timelineItems: {nodes: ($xref | map({source: .}))}}'
}
{
	jq -nc --argjson nodes "[$(issue 1 "Parked ideas: misc things to try" 100 120 '[]' '[]'),
		$(issue 2 "merged but open" 5 30 '[{"number":10,"state":"MERGED"}]' '[{"__typename":"PullRequest","number":10,"state":"MERGED"},{"__typename":"PullRequest","number":11,"state":"OPEN"}]'),
		$(issue 3 "has an open PR" 3 3 '[{"number":12,"state":"OPEN"}]' '[{"__typename":"Issue"}]')]" \
		'{data: {repository: {issues: {nodes: $nodes}}}}'
	jq -nc --argjson nodes "[$(issue 4 "overtaken by other work" 20 40 '[]' '[{"__typename":"PullRequest","number":13,"state":"MERGED"},{"__typename":"PullRequest","number":13,"state":"MERGED"}]'),
		$(issue 5 "ticket-workflow: Restack stacked children after the parent merges" 9 9 '[]' '[]'),
		$(issue 6 "spawn: restack stacked children once a parent merges" 8 8 '[]' '[]'),
		$(issue 7 "spawn: children of a parent session" 7 7 '[]' '[]'),
		$(issue 8 "only a PR in another repo mentions it" 2 2 '[]' '[{"__typename":"PullRequest","number":13,"state":"MERGED","repository":{"nameWithOwner":"o/other"}}]')]" \
		'{data: {repository: {issues: {nodes: $nodes}}}}'
} >"$tmp/fx/issues.json"

cat >"$tmp/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
case "$*" in
"api graphql --paginate "*) [ -n "${STUB_FAIL:-}" ] && { echo "GraphQL is not available" >&2; exit 1; }; cat "$STUB_DIR/issues.json" ;;
*) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$tmp/bin/gh"
export STUB_DIR="$tmp/fx"
tools_dir "$tmp/tools"
PATH="$tmp/bin:$tmp/tools:/usr/bin:/bin"

bash "$script" --repo owner/repo >"$tmp/out" 2>"$tmp/err"
record 0 "exits 0" "$?"
record "#1 #4 #5 #6 #7 #2 #3 #8" "issues most idle first, both pages" "$(rows open-issues "$tmp/out" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
record "no-pr,catch-all" "#1 flags" "$(row open-issues '#1' "$tmp/out" | col 8)"
record "100 120 2" "#1 idle, age, comments" "$(row open-issues '#1' "$tmp/out" | awk -F '\t' '{ print $2, $3, $4 }')"
record "merged-but-open" "#2 flags" "$(row open-issues '#2' "$tmp/out" | col 8)"
record "#10 merged" "#2 closing PRs" "$(row open-issues '#2' "$tmp/out" | col 6)"
record "#11 open" "#2 other PRs leave out the closing one" "$(row open-issues '#2' "$tmp/out" | col 7)"
record "open-pr" "#3 flags (an issue's cross-reference isn't a PR)" "$(row open-issues '#3' "$tmp/out" | col 8)"
record "-" "#3 has no other PRs" "$(row open-issues '#3' "$tmp/out" | col 7)"
record "mentioned-by-merged" "#4 flags" "$(row open-issues '#4' "$tmp/out" | col 8)"
record "#13 merged" "#4 other PRs, once each" "$(row open-issues '#4' "$tmp/out" | col 7)"
record "o/other#13 merged" "#8: another repo's PR is named with its repo" "$(row open-issues '#8' "$tmp/out" | col 7)"
record "-" "#8: and sets no flag (it isn't this repo's work)" "$(row open-issues '#8' "$tmp/out" | col 8)"

record "#5 #6" "the one duplicate pair" "$(rows possible-duplicates "$tmp/out" | awk -F '\t' '{ print $1, $2 }')"
record "children,merges,parent,restack,stacked" "its shared words, scope prefixes dropped" \
	"$(rows possible-duplicates "$tmp/out" | col 4)"

STUB_FAIL=1 bash "$script" --repo owner/repo >"$tmp/fail" 2>&1
record 0 "a failed read still exits 0" "$?"
record 2 "both sections say they skipped" "$(grep -c '^skipped: GitHub GraphQL read failed: GraphQL is not available$' "$tmp/fail")"

bash "$script" --repo owner/repo --bogus >/dev/null 2>&1
record 2 "an unknown argument is a usage error" "$?"

finish
