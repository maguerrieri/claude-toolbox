#!/usr/bin/env bash
# check-evidence.sh unit test (software-factory design, item 1b).
#
# Drives the FINISH gate through a fake `gh` (fixtures/check-evidence/bin/gh)
# that serves the reads from fixture JSON. Every case starts from the `green`
# fixture set — a PR that satisfies all six rules — and patches one fact with
# jq, then asserts the gate's exit status AND that the FAIL line names the
# rule that should have fired, so a case cannot pass by failing for an
# unrelated reason. Covers the spec's list (green + complete, red optional
# check, unresolved thread, PR closing two issues / a different issue,
# missing label, two risk labels, unknown risk name, risk:high without the
# flag, missing block, wrong schema, placeholder tests, non-numeric
# wall_clock_min) plus the issue's rerun-green case, pagination, legacy
# statuses, the rollup cross-check, every high-risk approval shape, and the
# usage/API-error exits. (`/spawn-epic … --confirm-high` refused is item 7b's
# launcher convention, not this script's.)
#
# Stdlib only: bash, jq, git. Run from anywhere:
#   bash plugins/ticket-workflow/tests/test-check-evidence.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../scripts/check-evidence.sh"
fixtures="$here/fixtures/check-evidence"
green="$fixtures/green"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cp "$fixtures/bin/gh" "$work/bin/gh"
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"

failures=0 cases=0
ok() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$((failures + 1)); }

# --- harness ---------------------------------------------------------------------
case_dir=''
new_case() { # <name> — a fresh copy of the green fixtures in $case_dir
	case_dir="$work/case-$1"
	rm -rf "$case_dir"
	cp -R "$green" "$case_dir"
	cases=$((cases + 1))
}
patch() { # <fixture file, relative to the case> <jq filter> [jq args…]
	local file="$case_dir/$1" tmp
	shift
	tmp=$(mktemp)
	jq "$@" "$file" >"$tmp" && mv "$tmp" "$file"
}
set_body() { # <markdown> — replace the PR body
	patch pull.json --arg b "$1" '.body = $b'
}
out='' status=0
run_gate() { # <script args…>; sets $out and $status
	set +e
	out=$(cd "$work" && FAKE_GH_FIXTURES="$case_dir" FAKE_GH_LOG="$case_dir/gh.log" bash "$script" "$@" 2>&1)
	status=$?
	set -e
}
expect_pass() { # <description> <script args…>
	local desc=$1
	shift
	run_gate "$@"
	if [ "$status" -eq 0 ] && [[ $out == *"PASS: "* ]] && [[ $out != *"FAIL - "* ]]; then ok "$desc"; else fail "$desc (exit $status)"; printf '%s\n' "$out" | sed 's/^/       /'; fi
}
expect_refuse() { # <description> <expected FAIL substring> <script args…>
	local desc=$1 expected=$2
	shift 2
	run_gate "$@"
	if [ "$status" -eq 1 ] && [[ $out == *"FAIL - "*"$expected"* ]] && [[ $out == *"REFUSED: "* ]]; then ok "$desc"; else fail "$desc (exit $status; wanted a FAIL line containing '$expected')"; printf '%s\n' "$out" | sed 's/^/       /'; fi
}
expect_error() { # <description> <expected stderr substring> <script args…>
	local desc=$1 expected=$2
	shift 2
	run_gate "$@"
	if [ "$status" -eq 2 ] && [[ $out == *"$expected"* ]]; then ok "$desc"; else fail "$desc (exit $status; wanted '$expected')"; printf '%s\n' "$out" | sed 's/^/       /'; fi
}
expect_output() { # <description> <substring> — on the last run
	if [[ $out == *"$2"* ]]; then ok "$1"; else fail "$1 (no '$2' in output)"; fi
}

HEAD=$(jq -r '.head.sha' "$green/pull.json")
OLD=fedcba9876543210fedcba9876543210fedcba98
# A check run / status / review / rollup node, for patches.
run() { # <id> <name> <suite> <status> <conclusion>
	jq -nc --argjson id "$1" --arg n "$2" --argjson s "$3" --arg st "$4" --arg c "$5" \
		'{id: $id, name: $n, status: $st, conclusion: (if $c == "null" then null else $c end), app: {slug: "github-actions"}, check_suite: {id: $s}}'
}
rollup_run() { # <name> <suite> <databaseId> [<status> <conclusion>]
	jq -nc --arg n "$1" --argjson s "$2" --argjson id "$3" --arg st "${4:-COMPLETED}" --arg c "${5:-SUCCESS}" \
		'{__typename: "CheckRun", name: $n, status: $st, conclusion: (if $c == "null" then null else $c end), databaseId: $id, checkSuite: {databaseId: $s}}'
}
ROLLUP='.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup'
CLOSING='.data.repository.pullRequest.closingIssuesReferences'

