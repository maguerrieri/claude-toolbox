#!/usr/bin/env bash
# Tests for skills/upkeep/scripts/hotspots.sh: per-file review fixes, by a
# subject pattern and by the after-the-PR-opened fallback, with review
# threads, restacks and open-PR overlap from stubbed GitHub reads. Runs under
# macOS /bin/bash 3.2 too:
#
#   bash plugins/upkeep/tests/test-hotspots.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../skills/upkeep/scripts/hotspots.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

now=1795000000
export UPKEEP_NOW=$now
ago() { jq -nr --argjson s "$((now - $1 * 86400))" '$s | todate'; }

repo="$tmp/repo"
mkrepo "$repo"
printf 'a\n' >"$repo/a.md"
commit_at "$repo" 200 "[#1] init"
printf 'a2\n' >"$repo/a.md"
printf 'b\n' >"$repo/b.sh"
commit_at "$repo" 20 "[#2] (Claude Code) feat: Add x"
printf 'a3\n' >"$repo/a.md"
commit_at "$repo" 15 "[#2] (CRC; Claude Code) feat: Fix the review finding"
printf 'c\n' >"$repo/c.py"
commit_at "$repo" 10 "[#3] (Claude Code) other: Add c with a subject long enough to be cut short"

mkdir "$tmp/bin" "$tmp/fx"
jq -nc --arg o50 "$(ago 18)" --arg o51 "$(ago 11)" --arg d20 "$(ago 20)" --arg d15 "$(ago 15)" --arg d10 "$(ago 10)" '
	{data: {search: {nodes: [
	  {number: 50, title: "feat: x", createdAt: $o50,
	   files: {nodes: [{path: "a.md"}, {path: "b.sh"}]},
	   reviewThreads: {nodes: [{path: "a.md"}, {path: "a.md"}, {path: "b.sh"}]},
	   timelineItems: {totalCount: 3},
	   commits: {nodes: [
	     {commit: {messageHeadline: "[#2] (Claude Code) feat: Add x", authoredDate: $d20}},
	     {commit: {messageHeadline: "[#2] (CRC; Claude Code) feat: Fix the review finding", authoredDate: $d15}}]}},
	  {}]}}}' >"$tmp/fx/search.json"
jq -nc --arg o51 "$(ago 11)" --arg d10 "$(ago 10)" '
	{data: {search: {nodes: [
	  {number: 51, title: "other: c", createdAt: $o51,
	   files: {nodes: [{path: "c.py"}]}, reviewThreads: {nodes: []}, timelineItems: {totalCount: 1},
	   commits: {nodes: [{commit: {messageHeadline: "[#3] (Claude Code) other: Add c with a subject…", authoredDate: $d10}}]}}]}}}' \
	>>"$tmp/fx/search.json"
printf '%s\n' '[{"number": 60, "files": [{"path": "a.md"}]}, {"number": 61, "files": [{"path": "a.md"}, {"path": "d.md"}]}]' >"$tmp/fx/open.json"

cat >"$tmp/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
case "$*" in
"api graphql --paginate "*) [ "${STUB_FAIL:-}" = graphql ] && { echo "GraphQL is not available" >&2; exit 1; }; cat "$STUB_DIR/search.json" ;;
"pr list -R owner/repo --state open "*) [ "${STUB_FAIL:-}" = open ] && exit 1; cat "$STUB_DIR/open.json" ;;
*) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$tmp/bin/gh"
export STUB_DIR="$tmp/fx"
PATH="$tmp/bin:/usr/bin:/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v git)")"

hot() { # hot <out> [args...]
	out=$1
	shift
	(cd "$repo" && bash "$script" --repo owner/repo --days 90 "$@") >"$out" 2>"$out.err"
	echo $? >"$out.rc"
}
cols() { rows files "$1" | awk -F '\t' -v p="$2" '$7 == p { print $1, $2, $3, $4, $5, $6 }'; }

# --- by subject pattern -----------------------------------------------------
hot "$tmp/pat" --fix-pattern '\(CRC[;)]'
record 0 "pattern run exits 0" "$(cat "$tmp/pat.rc")"
record "1 2 1 2 3 2" "a.md: fix, commits, prs, threads, restacks, open PRs" "$(cols "$tmp/pat" a.md)"
record "0 1 1 1 3 0" "b.sh" "$(cols "$tmp/pat" b.sh)"
record "0 1 1 0 1 0" "c.py" "$(cols "$tmp/pat" c.py)"
record "0 0 0 0 0 1" "d.md: only an open PR touches it" "$(cols "$tmp/pat" d.md)"
record "a.md b.sh c.py d.md" "files ranked by fixes, threads, commits" "$(rows files "$tmp/pat" | cut -f7 | tr '\n' ' ' | sed 's/ $//')"
record "#50	2	1	3	3	feat: x" "PR #50's row" "$(row prs '#50' "$tmp/pat")"
record "#51	1	0	0	1	other: c" "PR #51's row" "$(row prs '#51' "$tmp/pat")"
record "" "the init commit is outside the window" "$(cols "$tmp/pat" a.md | awk '$2 > 2')"

# --- the fallback: commits made after their PR opened ------------------------
hot "$tmp/fb"
record "1 2 1 2 3 2" "a.md: its fix came after PR #50 opened" "$(cols "$tmp/fb" a.md)"
record "1 1 1 0 1 0" "c.py: matched through a cut-short headline" "$(cols "$tmp/fb" c.py)"
record "0" "b.sh: committed before the PR opened" "$(cols "$tmp/fb" b.sh | cut -d ' ' -f1)"
record 1 "PR #51 has one fix" "$(row prs '#51' "$tmp/fb" | col 3)"

# --- degraded reads ---------------------------------------------------------
(cd "$repo" && STUB_FAIL=graphql bash "$script" --repo owner/repo --days 90) >"$tmp/nogql" 2>&1
record "? 2 ? ? ? 2" "no GraphQL, no pattern: fixes and PR columns unknown" "$(cols "$tmp/nogql" a.md)"
record "skipped: GitHub GraphQL read failed" "the prs section skips" "$(sed -n '/^## prs$/{n;n;p;}' "$tmp/nogql")"
(cd "$repo" && STUB_FAIL=graphql bash "$script" --repo owner/repo --days 90 --fix-pattern '\(CRC[;)]') >"$tmp/nogql-pat" 2>&1
record "1 2 ? ? ? 2" "no GraphQL with a pattern: fixes still counted from git" "$(cols "$tmp/nogql-pat" a.md)"
(cd "$repo" && STUB_FAIL=open bash "$script" --repo owner/repo --days 90 --fix-pattern '\(CRC[;)]') >"$tmp/noopen" 2>&1
record "1 2 1 2 3 ?" "open PRs unknown when the list fails" "$(cols "$tmp/noopen" a.md)"

(cd "$repo" && bash "$script" --repo owner/repo --top 2 --fix-pattern '\(CRC[;)]') >"$tmp/top" 2>&1
record 2 "--top limits the files" "$(rows files "$tmp/top" | wc -l | tr -d ' ')"
(cd "$repo" && bash "$script" --repo owner/repo --fix-pattern '') >/dev/null 2>&1
record 2 "an empty pattern is a usage error" "$?"

finish
