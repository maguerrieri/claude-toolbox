#!/usr/bin/env bash
# Tests for skills/upkeep/scripts/work.sh: open PRs with their sessions,
# branches with no open PR, local branches, and worktrees. gh and claude are
# stubs serving fixtures; git is real, on a scratch repo with a remote and two
# worktrees. Runs under macOS /bin/bash 3.2 too:
#
#   bash plugins/upkeep/tests/test-work.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../skills/upkeep/scripts/work.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

now=1795000000
export UPKEEP_NOW=$now
ago() { jq -nr --argjson s "$((now - $1 * 86400))" '$s | todate'; }

# --- the repo: main, a remote, a gone upstream, an orphan, two worktrees ----
repo="$tmp/repo"
mkrepo "$repo"
commit_at "$repo" 50 "init"
git init -q --bare "$tmp/remote.git"
git -C "$repo" remote add origin "$tmp/remote.git"
git -C "$repo" push -q origin main
git -C "$repo" branch gone-branch
git -C "$repo" push -q -u origin gone-branch 2>/dev/null
git -C "$repo" push -q origin --delete gone-branch 2>/dev/null
git -C "$repo" fetch -q --prune origin
# Two branches whose upstream the clone still tracks: one GitHub deleted
# (the clone never pruned it), one GitHub still has.
git -C "$repo" branch pruned-late
git -C "$repo" push -q -u origin pruned-late 2>/dev/null
git -C "$repo" branch still-there
git -C "$repo" push -q -u origin still-there 2>/dev/null
git -C "$repo" branch orphan
git -C "$repo" branch with-pr
git -C "$repo" worktree add -q "$repo/.claude/worktrees/feat-a" -b feat-a 2>/dev/null
git -C "$repo" worktree add -q "$repo/.claude/worktrees/feat-b" -b feat-b 2>/dev/null
printf 'wip\n' >"$repo/.claude/worktrees/feat-b/untracked.txt"

# --- fixtures ---------------------------------------------------------------
mkdir "$tmp/bin" "$tmp/cbin" "$tmp/fx"
cat >"$tmp/fx/all-prs.json" <<'EOF'
[{"number": 5, "state": "MERGED", "headRefName": "feat-a"},
 {"number": 9, "state": "OPEN", "headRefName": "with-pr"},
 {"number": 12, "state": "OPEN", "headRefName": "feat-b-old"}]
EOF
jq -n --arg old "$(ago 40)" --arg new "$(ago 1)" '[
  {number: 12, title: "Second", isDraft: true, updatedAt: $new, mergeable: "MERGEABLE",
   mergeStateStatus: "CLEAN", baseRefName: "main", headRefName: "feat-b-old", labels: [],
   closingIssuesReferences: [],
   body: "Stacked on #9.\n\nFixes #11\n\nExamples: `Closes #77`, and\n\n```text\nFixes #78\n```\n"},
  {number: 9, title: "First\tone", isDraft: false, updatedAt: $old, mergeable: "CONFLICTING",
   mergeStateStatus: "DIRTY", baseRefName: "main", headRefName: "with-pr",
   labels: [{name: "upkeep:keep"}], closingIssuesReferences: [{number: 8}], body: "Closes #8"}
]' >"$tmp/fx/open-prs.json"
# Two GraphQL pages, as --paginate prints them.
jq -nc --arg d "$(ago 30)" '{data: {repository: {refs: {nodes: [
  {name: "main", target: {committedDate: $d}, associatedPullRequests: {nodes: []}},
  {name: "feat-a", target: {committedDate: $d}, associatedPullRequests: {nodes: [{number: 5, state: "MERGED"}]}},
  {name: "stale-x", target: {committedDate: $d}, associatedPullRequests: {nodes: []}}]}}}}' >"$tmp/fx/refs.json"