review() { # <login> <state> <sha> <submittedAt>
	jq -nc --arg l "$1" --arg s "$2" --arg c "$3" --arg t "$4" '{state: $s, author: {login: $l}, commit: {oid: $c}, submittedAt: $t}'
}
EVIDENCE_BLOCK=$(awk '/^```json$/{f=1;next} /^```$/{f=0} f' <<<"$(jq -r .body "$green/pull.json")")
body_with() { # <jq filter over the evidence object> — a full PR body with that block
	printf '## Summary\n- x\n\n## Evidence\n```json\n%s\n```\n\nCloses #42\n' "$(printf '%s' "$EVIDENCE_BLOCK" | jq "$1")"
}

# --- green + complete ----------------------------------------------------------------
new_case green
expect_pass "green + complete passes" 7 42 --repo o/r
for rule in "1 check github-actions/check" "1 statusCheckRollup on head: SUCCESS" "1 statusCheckRollup contexts are all in the head-SHA read" "2 review threads: none unresolved" "3 closing references: exactly #42" "4 issue #42 risk label: risk:normal" "6 evidence block: well-formed" "6 context_reads path is in the head tree: AGENTS.md"; do
	expect_output "green: reports '$rule'" "ok   - $rule"
done
if [[ $out != *"- 5 "* ]]; then ok "green: rule 5 is not evaluated on risk:normal"; else fail "green: rule 5 is not evaluated on risk:normal"; fi
if grep -q '^api -X\|^api --method' "$case_dir/gh.log"; then fail "gate never writes"; else ok "gate never writes (no -X/--method in the gh log)"; fi
if grep -q 'check-runs?filter=all' "$case_dir/gh.log"; then ok "check runs are read with filter=all"; else fail "check runs are read with filter=all"; fi
if grep -q -- "--paginate repos/o/r/commits/$HEAD/check-runs" "$case_dir/gh.log" && grep -q -- '--paginate graphql.*ReviewThreads' "$case_dir/gh.log" && grep -q -- '--paginate graphql.*ClosingRefs' "$case_dir/gh.log" && grep -q -- '--paginate graphql.*RollupContexts' "$case_dir/gh.log"; then ok "list reads are paginated"; else fail "list reads are paginated"; fi
# gh with a --repo derived from the git remote
new_case remote
git -C "$case_dir" init -q && git -C "$case_dir" remote add origin git@github.com:o/r.git
if (cd "$case_dir" && FAKE_GH_FIXTURES="$case_dir" bash "$script" 7 42 >/dev/null 2>&1); then ok "repo derived from an ssh origin remote"; else fail "repo derived from an ssh origin remote"; fi
git -C "$case_dir" remote set-url origin https://github.com/o/r.git
if (cd "$case_dir" && FAKE_GH_FIXTURES="$case_dir" bash "$script" '#7' '#42' >/dev/null 2>&1); then ok "repo derived from an https origin remote; # prefixes stripped"; else fail "repo derived from an https origin remote; # prefixes stripped"; fi
git -C "$case_dir" remote set-url origin ssh://git@github.com:22/o/r.git
if (cd "$case_dir" && FAKE_GH_FIXTURES="$case_dir" bash "$script" 7 42 >/dev/null 2>&1); then ok "repo derived from an ssh:// origin remote carrying a port"; else fail "repo derived from an ssh:// origin remote carrying a port"; fi
# A non-GitHub origin must never be gated as the GitHub repo of the same name.
for bad_remote in git@gitlab.com:o/r.git https://gitlab.com/o/r.git ssh://git@git.example.com/o/r.git; do
	git -C "$case_dir" remote set-url origin "$bad_remote"
	set +e
	out=$(cd "$case_dir" && FAKE_GH_FIXTURES="$case_dir" bash "$script" 7 42 2>&1)
	status=$?
	set -e
	if [ "$status" -eq 2 ] && [[ $out == *"origin is not on github.com"* ]]; then ok "a non-GitHub origin ($bad_remote) refuses with exit 2"; else fail "a non-GitHub origin ($bad_remote) refuses with exit 2 (exit $status: $out)"; fi
done
new_case repo-casing
expect_pass "--repo in a different case than GitHub's canonical spelling passes" 7 42 --repo O/R
expect_output "repo-casing: the canonical spelling is used" "check-evidence: o/r PR #7"
# CRLF bodies (edited in the GitHub web UI) parse the same
new_case crlf
patch pull.json '.body |= gsub("\n"; "\r\n")'
expect_pass "a CRLF PR body passes" 7 42 --repo o/r

