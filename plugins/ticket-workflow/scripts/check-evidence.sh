#!/usr/bin/env bash
# check-evidence.sh — the machine-checked FINISH gate (software-factory design,
# item 1b; docs/superpowers/specs/2026-09-11-software-factory-design.md).
#
#   check-evidence.sh <pr> <issue> [--confirm-high] [--repo OWNER/REPO]
#
# Re-derives every piece of *state* — CI, review threads, closing references,
# risk class, approvals — from the platform, never from the PR body; the body
# is read only for the Evidence block (rule 6), and only to check its shape,
# never to learn whether anything passed. It refuses (exit 1, with a FAIL line
# per broken rule) when any of these holds, each checked against the PR's
# CURRENT HEAD:
#
#   1. the set of check contexts on the head SHA is empty, or the latest
#      attempt of any context (check run or commit status, required or not)
#      is not `success`; cross-checked against the PR's statusCheckRollup;
#   2. any review thread is unresolved (the paginated reviewThreads query
#      the profile's REVIEW_BOT step uses);
#   3. the PR's closing references are not exactly [<issue>];
#   4. <issue> does not carry exactly one `risk:*` label, or that label is
#      not one of risk:docs / risk:low / risk:normal / risk:high;
#   5. the label is risk:high and the PR lacks BOTH the --confirm-high
#      acknowledgement AND a current human approval: reviewDecision must be
#      APPROVED, and an APPROVED review on the head SHA must come from a
#      login in policy/human-reviewers.txt (read from the repository's
#      default branch via the API, never from this checkout) who is not the
#      PR author, with no reviewer's latest review on that SHA requesting
#      changes. The flag never substitutes for the review;
#   6. the `## Evidence` block (item 1a) is absent, duplicated, malformed,
#      fails the required-key / schema / type / placeholder rules, or names
#      a context_reads path that is not in the head tree.
#
# It is a record-checker and a drift control, not a security boundary (the
# spec says so): the unattended merge path (item 11) re-implements every
# predicate in a base-branch workflow. Report-and-stop only — nothing here
# writes to GitHub. Every list read is fully paginated.
#
# Exit status: 0 every rule holds; 1 the gate refuses; 2 usage or API error
# (nothing was decided). Needs gh (authenticated), jq, git. Written to run
# from a piped copy (`git show origin/main:…/check-evidence.sh | bash -s --
# <pr> <issue>`), so nothing is resolved relative to $0. A unit test with a
# fake gh serving fixture JSON lives in ../tests/test-check-evidence.sh.
set -euo pipefail

EVIDENCE_SCHEMAS='["ticket-workflow/evidence/1"]'
RISK_CLASSES='["risk:docs","risk:low","risk:normal","risk:high"]'
ALLOWLIST_PATH='policy/human-reviewers.txt'