jq -nc --arg d "$(ago 10)" '{data: {repository: {refs: {nodes: [
  {name: "with-pr", target: {committedDate: $d}, associatedPullRequests: {nodes: [{number: 9, state: "OPEN"}]}},
  {name: "still-there", target: {committedDate: $d}, associatedPullRequests: {nodes: []}},
  {name: "closed-y", target: {committedDate: $d}, associatedPullRequests: {nodes: [{number: 3, state: "CLOSED"}]}}]}}}}' >>"$tmp/fx/refs.json"
jq -n --arg repo "$repo" --arg other "$tmp/elsewhere" '[
  {name: "repo #8: first thing", cwd: $repo, state: "done", startedAt: 1},
  {name: "repo #11: other repo", cwd: $other, state: "working", pid: 123, status: "busy", startedAt: 2},
  {name: "repo 12: second", cwd: ($repo + "/.claude/worktrees/feat-b"), state: "working", pid: 99, status: "busy", startedAt: 3},
  {name: "repo #120: not twelve", cwd: $repo, state: "working", pid: 7, status: "busy", startedAt: 4}
]' >"$tmp/fx/agents.json"

cat >"$tmp/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
case "$*" in
"repo view owner/repo --json defaultBranchRef -q .defaultBranchRef.name") echo main ;;
"pr list -R owner/repo --state all "*) [ "${STUB_FAIL:-}" = all ] && { echo "boom" >&2; exit 1; }; cat "$STUB_DIR/all-prs.json" ;;
"pr list -R owner/repo --state open "*) [ "${STUB_FAIL:-}" = open ] && { echo "HTTP 502" >&2; exit 1; }; cat "$STUB_DIR/open-prs.json" ;;
"api graphql --paginate "*) [ "${STUB_FAIL:-}" = graphql ] && { echo "GraphQL is not available" >&2; exit 1; }; cat "$STUB_DIR/refs.json" ;;
*) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB_EOF
cat >"$tmp/cbin/claude" <<'STUB_EOF'
#!/usr/bin/env bash
[ "$*" = "agents --json --all" ] || { echo "unexpected claude call: $*" >&2; exit 1; }
[ "${STUB_FAIL:-}" = claude ] && { echo "requires an interactive terminal" >&2; exit 1; }
cat "$STUB_DIR/agents.json"
STUB_EOF
chmod +x "$tmp/bin/gh" "$tmp/cbin/claude"
export STUB_DIR="$tmp/fx" UPKEEP_NOW=$now
# A PATH with no real gh or claude on it: the stubs, the system's tools, jq.
base_path="$tmp/bin:/usr/bin:/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v git)")"

run() { # run <out file> [env assignments...]: work.sh from inside the repo
	out=$1
	shift
	(cd "$repo" && env "$@" bash "$script" --repo owner/repo) >"$out" 2>"$out.err"
	echo $? >"$out.rc"
}

# --- a full run -------------------------------------------------------------
run "$tmp/out" PATH="$tmp/cbin:$base_path"
record 0 "exits 0" "$(cat "$tmp/out.rc")"
record "#9 #12" "open PRs most idle first" "$(rows open-prs "$tmp/out" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
r9=$(row open-prs '#9' "$tmp/out")
record 40 "#9 idle days" "$(printf '%s\n' "$r9" | col 2)"
record CONFLICTING "#9 mergeable" "$(printf '%s\n' "$r9" | col 4)"
record '#8' "#9 closes its closing reference" "$(printf '%s\n' "$r9" | col 8)"
record upkeep:keep "#9 labels" "$(printf '%s\n' "$r9" | col 9)"
record resumable "#9 session: a stopped session named for its issue" "$(printf '%s\n' "$r9" | col 10)"
record 'First one' "a tab in a title can't split the row" "$(printf '%s\n' "$r9" | col 11 | sed 's/\\t/ /')"
r12=$(row open-prs '#12' "$tmp/out")
record draft "#12 is a draft" "$(printf '%s\n' "$r12" | col 3)"
record '#11' "#12 closes the issue its body names, not ones in code spans or fences" "$(printf '%s\n' "$r12" | col 8)"
record running "#12 session: a live session in a worktree, named <n>:" "$(printf '%s\n' "$r12" | col 10)"
record "" "no note when sessions were read" "$(grep '^note: session' "$tmp/out")"