# --- rule 1: checks ----------------------------------------------------------------------
new_case rerun-green
patch check-runs.json --argjson r "$(run 2999 test 92 completed failure)" '.check_runs += [$r]'
expect_pass "a rerun-green latest attempt passes (older red attempt of the same context superseded)" 7 42 --repo o/r
expect_output "rerun-green: the superseded attempt is noted" "1 older attempt(s) superseded"
new_case rerun-red
patch check-runs.json --argjson r "$(run 3999 test 92 completed failure)" '.check_runs += [$r]'
expect_refuse "an older green attempt does not cover a newer red one" "1 check github-actions/test [suite 92]: failure" 7 42 --repo o/r
new_case red-optional
patch check-runs.json '(.check_runs[] | select(.id == 3003) | .conclusion) = "failure"'
patch graphql/PrGate.json '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state = "FAILURE"'
expect_refuse "a red optional check refuses" "1 check github-actions/check [suite 93]: failure" 7 42 --repo o/r
new_case pending
patch check-runs.json '(.check_runs[] | select(.id == 3003)) |= (.status = "in_progress" | .conclusion = null)'
patch graphql/PrGate.json '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state = "PENDING"'
expect_refuse "a pending check refuses" "1 check github-actions/check [suite 93]: in_progress" 7 42 --repo o/r
new_case skipped
patch check-runs.json '(.check_runs[] | select(.id == 3003) | .conclusion) = "skipped"'
expect_refuse "a skipped conclusion is not success" "[suite 93]: skipped" 7 42 --repo o/r
new_case empty
patch check-runs.json '.check_runs = [] | .total_count = 0'
patch graphql/RollupContexts.json "$ROLLUP = null"
patch graphql/PrGate.json '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup = null'
expect_refuse "an empty check set refuses (never vacuously green)" "1 checks: no check runs or statuses on head" 7 42 --repo o/r
new_case status-red
patch statuses.json --arg h "$HEAD" '. + [{id: 501, context: "ci/legacy", state: "failure"}]'
patch graphql/RollupContexts.json "$ROLLUP.contexts.nodes += [{__typename: \"StatusContext\", context: \"ci/legacy\", state: \"FAILURE\"}]"
patch graphql/PrGate.json '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state = "FAILURE"'
expect_refuse "a red commit status (legacy Status API) refuses" "1 status ci/legacy: failure" 7 42 --repo o/r
new_case status-rerun-green
patch statuses.json '. + [{id: 501, context: "ci/legacy", state: "failure"}, {id: 502, context: "ci/legacy", state: "success"}]'
patch graphql/RollupContexts.json "$ROLLUP.contexts.nodes += [{__typename: \"StatusContext\", context: \"ci/legacy\", state: \"SUCCESS\"}]"
expect_pass "a commit status whose newest state is success passes" 7 42 --repo o/r
new_case rollup-state
patch graphql/PrGate.json '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state = "FAILURE"'
expect_refuse "a non-SUCCESS statusCheckRollup refuses even when the direct read is green" "1 statusCheckRollup on head: FAILURE" 7 42 --repo o/r
new_case rollup-mismatch
patch graphql/RollupContexts.json --argjson r "$(rollup_run extra-workflow 99 3009)" "$ROLLUP.contexts.nodes += [\$r]"
expect_refuse "a rollup context the head-SHA read did not see refuses" "1 statusCheckRollup lists context(s) the head-SHA read did not see: check:99/extra-workflow" 7 42 --repo o/r
new_case rollup-duplicate-name
patch graphql/RollupContexts.json --argjson r "$(rollup_run test 99 3009)" "$ROLLUP.contexts.nodes += [\$r]"
expect_refuse "a rollup context sharing a name with a read one but in another suite refuses (identity is suite + name, not name)" "did not see: check:99/test" 7 42 --repo o/r
new_case rollup-later-red
patch graphql/RollupContexts.json "($ROLLUP.contexts.nodes[] | select(.databaseId == 3002) | .conclusion) = \"FAILURE\""
expect_refuse "a rollup context that turned red after the direct read refuses" "1 statusCheckRollup check test [suite 92]: FAILURE" 7 42 --repo o/r
new_case rollup-later-pending
patch graphql/RollupContexts.json "($ROLLUP.contexts.nodes[] | select(.databaseId == 3002)) |= (.status = \"IN_PROGRESS\" | .conclusion = null)"
expect_refuse "a rollup context re-running after the direct read refuses" "1 statusCheckRollup check test [suite 92]: IN_PROGRESS" 7 42 --repo o/r
new_case rollup-rerun-green
patch graphql/RollupContexts.json --argjson r "$(rollup_run test 92 2999 COMPLETED FAILURE)" "$ROLLUP.contexts.nodes += [\$r]"
expect_pass "an older red attempt listed in the rollup beside its newer green attempt passes" 7 42 --repo o/r
new_case rollup-status-red
patch statuses.json '. + [{id: 501, context: "ci/legacy", state: "success"}]'
patch graphql/RollupContexts.json "$ROLLUP.contexts.nodes += [{__typename: \"StatusContext\", context: \"ci/legacy\", state: \"FAILURE\"}]"
expect_refuse "a rollup status context that is not SUCCESS refuses" "1 statusCheckRollup status ci/legacy: FAILURE" 7 42 --repo o/r
new_case read-extra
patch check-runs.json --argjson r "$(run 3004 copilot-pull-request-reviewer 94 completed success)" '.check_runs += [$r]'
expect_pass "a green context the rollup does not list passes (the read is the superset)" 7 42 --repo o/r
expect_output "read-extra: the extra context is noted" "note - 1 head-SHA read saw context(s) the rollup does not list (each still held to success): check:94/copilot-pull-request-reviewer"
new_case read-extra-red
patch check-runs.json --argjson r "$(run 3004 copilot-pull-request-reviewer 94 in_progress null)" '.check_runs += [$r]'
expect_refuse "a non-green context the rollup does not list still refuses" "1 check github-actions/copilot-pull-request-reviewer [suite 94]: in_progress" 7 42 --repo o/r
new_case paginated-red
patch check-runs.json '.check_runs = .check_runs[0:2]'
jq -nc --argjson r "$(run 3001 test 91 completed failure)" '{total_count: 3, check_runs: [$r]}' >"$case_dir/check-runs.page2.json"
patch graphql/PrGate.json '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state = "FAILURE"'
expect_refuse "a red check on page 2 of the check-runs list refuses" "1 check github-actions/test [suite 91]: failure" 7 42 --repo o/r
new_case body-claims-green
patch check-runs.json '(.check_runs[] | select(.id == 3003) | .conclusion) = "failure"'
set_body "$(printf 'CI: all green, checks passed.\n\n%s' "$(jq -r .body "$green/pull.json")")"
expect_refuse "a body claiming green while a check is red refuses (the body is never consulted for state)" "[suite 93]: failure" 7 42 --repo o/r