usage() {
	cat <<'USAGE'
usage: check-evidence.sh <pr> <issue> [--confirm-high] [--repo OWNER/REPO]

  <pr>            pull request number (a leading # is fine)
  <issue>         the issue this PR must close — passed by FINISH, never
                  inferred from the PR (a PR can reference several)
  --confirm-high  the local acknowledgement FINISH forwards only when it
                  appeared literally in the /finish-ticket arguments; required
                  for a risk:high issue, never sufficient on its own
  --repo          OWNER/REPO; default: parsed from `git remote get-url origin`

exit 0 pass, 1 refused (see FAIL lines), 2 usage/API error
USAGE
}

die() { # <status> <message>
	printf 'check-evidence: %s\n' "$2" >&2
	exit "$1"
}

# --- arguments ----------------------------------------------------------------
pr='' issue='' confirm_high=0 repo=''
while [ $# -gt 0 ]; do
	case $1 in
	--confirm-high) confirm_high=1 ;;
	--repo)
		[ $# -ge 2 ] || die 2 "--repo needs a value (OWNER/REPO)"
		shift
		repo=$1
		;;
	--repo=*)
		repo=${1#--repo=}
		[ -n "$repo" ] || die 2 "--repo needs a value (OWNER/REPO)"
		;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		usage >&2
		die 2 "unknown flag: $1"
		;;
	*)
		if [ -z "$pr" ]; then pr=${1#\#}; elif [ -z "$issue" ]; then issue=${1#\#}; else
			usage >&2
			die 2 "unexpected argument: $1"
		fi
		;;
	esac
	shift
done
[[ $pr =~ ^[0-9]+$ && $issue =~ ^[0-9]+$ ]] || {
	usage >&2
	die 2 "need a numeric <pr> and <issue>"
}
# Normalize to plain decimal: `042` and `42` name the same issue, but rule 3
# compares the id against GitHub's canonical `o/r#42` reference as a string.
pr=$((10#$pr))
issue=$((10#$issue))
for tool in gh jq git; do
	command -v "$tool" >/dev/null || die 2 "$tool is required"
done
if [ -z "$repo" ]; then
	remote=$(git remote get-url origin 2>/dev/null) || die 2 "no origin remote; pass --repo OWNER/REPO"
	# Split the remote into host and path — every git URL form (https://, ssh://
	# with an optional port, git://, and the scp-like git@host:path) — because a
	# path alone would let a non-GitHub origin be gated as though it were the
	# GitHub repo of the same name.
	remote_host=$(printf '%s' "$remote" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#^[^@/]+@##; s#[:/].*$##')
	repo=$(printf '%s' "$remote" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#^[^@/]+@##; s#^[^:/]+(:[0-9]+)?[:/]##; s#\.git$##; s#/$##')
	[ "$(printf '%s' "$remote_host" | tr '[:upper:]' '[:lower:]')" = github.com ] ||
		die 2 "origin is not on github.com (host '$remote_host'); this gate reads the GitHub API — pass --repo OWNER/REPO for the GitHub repository it should gate"
fi
[[ $repo =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die 2 "cannot derive OWNER/REPO (got '$repo'); pass --repo"
owner=${repo%/*}
name=${repo#*/}

# --- output + API helpers -------------------------------------------------------
failures=0
ok() { printf 'ok   - %s\n' "$1"; }
fail() {
	printf 'FAIL - %s\n' "$1"
	failures=$((failures + 1))
}
note() { printf 'note - %s\n' "$1"; }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
errfile="$tmpdir/stderr"

# api <gh api args…> — one read; any failure is an API error (exit 2), since a
# gate that cannot read the platform must not decide.
api() {
	local out
	if ! out=$(gh api "$@" 2>"$errfile"); then
		die 2 "gh api $* failed: $(tr '\n' ' ' <"$errfile")"
	fi
	printf '%s' "$out"
}
# api_list <gh api args…> — a paginated read whose per-page --jq emits a stream
# of items; returns them as one JSON array.
api_list() { api --paginate "$@" | jq -s '.'; }
# graphql_list <OpName> <query> <per-page jq> — paginated GraphQL, same contract.
graphql_list() {
	api_list graphql -f owner="$owner" -f name="$name" -F pr="$pr" -f query="$2" --jq "$3"
}
# head_has_path <path> — 0 when the path exists in the head tree, 1 on 404;
# any other failure is an API error.
head_has_path() {
	local encoded
	encoded=$(printf '%s' "$1" | jq -Rr 'split("/") | map(@uri) | join("/")')
	if gh api "repos/$repo/contents/$encoded?ref=$head" >/dev/null 2>"$errfile"; then return 0; fi
	grep -q 'HTTP 404' "$errfile" && return 1
	die 2 "gh api repos/$repo/contents/$1 failed: $(tr '\n' ' ' <"$errfile")"
}

# --- reads ------------------------------------------------------------------------
repo_json=$(api "repos/$repo")
# Owner and name are case-insensitive for lookup; use GitHub's canonical
# spelling from here on so identity comparisons (rule 3) never trip on casing.
repo=$(printf '%s' "$repo_json" | jq -r '.full_name')
owner=${repo%/*}
name=${repo#*/}
default_branch=$(printf '%s' "$repo_json" | jq -r '.default_branch')
repo_owner=$(printf '%s' "$repo_json" | jq -r '.owner.login')

pull_json=$(api "repos/$repo/pulls/$pr")
pr_state=$(printf '%s' "$pull_json" | jq -r '.state')
[ "$pr_state" = open ] || die 2 "PR #$pr is $pr_state, not open; nothing to gate"
head=$(printf '%s' "$pull_json" | jq -r '.head.sha')
pr_author=$(printf '%s' "$pull_json" | jq -r '.user.login')
# Strip only a line-ending CR (a body edited in the GitHub web UI is CRLF).
# Deleting every CR would launder a raw control character inside the Evidence
# JSON — invalid JSON jq must reject — into something that parses.
printf '%s' "$pull_json" | jq -r '.body // ""' | sed 's/\r$//' >"$tmpdir/body"

# One un-paginated GraphQL read for the scalar facts.
pr_gate_query='query PrGate($owner:String!,$name:String!,$pr:Int!){
  repository(owner:$owner,name:$name){ pullRequest(number:$pr){
    headRefOid author{login} reviewDecision } } }'
gate_json=$(api graphql -f owner="$owner" -f name="$name" -F pr="$pr" -f query="$pr_gate_query" --jq '.data.repository.pullRequest')
[ "$(printf '%s' "$gate_json" | jq -r '.headRefOid')" = "$head" ] ||
	die 2 "PR #$pr's head moved between reads (REST $head vs GraphQL $(printf '%s' "$gate_json" | jq -r '.headRefOid')); re-run"

printf 'check-evidence: %s PR #%s (head %s) against issue #%s\n' "$repo" "$pr" "${head:0:12}" "$issue"

# --- rule 1: every check context on the head SHA, latest attempt, is success ------
# filter=all returns every attempt GitHub retains for the SHA; a context is
# (check suite, name) for check runs — the same name recurs across suites when
# two workflows or two triggers share a job name, and each must be green — and
# the context string for commit statuses. The newest attempt (highest id) wins.
runs_json=$(api_list "repos/$repo/commits/$head/check-runs?filter=all&per_page=100" --jq '.check_runs[]')
statuses_json=$(api_list "repos/$repo/commits/$head/statuses?per_page=100" --jq '.[]')
contexts_json=$(jq -n --argjson runs "$runs_json" --argjson statuses "$statuses_json" '
	def run_ctx: {kind: "check", key: "check:\(.check_suite.id // "?")/\(.name)", label: "\(.app.slug // "unknown-app")/\(.name) [suite \(.check_suite.id // "?")]", name: .name,
		state: (if .status == "completed" then (.conclusion // "no conclusion") else .status end),
		green: (.status == "completed" and .conclusion == "success")};
	def status_ctx: {kind: "status", key: "status:\(.context)", label: .context, name: .context, state: .state, green: (.state == "success")};
	($runs | group_by([.check_suite.id, .name]) | map(max_by(.id) | run_ctx))
	+ ($statuses | group_by(.context) | map(max_by(.id) | status_ctx))')
superseded=$(jq -n --argjson runs "$runs_json" --argjson statuses "$statuses_json" --argjson ctx "$contexts_json" \
	'($runs | length) + ($statuses | length) - ($ctx | length)')
if [ "$(printf '%s' "$contexts_json" | jq 'length')" -eq 0 ]; then
	fail "1 checks: no check runs or statuses on head $head (\"all green\" is never vacuous)"
else
	[ "$superseded" -gt 0 ] && note "1 checks: $superseded older attempt(s) superseded by a newer attempt of the same context"
	while IFS=$'\t' read -r kind label state green; do
		if [ "$green" = true ]; then ok "1 $kind $label: $state"; else fail "1 $kind $label: $state (latest attempt is not success)"; fi
	done < <(printf '%s' "$contexts_json" | jq -r '.[] | [.kind, .label, .state, .green] | @tsv')
fi
# Cross-check: the platform's own rollup for the head commit must agree —
# SUCCESS overall, every rollup context green by the same latest-attempt rule
# (this read comes after the direct one, so a rerun or failure in between
# shows up here), and every context the rollup lists present in the direct
# read under the same identity: (check suite, name) for check runs, the
# context string for statuses. The direct read is a superset by construction
# (filter=all, every suite, plus commit statuses) and each extra it sees is
# still held to success above, so only a context the read missed could weaken
# the gate.
# Read the aggregate state *after* the direct check/status reads, not from the
# earlier scalar query: an aggregate that turns EXPECTED (a required context
# with no run at all) between the two would otherwise never be seen.
rollup_state_query='query RollupState($owner:String!,$name:String!,$pr:Int!){
  repository(owner:$owner,name:$name){ pullRequest(number:$pr){
    commits(last:1){ nodes{ commit{ oid statusCheckRollup{ state } } } } } } }'
rollup_state=$(api graphql -f owner="$owner" -f name="$name" -F pr="$pr" -f query="$rollup_state_query" \
	--jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state // "none"')
rollup_query='query RollupContexts($owner:String!,$name:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){ pullRequest(number:$pr){ commits(last:1){ nodes{ commit{ statusCheckRollup{
    contexts(first:100, after:$endCursor){ pageInfo{ hasNextPage endCursor }
      nodes{ __typename
        ... on CheckRun{ name status conclusion databaseId checkSuite{ databaseId } }
        ... on StatusContext{ context state } } } } } } } } } }'
rollup_json=$(graphql_list RollupContexts "$rollup_query" \
	'(.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup // {contexts: {nodes: []}}).contexts.nodes[]')
if [ "$rollup_state" = SUCCESS ]; then
	ok "1 statusCheckRollup on head: SUCCESS"
else
	fail "1 statusCheckRollup on head: $rollup_state (cross-check; expected SUCCESS)"
fi
rollup_ctx_json=$(printf '%s' "$rollup_json" | jq '
	def check_ctx: {key: "check:\(.checkSuite.databaseId // "?")/\(.name)", label: "check \(.name) [suite \(.checkSuite.databaseId // "?")]",
		state: (if .status == "COMPLETED" then (.conclusion // "no conclusion") else .status end),
		green: (.status == "COMPLETED" and .conclusion == "SUCCESS")};
	def status_ctx: {key: "status:\(.context)", label: "status \(.context)", state: .state, green: (.state == "SUCCESS")};
	(map(select(.__typename == "CheckRun")) | group_by([.checkSuite.databaseId, .name]) | map(max_by(.databaseId) | check_ctx))
	+ (map(select(.__typename == "StatusContext")) | group_by(.context) | map(last | status_ctx))')
while IFS=$'\t' read -r label state; do
	fail "1 statusCheckRollup $label: $state (latest attempt is not success)"
done < <(printf '%s' "$rollup_ctx_json" | jq -r '.[] | select(.green | not) | [.label, .state] | @tsv')
key_diff=$(jq -n --argjson ctx "$contexts_json" --argjson rollup "$rollup_ctx_json" '
	([$ctx[].key] | unique) as $ours
	| ([$rollup[].key] | unique) as $theirs
	| {missing_from_read: ($theirs - $ours), extra_in_read: ($ours - $theirs)}')
if [ "$(printf '%s' "$key_diff" | jq '.missing_from_read | length')" -eq 0 ]; then
	ok "1 statusCheckRollup contexts are all in the head-SHA read ($(printf '%s' "$rollup_ctx_json" | jq 'length') listed, $(printf '%s' "$contexts_json" | jq 'length') read)"
else
	fail "1 statusCheckRollup lists context(s) the head-SHA read did not see: $(printf '%s' "$key_diff" | jq -r '.missing_from_read | join(", ")')"
fi
[ "$(printf '%s' "$key_diff" | jq '.extra_in_read | length')" -eq 0 ] ||
	note "1 head-SHA read saw context(s) the rollup does not list (each still held to success): $(printf '%s' "$key_diff" | jq -r '.extra_in_read | join(", ")')"

# --- rule 2: no unresolved review threads ------------------------------------------
threads_query='query ReviewThreads($owner:String!,$name:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){ pullRequest(number:$pr){
    reviewThreads(first:100, after:$endCursor){ pageInfo{ hasNextPage endCursor }
      nodes{ id isResolved path comments(first:1){ nodes{ author{login} body } } } } } } }'
threads_json=$(graphql_list ReviewThreads "$threads_query" '.data.repository.pullRequest.reviewThreads.nodes[]')
unresolved=$(printf '%s' "$threads_json" | jq '[.[] | select(.isResolved | not)]')
if [ "$(printf '%s' "$unresolved" | jq 'length')" -eq 0 ]; then
	ok "2 review threads: none unresolved ($(printf '%s' "$threads_json" | jq 'length') total)"
else
	while IFS=$'\t' read -r path author body; do
		fail "2 unresolved review thread on ${path:-<no file>} by ${author:-unknown}: ${body}"
	done < <(printf '%s' "$unresolved" | jq -r '.[] | [(.path // ""), (.comments.nodes[0].author.login // ""), ((.comments.nodes[0].body // "") | gsub("[\\r\\n\\t]+"; " ") | .[0:80])] | @tsv')
fi

# --- rule 3: closing references are exactly [<issue>] -----------------------------------
closing_query='query ClosingRefs($owner:String!,$name:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){ pullRequest(number:$pr){
    closingIssuesReferences(first:100, after:$endCursor){ pageInfo{ hasNextPage endCursor }
      nodes{ number repository{nameWithOwner} } } } } }'
closing_json=$(graphql_list ClosingRefs "$closing_query" '.data.repository.pullRequest.closingIssuesReferences.nodes[]')
closing_count=$(printf '%s' "$closing_json" | jq 'length')
closing_list=$(printf '%s' "$closing_json" | jq -r '[.[] | "\(.repository.nameWithOwner)#\(.number)"] | join(", ")')
if [ "$closing_count" -eq 1 ] && [ "$closing_list" = "$repo#$issue" ]; then
	ok "3 closing references: exactly #$issue"
elif [ "$closing_count" -eq 0 ]; then
	fail "3 closing references: none (the PR body needs a closing keyword for #$issue)"
else
	fail "3 closing references: expected exactly $repo#$issue, got $closing_count: ${closing_list:-?}"
fi

# --- rule 4: the issue carries exactly one known risk label -----------------------------
issue_json=$(api "repos/$repo/issues/$issue")
labels_json=$(api_list "repos/$repo/issues/$issue/labels?per_page=100" --jq '.[]')
risk_labels=$(printf '%s' "$labels_json" | jq -c '[.[].name | select(startswith("risk:"))] | sort')
risk_class=''
if [ "$(printf '%s' "$issue_json" | jq 'has("pull_request")')" = true ]; then
	fail "4 #$issue is a pull request, not an issue"
elif [ "$(printf '%s' "$risk_labels" | jq --argjson known "$RISK_CLASSES" 'length == 1 and (.[0] | IN($known[]))')" = true ]; then
	risk_class=$(printf '%s' "$risk_labels" | jq -r '.[0]')
	ok "4 issue #$issue risk label: $risk_class"
elif [ "$(printf '%s' "$risk_labels" | jq 'length')" -eq 0 ]; then
	fail "4 issue #$issue has no risk:* label (provision + backfill: scripts/provision-risk-labels)"
else
	fail "4 issue #$issue must carry exactly one of $(printf '%s' "$RISK_CLASSES" | jq -r 'join(", ")'); has $(printf '%s' "$risk_labels" | jq -r 'join(", ")')"
fi

# --- rule 5: risk:high needs the flag AND a current human approval -----------------
if [ "$risk_class" = "risk:high" ]; then
	if [ "$confirm_high" -eq 1 ]; then
		ok "5 risk:high: --confirm-high acknowledged (never sufficient on its own)"
	else
		fail "5 risk:high: --confirm-high is required (pass it literally in the /finish-ticket arguments)"
	fi
	# The allowlist comes from the default branch through the API, so the ticket
	# checkout cannot allowlist its own reviewer. Absent → the repository owner.
	if allowlist_raw=$(gh api -H 'Accept: application/vnd.github.raw+json' "repos/$repo/contents/$ALLOWLIST_PATH?ref=$default_branch" 2>"$errfile"); then
		# `grep -v` exits 1 on no output (a comment-only file) — that is an empty list, not an error.
		allowlist=$(printf '%s\n' "$allowlist_raw" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | { grep -v '^$' || true; } | jq -R . | jq -sc '.')
		note "5 human-reviewer allowlist from $default_branch:$ALLOWLIST_PATH: $(printf '%s' "$allowlist" | jq -r 'join(", ")')"
	elif grep -q 'HTTP 404' "$errfile"; then
		allowlist=$(jq -nc --arg o "$repo_owner" '[$o]')
		note "5 no $ALLOWLIST_PATH on $default_branch; allowlist defaults to the repository owner ($repo_owner)"
	else
		die 2 "reading $ALLOWLIST_PATH from $default_branch failed: $(tr '\n' ' ' <"$errfile")"
	fi
	review_decision=$(printf '%s' "$gate_json" | jq -r '.reviewDecision // "null"')
	if [ "$review_decision" = APPROVED ]; then
		ok "5 reviewDecision: APPROVED"
	else
		fail "5 reviewDecision: $review_decision (expected APPROVED)"
	fi
	reviews_query='query Reviews($owner:String!,$name:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$name){ pullRequest(number:$pr){
    reviews(first:100, after:$endCursor){ pageInfo{ hasNextPage endCursor }
      nodes{ state author{login} commit{oid} submittedAt } } } } }'
	reviews_json=$(graphql_list Reviews "$reviews_query" '.data.repository.pullRequest.reviews.nodes[]')
	# Each reviewer's most recent submitted review ON THE HEAD SHA is what counts:
	# an approval on an older commit, a dismissed one, or an unsubmitted (PENDING)
	# one is not a current approval.
	verdict=$(jq -n --argjson reviews "$reviews_json" --argjson allow "$allowlist" --arg head "$head" --arg author "$pr_author" '
		# COMMENTED carries no verdict — leaving a comment after approving does not
		# withdraw the approval (GitHub keeps reviewDecision APPROVED), so only a
		# verdict-bearing review supersedes an earlier one. PENDING is unsubmitted.
		[$reviews[] | select(.commit.oid == $head and (.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED")))]
		| group_by(.author.login) | map(sort_by(.submittedAt) | last) as $latest
		| {
			changes_requested: [$latest[] | select(.state == "CHANGES_REQUESTED") | .author.login],
			approvers: [$latest[] | select(.state == "APPROVED") | .author.login],
			valid: [$latest[] | select(.state == "APPROVED" and .author.login != $author and (.author.login | IN($allow[]))) | .author.login],
			older_approvals: [$reviews[] | select(.state == "APPROVED" and .commit.oid != $head) | .author.login] | unique
		}')
	if [ "$(printf '%s' "$verdict" | jq '.changes_requested | length')" -gt 0 ]; then
		fail "5 changes requested on head by: $(printf '%s' "$verdict" | jq -r '.changes_requested | join(", ")')"
	fi
	if [ "$(printf '%s' "$verdict" | jq '.valid | length')" -gt 0 ]; then
		ok "5 current APPROVED review on head from an allowlisted non-author: $(printf '%s' "$verdict" | jq -r '.valid | join(", ")')"
	else
		approvers=$(printf '%s' "$verdict" | jq -r '.approvers | join(", ")')
		older=$(printf '%s' "$verdict" | jq -r '.older_approvals | join(", ")')
		reason="no APPROVED review on head ${head:0:12}"
		[ -n "$approvers" ] && reason="APPROVED on head only by ${approvers} (the author, or not in the allowlist)"
		[ -z "$approvers" ] && [ -n "$older" ] && reason="$reason; approval(s) by $older are on an older commit"
		fail "5 risk:high needs a current APPROVED review on the head SHA from an allowlisted human who is not the author: $reason"
	fi
elif [ "$confirm_high" -eq 1 ]; then
	note "5 --confirm-high given but the issue is ${risk_class:-unclassified}; the flag is ignored"
fi

# --- rule 6: exactly one well-formed Evidence block -------------------------------------
# One fence-aware parser backs the heading count, the fence count and the
# extraction, so all three agree about what is structure and what is quoted
# text: a `## Evidence` line or a ```json snippet quoted inside another fence
# (a template example in a test plan, say) is text, never the block. Same
# parser and same column-0 contract as the evidence-block contract test
# (tests/test-evidence-block.sh, item 1a), which pins these decoys from the
# template's side.
evidence_parser='
	# A fence opens with 3+ backticks or 3+ tildes (CommonMark); it closes on a
	# line of the same character at least as long, with nothing else on it.
	function run(s, c) { match(s, "^[" c "]+"); return RLENGTH }
	!infence && /^(```|~~~)/ {
		infence = 1; fchar = substr($0, 1, 1); width = run($0, fchar)
		info = substr($0, width + 1); sub(/[[:space:]]+$/, "", info)
		json = (inside && info == "json"); buf = ""
		next
	}
	infence && substr($0, 1, 1) == fchar && run($0, fchar) >= width && $0 ~ ("^[" fchar "]+[[:space:]]*$") {
		infence = 0
		if (json) { fences++; if (MODE == "extract" && !done) { printf "%s", buf; done = 1 } }
		json = 0; next
	}
	infence { if (json) buf = buf $0 "\n"; next }
	/^## Evidence[[:space:]]*$/ { headings++; inside = 1; next }
	/^##?([ \t]|$)/ { inside = 0 }
	# A json fence still open at EOF is malformed, whatever came before it:
	# report -1 so the "exactly one" comparison fails rather than counting an
	# earlier closed block as the whole story.
	END {
		if (infence && json) fences = -1
		if (MODE == "headings") print headings + 0; else if (MODE == "fences") print fences + 0
	}
'
count_evidence_headings() { awk -v MODE=headings "$evidence_parser" "$1"; }
count_evidence_fences() { awk -v MODE=fences "$evidence_parser" "$1"; }
extract_evidence_block() { awk -v MODE=extract "$evidence_parser" "$1"; }

headings=$(count_evidence_headings "$tmpdir/body")
fences=$(count_evidence_fences "$tmpdir/body")
block='' have_block=0
if [ "$headings" -eq 0 ]; then
	fail "6 evidence: no '## Evidence' section in the PR body"
elif [ "$headings" -gt 1 ]; then
	fail "6 evidence: $headings '## Evidence' sections; exactly one block per PR"
elif [ "$fences" -lt 0 ]; then
	fail "6 evidence: an unterminated \`\`\`json fence under '## Evidence'"
elif [ "$fences" -ne 1 ]; then
	fail "6 evidence: expected one \`\`\`json fence under '## Evidence', found $fences"
else
	block=$(extract_evidence_block "$tmpdir/body")
	have_block=1
fi
if [ "$have_block" -eq 1 ]; then
	# Exactly one object in the fence — an empty fence yields zero values, and
	# `jq -e` alone would report only the last of several.
	if ! printf '%s' "$block" | jq -es 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
		fail "6 evidence: the block is not exactly one strict JSON object"
		have_block=0
	fi
fi
if [ "$have_block" -eq 1 ]; then
	# The item 1a contract, as named jq predicates; each failing name is reported.
	problems=$(printf '%s' "$block" | jq -r --argjson schemas "$EVIDENCE_SCHEMAS" '
		def placeholder: test("^\\s*(TODO|TBD|n/?a)\\s*$"; "i") or test("<[^>]*>");
		def relative: (test("^/") | not) and (test("(^|/)[.][.]?(/|$)") | not);
		(["schema","tests","docs","context_reads","session","role","wall_clock_min"] - keys) as $missing
		| [
			(if ($missing | length) > 0 then "missing key(s): \($missing | join(", "))" else empty end),
			(if (.schema | type) == "string" and (.schema | IN($schemas[])) then empty else "schema must be one of \($schemas | join(", "))" end),
			(if (to_entries | map(select(.key != "context_reads")) | all(.value | type == "string")) then empty else "every scalar must be a quoted string" end),
			(if ((.context_reads | type) == "array" and (.context_reads | length) > 0 and (.context_reads | all(type == "string" and length > 0))) then empty else "context_reads must be a non-empty array of strings" end),
			(if ((.context_reads | type) == "array" and (.context_reads | all(type == "string" and relative))) then empty else "context_reads must be repo-relative (no leading /, no . or .. segment)" end),
			(if ((.context_reads | type) == "array" and (.context_reads | all(type == "string" and (test("[\u0000-\u001f]") | not)))) then empty else "context_reads must not contain control characters" end),
			(if ([.tests, .docs] | all(type == "string" and length > 0)) then empty else "tests and docs must be non-empty" end),
			(if ([.tests, .docs] + (if (.context_reads | type) == "array" then .context_reads else [] end) | all(type == "string" and (placeholder | not))) then empty else "placeholder left in tests, docs, or context_reads (TODO, TBD, n/a without a reason, <…>)" end),
			(if (.session | type) == "string" and (.session | test("^(cse_[A-Za-z0-9]+|session_[A-Za-z0-9]+|local)$")) then empty else "session must match ^(cse_…|session_…|local)$" end),
			(if (.role | type) == "string" and (.role | IN("planner", "epic-coordinator", "implementer")) then empty else "role must be planner, epic-coordinator, or implementer" end),
			(if (.wall_clock_min | type) == "string" and (.wall_clock_min | test("^[0-9]+$")) then empty else "wall_clock_min must be a digit string" end),
			(if (has("critic") | not) or ((.critic | type) == "string" and (.critic | IN("ran", "not run"))) then empty else "critic must be \"ran\" or \"not run\"" end)
		] | .[]')
	if [ -z "$problems" ]; then
		ok "6 evidence block: well-formed ($(printf '%s' "$block" | jq -r '.schema'))"
		while IFS= read -r -d '' read_path; do
			if head_has_path "$read_path"; then
				ok "6 context_reads path is in the head tree: $read_path"
			else
				fail "6 context_reads path is not in the head tree: $read_path"
			fi
		done < <(printf '%s' "$block" | jq -j '.context_reads[] | ., "\u0000"')
	else
		while IFS= read -r problem; do fail "6 evidence block: $problem"; done <<<"$problems"
	fi
fi

# --- final state: every read above was against $head on an open PR. A push
# during the gate would leave a green old commit judged while the PR points
# elsewhere; a merge or close during the gate would hand FINISH a verdict for a
# PR that is no longer open (and a merge keeps the same head, so the SHA alone
# does not catch it). Either way nothing is decided — exit 2 and re-run.
final_state=$(api "repos/$repo/pulls/$pr" --jq '"\(.state) \(.head.sha)"')
final_head=${final_state#* }
[ "$final_head" = "$head" ] || die 2 "PR #$pr's head moved during the gate ($head -> $final_head); re-run"
[ "${final_state%% *}" = open ] || die 2 "PR #$pr stopped being open during the gate (now ${final_state%% *}); nothing was decided"

# --- verdict -------------------------------------------------------------------------------
if [ "$failures" -gt 0 ]; then
	printf 'REFUSED: %d rule violation(s) on PR #%s; report and stop — never auto-fix from FINISH\n' "$failures" "$pr"
	exit 1
fi
# The verdict is a snapshot, not a lock. Every rule was evaluated against head
# $head on an open PR, and the head and open state were re-read at the end; the
# other inputs (labels, threads, reviews, the body) can still change in the
# moment between this line and a merge, and no amount of re-reading closes that
# window — the gate is a drift control, not a mutual exclusion (spec 1b). What
# does close it is pinning the merge to the SHA below, which the GitHub merge
# API accepts and refuses if the head has moved; FINISH should pass it through.
printf 'PASS: PR #%s satisfies the FINISH gate for issue #%s, as of head %s\n' "$pr" "$issue" "$head"
printf '      (a snapshot — pin the merge to %s so a change after this verdict cannot slip through)\n' "$head"