record "closed-y:closed-pr feat-a:merged-pr stale-x:no-pr still-there:no-pr" "branches without an open PR, both pages" \
	"$(rows branches "$tmp/out" | awk -F '\t' '{ printf "%s%s:%s", (NR > 1 ? " " : ""), $1, $3 }')"
record 30 "branch idle days" "$(row branches feat-a "$tmp/out" | col 2)"

record "feat-b:none:none:yes gone-branch:gone:none:no orphan:none:none:no pruned-late:gone:none:no" \
	"local branches: gone upstream (pruned, or missing from GitHub), or none and no PR" \
	"$(rows local-branches "$tmp/out" | awk -F '\t' '{ printf "%s%s:%s:%s:%s", (NR > 1 ? " " : ""), $1, $3, $4, $5 }')"

wa=$(row worktrees .claude/worktrees/feat-a "$tmp/out")
record "feat-a 0 #5 merged" "worktree feat-a: clean, its PR merged" "$(printf '%s\n' "$wa" | awk -F '\t' '{ print $2, $4, $5 }')"
record 50 "worktree idle days from its head commit" "$(printf '%s\n' "$wa" | col 3)"
wb=$(row worktrees .claude/worktrees/feat-b "$tmp/out")
record "1 none" "worktree feat-b: one untracked path, no PR" "$(printf '%s\n' "$wb" | awk -F '\t' '{ print $4, $5 }')"
record 2 "the main checkout isn't listed" "$(rows worktrees "$tmp/out" | wc -l | tr -d ' ')"

# --- degraded sources -------------------------------------------------------
if PATH="$base_path" command -v claude >/dev/null 2>&1; then
	record "" "no claude on the test PATH" "$(PATH="$base_path" command -v claude)"
fi
run "$tmp/noclaude" PATH="$base_path"
record "?" "session unknown without claude" "$(row open-prs '#9' "$tmp/noclaude" | col 10)"
record "note: session column unknown: claude isn't on PATH" "a note says why" "$(grep '^note: session' "$tmp/noclaude")"
run "$tmp/badclaude" PATH="$tmp/cbin:$base_path" STUB_FAIL=claude
record "?" "session unknown when the listing fails" "$(row open-prs '#12' "$tmp/badclaude" | col 10)"

run "$tmp/noopen" PATH="$tmp/cbin:$base_path" STUB_FAIL=open
record "skipped: gh pr list failed: HTTP 502" "open PRs skip when gh fails" \
	"$(sed -n '/^## open-prs$/{n;p;}' "$tmp/noopen")"
record "#5 merged" "the other sections still run" "$(row worktrees .claude/worktrees/feat-a "$tmp/noopen" | col 5)"

run "$tmp/nogql" PATH="$tmp/cbin:$base_path" STUB_FAIL=graphql
record "skipped: GitHub GraphQL read failed: GraphQL is not available" "branches skip without GraphQL" \
	"$(sed -n '/^## branches$/{n;p;}' "$tmp/nogql")"
record "" "without GitHub's branch list an unpruned upstream reads as tracking" "$(row local-branches pruned-late "$tmp/nogql")"
record "gone" "a pruned one is still gone" "$(row local-branches gone-branch "$tmp/nogql" | col 3)"

run "$tmp/noall" PATH="$tmp/cbin:$base_path" STUB_FAIL=all
record "?" "worktree PR unknown when the PR list fails" "$(row worktrees .claude/worktrees/feat-a "$tmp/noall" | col 5)"

(cd "$repo" && PATH="$base_path" bash "$script" --repo 'not a repo') >/dev/null 2>&1
record 2 "a bad --repo is a setup error" "$?"

finish