# --- rule 2: review threads ----------------------------------------------------------------
new_case unresolved
patch graphql/ReviewThreads.json '.data.repository.pullRequest.reviewThreads.nodes += [{id: "PRRT_2", isResolved: false, path: "src/a.sh", comments: {nodes: [{author: {login: "copilot-pull-request-reviewer"}, body: "quote this"}]}}]'
expect_refuse "an unresolved review thread refuses" "2 unresolved review thread on src/a.sh by copilot-pull-request-reviewer: quote this" 7 42 --repo o/r
new_case unresolved-page2
patch graphql/ReviewThreads.json '.data.repository.pullRequest.reviewThreads.pageInfo = {hasNextPage: true, endCursor: "c1"}'
jq -n '{data: {repository: {pullRequest: {reviewThreads: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [{id: "PRRT_9", isResolved: false, path: null, comments: {nodes: []}}]}}}}}' >"$case_dir/graphql/ReviewThreads.page2.json"
expect_refuse "an unresolved thread on page 2 refuses" "2 unresolved review thread on <no file>" 7 42 --repo o/r

# --- rule 3: closing references -------------------------------------------------------------
new_case closes-two
patch graphql/ClosingRefs.json "$CLOSING.nodes += [{number: 43, repository: {nameWithOwner: \"o/r\"}}]"
expect_refuse "a PR closing two issues refuses" "3 closing references: expected exactly o/r#42, got 2: o/r#42, o/r#43" 7 42 --repo o/r
new_case closes-other
patch graphql/ClosingRefs.json "$CLOSING.nodes[0].number = 43"
expect_refuse "a PR closing a different issue refuses" "3 closing references: expected exactly o/r#42, got 1: o/r#43" 7 42 --repo o/r
new_case closes-none
patch graphql/ClosingRefs.json "$CLOSING.nodes = []"
expect_refuse "a PR closing nothing refuses" "3 closing references: none" 7 42 --repo o/r
new_case closes-cross-repo
patch graphql/ClosingRefs.json "$CLOSING.nodes[0].repository.nameWithOwner = \"o/other\""
expect_refuse "a closing reference to #42 in another repo refuses" "3 closing references: expected exactly o/r#42, got 1: o/other#42" 7 42 --repo o/r
new_case closes-page2
patch graphql/ClosingRefs.json "$CLOSING.pageInfo = {hasNextPage: true, endCursor: \"c1\"}"
jq -n '{data: {repository: {pullRequest: {closingIssuesReferences: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [{number: 43, repository: {nameWithOwner: "o/r"}}]}}}}}' >"$case_dir/graphql/ClosingRefs.page2.json"
expect_refuse "a second closing reference on page 2 refuses" "got 2: o/r#42, o/r#43" 7 42 --repo o/r

# --- rule 4: risk label ---------------------------------------------------------------------
new_case no-label
patch issue-labels.json '[]'
expect_refuse "a missing risk label refuses" "4 issue #42 has no risk:* label" 7 42 --repo o/r
new_case two-labels
patch issue-labels.json '. + [{name: "risk:high"}]'
expect_refuse "two risk labels refuse" "4 issue #42 must carry exactly one of risk:docs, risk:low, risk:normal, risk:high; has risk:high, risk:normal" 7 42 --repo o/r
new_case unknown-label
patch issue-labels.json '[{name: "risk:critical"}]'
expect_refuse "an unknown risk: name refuses" "has risk:critical" 7 42 --repo o/r
new_case label-page2
patch issue-labels.json '[{name: "bug"}]'
echo '[{"name": "risk:docs"}]' >"$case_dir/issue-labels.page2.json"
expect_pass "a risk label on page 2 of the label list is seen" 7 42 --repo o/r
new_case issue-is-pr
patch issue.json '.pull_request = {url: "https://api.github.com/repos/o/r/pulls/42"}'
expect_refuse "an <issue> that is a pull request refuses" "4 #42 is a pull request" 7 42 --repo o/r

# --- rule 5: risk:high ------------------------------------------------------------------------
high() { # make the current case risk:high with an approval from <login> on <sha> and a decision
	patch issue-labels.json '[{name: "risk:high"}]'
	patch graphql/PrGate.json --arg d "$3" '.data.repository.pullRequest.reviewDecision = $d'
	patch graphql/Reviews.json --argjson r "$(review "$1" APPROVED "$2" 2026-09-11T22:00:00Z)" '.data.repository.pullRequest.reviews.nodes += [$r]'
}
new_case high-valid
high human "$HEAD" APPROVED
expect_pass "risk:high with --confirm-high and a current allowlisted approval passes" 7 42 --confirm-high --repo o/r
expect_output "high-valid: names the approver" "5 current APPROVED review on head from an allowlisted non-author: human"
expect_output "high-valid: the allowlist came from the default branch" "5 human-reviewer allowlist from main:policy/human-reviewers.txt: human"
new_case high-no-flag
high human "$HEAD" APPROVED
expect_refuse "risk:high without --confirm-high refuses even with a valid approval" "5 risk:high: --confirm-high is required" 7 42 --repo o/r
new_case high-no-review
patch issue-labels.json '[{name: "risk:high"}]'
expect_refuse "risk:high with the flag but no review refuses (the flag is never sufficient)" "no APPROVED review on head" 7 42 --confirm-high --repo o/r
expect_output "high-no-review: reviewDecision null is not APPROVED" "FAIL - 5 reviewDecision: null"
new_case high-author
high author "$HEAD" APPROVED
expect_refuse "an approval by the PR author refuses" "APPROVED on head only by author (the author, or not in the allowlist)" 7 42 --confirm-high --repo o/r
new_case high-not-allowlisted
high stranger "$HEAD" APPROVED
expect_refuse "an approval from a login outside the allowlist refuses" "APPROVED on head only by stranger" 7 42 --confirm-high --repo o/r
new_case high-bot
printf 'human\ncopilot-pull-request-reviewer\n' >"$case_dir/human-reviewers.txt"
high copilot-pull-request-reviewer "$HEAD" APPROVED
expect_pass "the allowlist is the only identity test: a listed login passes even if it is a bot (listing one is the reviewed policy change)" 7 42 --confirm-high --repo o/r
new_case high-old-sha
high human "$OLD" APPROVED
expect_refuse "an approval on an older SHA refuses" "approval(s) by human are on an older commit" 7 42 --confirm-high --repo o/r
new_case high-dismissed
patch issue-labels.json '[{name: "risk:high"}]'
patch graphql/PrGate.json '.data.repository.pullRequest.reviewDecision = "APPROVED"'
patch graphql/Reviews.json --argjson r "$(review human DISMISSED "$HEAD" 2026-09-11T22:00:00Z)" '.data.repository.pullRequest.reviews.nodes += [$r]'
expect_refuse "a dismissed approval refuses" "no APPROVED review on head" 7 42 --confirm-high --repo o/r
new_case high-pending
patch issue-labels.json '[{name: "risk:high"}]'
patch graphql/PrGate.json '.data.repository.pullRequest.reviewDecision = "APPROVED"'
patch graphql/Reviews.json --argjson r "$(review human PENDING "$HEAD" 2026-09-11T22:00:00Z)" '.data.repository.pullRequest.reviews.nodes += [$r]'
expect_refuse "an unsubmitted (PENDING) review refuses" "no APPROVED review on head" 7 42 --confirm-high --repo o/r
new_case high-then-commented
high human "$HEAD" APPROVED
patch graphql/Reviews.json --argjson r "$(review human COMMENTED "$HEAD" 2026-09-11T22:05:00Z)" '.data.repository.pullRequest.reviews.nodes += [$r]'
expect_pass "a comment-only review after an approval does not withdraw it (only CHANGES_REQUESTED and DISMISSED do)" 7 42 --confirm-high --repo o/r
new_case high-commented-only
patch issue-labels.json '[{name: "risk:high"}]'
patch graphql/PrGate.json '.data.repository.pullRequest.reviewDecision = "REVIEW_REQUIRED"'
patch graphql/Reviews.json --argjson r "$(review human COMMENTED "$HEAD" 2026-09-11T22:00:00Z)" '.data.repository.pullRequest.reviews.nodes += [$r]'
expect_refuse "a comment-only review is not an approval" "no APPROVED review on head" 7 42 --confirm-high --repo o/r
new_case high-changes-requested
high human "$HEAD" CHANGES_REQUESTED
patch graphql/Reviews.json --argjson r "$(review other CHANGES_REQUESTED "$HEAD" 2026-09-11T22:05:00Z)" '.data.repository.pullRequest.reviews.nodes += [$r]'
expect_refuse "a change request beside an approval refuses" "5 changes requested on head by: other" 7 42 --confirm-high --repo o/r
expect_output "high-changes-requested: reviewDecision is read from the platform" "FAIL - 5 reviewDecision: CHANGES_REQUESTED"
new_case high-superseded
high human "$HEAD" APPROVED
patch graphql/Reviews.json --argjson r "$(review human CHANGES_REQUESTED "$HEAD" 2026-09-11T22:05:00Z)" '.data.repository.pullRequest.reviews.nodes += [$r]'
patch graphql/PrGate.json '.data.repository.pullRequest.reviewDecision = "CHANGES_REQUESTED"'
expect_refuse "a reviewer's later change request supersedes their earlier approval" "5 changes requested on head by: human" 7 42 --confirm-high --repo o/r
new_case high-decision-only
high human "$OLD" APPROVED
patch graphql/PrGate.json '.data.repository.pullRequest.reviewDecision = "APPROVED"'
expect_refuse "reviewDecision APPROVED alone (approval on an older SHA) refuses" "on an older commit" 7 42 --confirm-high --repo o/r
new_case high-reviews-page2
high nobody "$OLD" APPROVED
patch graphql/Reviews.json '.data.repository.pullRequest.reviews.pageInfo = {hasNextPage: true, endCursor: "c1"}'
jq -n --argjson r "$(review human APPROVED "$HEAD" 2026-09-11T22:00:00Z)" '{data: {repository: {pullRequest: {reviews: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [$r]}}}}}' >"$case_dir/graphql/Reviews.page2.json"
expect_pass "a valid approval on page 2 of the reviews list is seen" 7 42 --confirm-high --repo o/r
new_case high-default-allowlist
rm "$case_dir/human-reviewers.txt"
high owner "$HEAD" APPROVED
expect_pass "with no allowlist file, the repository owner's approval passes" 7 42 --confirm-high --repo o/r
expect_output "high-default-allowlist: the default is announced" "allowlist defaults to the repository owner (owner)"
new_case high-default-allowlist-other
rm "$case_dir/human-reviewers.txt"
high human "$HEAD" APPROVED
expect_refuse "with no allowlist file, a non-owner approval refuses" "APPROVED on head only by human" 7 42 --confirm-high --repo o/r
new_case high-empty-allowlist
printf '# nobody listed yet\n\n' >"$case_dir/human-reviewers.txt"
high human "$HEAD" APPROVED
expect_refuse "a comment-only allowlist is an empty list, not a crash" "APPROVED on head only by human (the author, or not in the allowlist)" 7 42 --confirm-high --repo o/r
new_case flag-on-normal
expect_pass "--confirm-high on a non-high issue is ignored" 7 42 --confirm-high --repo o/r
expect_output "flag-on-normal: the ignored flag is noted" "note - 5 --confirm-high given but the issue is risk:normal; the flag is ignored"

# --- rule 6: the Evidence block -------------------------------------------------------------
new_case no-block
set_body "$(printf '## Summary\n- x\n\nCloses #42\n')"
expect_refuse "a missing Evidence block refuses" "6 evidence: no '## Evidence' section" 7 42 --repo o/r
new_case two-headings
set_body "$(printf '%s\n\n## Evidence\n```json\n%s\n```\n' "$(jq -r .body "$green/pull.json")" "$EVIDENCE_BLOCK")"
expect_refuse "two '## Evidence' sections refuse" "6 evidence: 2 '## Evidence' sections" 7 42 --repo o/r
new_case two-fences
set_body "$(printf '## Evidence\n```json\n%s\n```\n\n```json\n%s\n```\n\nCloses #42\n' "$EVIDENCE_BLOCK" "$EVIDENCE_BLOCK")"
expect_refuse "two json fences under one heading refuse" "found 2" 7 42 --repo o/r
new_case no-fence
set_body "$(printf '## Evidence\nprose only\n\nCloses #42\n')"
expect_refuse "an Evidence heading with no fence refuses" "found 0" 7 42 --repo o/r
new_case empty-fence
set_body "$(printf '## Evidence\n```json\n```\n\nCloses #42\n')"
expect_refuse "an empty json fence refuses (validation keys off the selected fence, not its content)" "6 evidence: the block is not exactly one strict JSON object" 7 42 --repo o/r
new_case unterminated-fence
set_body "$(printf '## Evidence\n```json\n%s\n' "$EVIDENCE_BLOCK")"
expect_refuse "an unterminated json fence refuses" "an unterminated \`\`\`json fence under '## Evidence' (0 completed, 1 never closed)" 7 42 --repo o/r
new_case valid-plus-unterminated
set_body "$(printf '## Evidence\n```json\n%s\n```\n\n```json\n%s\n' "$EVIDENCE_BLOCK" "$EVIDENCE_BLOCK")"
expect_refuse "a valid fence followed by an unterminated one refuses" "(1 completed, 1 never closed)" 7 42 --repo o/r
new_case unterminated-before-next-heading
set_body "$(printf '## Evidence\n```json\n%s\n\n## Notes\nx\n\nCloses #42\n' "$EVIDENCE_BLOCK")"
expect_refuse "a fence left open when the next section starts refuses" "(0 completed, 1 never closed)" 7 42 --repo o/r
for bad in '.tests = true' '.docs = {}' '.context_reads = 7' '.context_reads = [1, "AGENTS.md"]' '.context_reads = [true]' '.session = null' '.role = 3' '.wall_clock_min = false' '.critic = []' '.schema = ["ticket-workflow/evidence/1"]'; do
	new_case "type-$(printf '%s' "$bad" | tr -c 'a-z' '-')"
	set_body "$(body_with "$bad")"
	expect_refuse "a non-string value ($bad) is a rule-6 FAIL, never a jq error" "6 evidence block:" 7 42 --repo o/r
	if [[ $out == *"jq: error"* ]]; then fail "type case $bad: jq errored"; fi
done
new_case malformed
set_body "$(printf '## Evidence\n```json\n{"schema": "ticket-workflow/evidence/1",\n```\n\nCloses #42\n')"
expect_refuse "malformed JSON refuses" "6 evidence: the block is not exactly one strict JSON object" 7 42 --repo o/r
new_case two-objects
set_body "$(printf '## Evidence\n```json\n%s\n%s\n```\n\nCloses #42\n' "$EVIDENCE_BLOCK" "$EVIDENCE_BLOCK")"
expect_refuse "two objects in one fence refuse" "not exactly one strict JSON object" 7 42 --repo o/r
new_case wrong-schema
set_body "$(body_with '.schema = "ticket-workflow/evidence/2"')"
expect_refuse "a wrong schema version refuses" "6 evidence block: schema must be one of ticket-workflow/evidence/1" 7 42 --repo o/r
new_case placeholder-tests
set_body "$(body_with '.tests = "TODO"')"
expect_refuse "a placeholder tests value refuses" "6 evidence block: placeholder left in tests, docs, or context_reads" 7 42 --repo o/r
new_case placeholder-template
set_body "$(body_with '.tests = "<command(s) run in Step 6 and their result>"')"
expect_refuse "an unfilled template placeholder refuses" "placeholder left" 7 42 --repo o/r
new_case na-with-reason
set_body "$(body_with '.tests = "n/a: docs-only change, no test surface"')"
expect_pass "n/a with a reason is not a placeholder" 7 42 --repo o/r
new_case non-numeric-wall-clock
set_body "$(body_with '.wall_clock_min = "about 20"')"
expect_refuse "a non-numeric wall_clock_min refuses" "6 evidence block: wall_clock_min must be a digit string" 7 42 --repo o/r
new_case unquoted-scalar
set_body "$(body_with '.wall_clock_min = 23')"
expect_refuse "an unquoted scalar refuses" "6 evidence block: every scalar must be a quoted string" 7 42 --repo o/r
new_case missing-key
set_body "$(body_with 'del(.session)')"
expect_refuse "a missing required key refuses" "6 evidence block: missing key(s): session" 7 42 --repo o/r
new_case bad-session
set_body "$(body_with '.session = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"')"
expect_refuse "a UUID session id refuses" "6 evidence block: session must match" 7 42 --repo o/r
new_case bad-role
set_body "$(body_with '.role = "reviewer"')"
expect_refuse "an unknown role refuses" "6 evidence block: role must be" 7 42 --repo o/r
new_case bad-critic
set_body "$(body_with '.critic = "clean"')"
expect_refuse "a critic value outside {ran, not run} refuses" "6 evidence block: critic must be" 7 42 --repo o/r
new_case no-critic
set_body "$(body_with 'del(.critic)')"
expect_pass "critic is optional" 7 42 --repo o/r
new_case empty-reads
set_body "$(body_with '.context_reads = []')"
expect_refuse "an empty context_reads refuses" "6 evidence block: context_reads must be a non-empty array" 7 42 --repo o/r
new_case absolute-read
set_body "$(body_with '.context_reads = ["/etc/passwd"]')"
expect_refuse "an absolute context_reads path refuses" "6 evidence block: context_reads must be repo-relative" 7 42 --repo o/r
new_case invented-read
set_body "$(body_with '.context_reads += ["docs/no-such-file.md"]')"
expect_refuse "a context_reads path absent from the head tree refuses" "6 context_reads path is not in the head tree: docs/no-such-file.md" 7 42 --repo o/r
expect_output "invented-read: the real paths still pass" "ok   - 6 context_reads path is in the head tree: AGENTS.md"

# --- everything wrong at once reports every rule --------------------------------------------
new_case all-wrong
patch check-runs.json '(.check_runs[] | select(.id == 3003) | .conclusion) = "failure"'
patch graphql/PrGate.json '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state = "FAILURE"'
patch graphql/ReviewThreads.json '.data.repository.pullRequest.reviewThreads.nodes[0].isResolved = false'
patch graphql/ClosingRefs.json "$CLOSING.nodes = []"
patch issue-labels.json '[]'
set_body "$(body_with '.tests = "TBD"')"
run_gate 7 42 --repo o/r
[ "$status" -eq 1 ] && ok "all-wrong: refuses" || fail "all-wrong: refuses (exit $status)"
for n in 1 2 3 4 6; do
	if [[ $out == *"FAIL - $n "* ]]; then ok "all-wrong: rule $n reported"; else fail "all-wrong: rule $n reported"; fi
done
expect_output "all-wrong: the count is right" "REFUSED: 6 rule violation(s)"

# --- usage and API errors (exit 2: nothing decided) --------------------------------------------
new_case usage
expect_error "a non-numeric PR refuses with usage" "need a numeric <pr> and <issue>" seven 42 --repo o/r
expect_error "a missing issue refuses with usage" "need a numeric <pr> and <issue>" 7 --repo o/r
expect_error "an unknown flag refuses with usage" "unknown flag: --force" 7 42 --force --repo o/r
expect_error "a bad --repo refuses" "cannot derive OWNER/REPO" 7 42 --repo not-a-repo
expect_error "--repo without a value is a usage error (exit 2), not a bare shift failure" "--repo needs a value" 7 42 --repo
expect_error "--repo= with an empty value is a usage error, not a silent fallback to the checkout's origin" "--repo needs a value" 7 42 --repo=
new_case repo-equals
expect_pass "--repo=OWNER/REPO (the = form) passes" 7 42 --repo=o/r
new_case leading-zeros
expect_pass "leading-zero ids name the same PR and issue" 007 042 --repo o/r
expect_output "leading-zeros: the ids are normalized for the canonical comparison" "3 closing references: exactly #42"
new_case closed-pr
patch pull.json '.state = "closed"'
expect_error "a closed PR is not gateable" "PR #7 is closed, not open" 7 42 --repo o/r
new_case head-moved
patch graphql/PrGate.json --arg s "$OLD" '.data.repository.pullRequest.headRefOid = $s'
expect_error "a head that moved between reads is an error, not a verdict" "head moved between reads" 7 42 --repo o/r
new_case head-moved-late
jq --arg s "$OLD" '.head.sha = $s' "$green/pull.json" >"$case_dir/pull.later.json"
expect_error "a push during the gate is an error, not a verdict" "head moved during the gate" 7 42 --repo o/r
new_case api-down
rm "$case_dir/pull.json"
expect_error "an API failure is an error, not a verdict" "gh api repos/o/r/pulls/7 failed" 7 42 --repo o/r
new_case allowlist-api-down
high human "$HEAD" APPROVED
mkdir -p "$work/wrap"
printf '#!/usr/bin/env bash\nif [[ "$*" == *human-reviewers* ]]; then echo "gh: HTTP 500" >&2; exit 1; fi\nexec "%s/bin/gh" "$@"\n' "$work" >"$work/wrap/gh"
chmod +x "$work/wrap/gh"
PATH="$work/wrap:$PATH" expect_error "a non-404 failure reading the allowlist is an error, not a default" "reading policy/human-reviewers.txt from main failed" 7 42 --confirm-high --repo o/r

printf '\n%d case(s), %d failure(s)\n' "$cases" "$failures"
[ "$failures" -eq 0 ] || exit 1
printf 'all check-evidence tests passed\n'
