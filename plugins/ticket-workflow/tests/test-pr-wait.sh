#!/usr/bin/env bash
# Tests for scripts/pr-wait.sh, the in-turn wait for CI, the review bot and
# mergeability: every exit path of each subcommand, with gh replaced by a
# stub that serves fixtures by endpoint. A fixture named <key>.<n> answers
# the n-th call to that endpoint and <key> every other call, so a test can
# script a sequence (pending, then green). The key is the endpoint after
# repos/o/r/, with / turned into _ (pulls_7, commits_<sha>_check-runs).
#
#   bash plugins/ticket-workflow/tests/test-pr-wait.sh
#
# The case #351 is about, a check that errors on every call, must end with
# exit 2 within the retry budget rather than wait.
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
script="$plugin/scripts/pr-wait.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

cat >"$tmp/gh" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls"
if [ -n "${STUB_FAIL:-}" ]; then
	echo "$STUB_FAIL" >&2
	exit 1
fi
[ "${1:-}" = api ] || { echo "stub gh: only api is stubbed: $*" >&2; exit 1; }
shift
endpoint=
while [ $# -gt 0 ]; do
	case $1 in
	-X | -f | -F | --hostname | --jq) shift 2 ;;
	*) [ -n "$endpoint" ] || endpoint=$1; shift ;;
	esac
done
key=$(printf '%s' "${endpoint#repos/o/r/}" | tr / _)
n=$(($(cat "$STUB_DIR/n-$key" 2>/dev/null || echo 0) + 1))
echo "$n" >"$STUB_DIR/n-$key"
if [ "${STUB_FAIL_ONCE:-}" = "$key" ] && [ "$n" = 1 ]; then
	echo 'HTTP 502: Bad Gateway' >&2
	exit 1
fi
for f in "$STUB_DIR/$key.$n" "$STUB_DIR/$key"; do
	if [ -f "$f" ]; then
		cat "$f"
		exit 0
	fi
done
echo "gh: Not Found (HTTP 404) $endpoint" >&2
exit 1
STUB_EOF
chmod +x "$tmp/gh"

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
stub=$tmp/stub

reset() { rm -rf "$stub" && mkdir -p "$stub"; }
fx() { printf '%s\n' "$2" >"$stub/$1"; } # fx <key> <json>

pr() { # pr <head> [requested login] [mergeable] [mergeable_state] [state] [merged_at]: a PR as REST returns it
	local requested=
	[ -z "${2:-}" ] || requested="{\"login\":\"$2\"}"
	printf '{"number":7,"state":"%s","merged_at":%s,"head":{"sha":"%s"},"requested_reviewers":[%s],"mergeable":%s,"mergeable_state":"%s"}' \
		"${5:-open}" "${6:-null}" "$1" "$requested" "${3:-null}" "${4:-unknown}"
}
runs() { # runs <name:status:conclusion>...: a check-runs reply
	local out= r
	for r in "$@"; do
		out="$out${out:+,}{\"name\":\"${r%%:*}\",\"status\":\"$(printf '%s' "$r" | cut -d: -f2)\",\"conclusion\":$(c=$(printf '%s' "$r" | cut -d: -f3); [ -n "$c" ] && printf '"%s"' "$c" || printf null),\"output\":{\"text\":\"long\"}}"
	done
	printf '{"total_count":%s,"check_runs":[%s]}' "$#" "$out"
}
statuses() { # statuses <context:state>...: a combined-status reply (its .state reads pending with none)
	local out= s
	for s in "$@"; do out="$out${out:+,}{\"context\":\"${s%%:*}\",\"state\":\"${s#*:}\"}"; done
	printf '{"state":"pending","statuses":[%s]}' "$out"
}
review() { # review <id> <commit> <submitted_at> <body>: one Copilot review
	jq -cn --argjson id "$1" --arg c "$2" --arg at "$3" --arg b "$4" \
		'{id: $id, user: {login: "copilot-pull-request-reviewer[bot]"}, commit_id: $c, submitted_at: $at, state: "COMMENTED", body: $b}'
}

run() { # run <args...>: "<last stdout line>|exit <n>"; every stdout line is kept in $tmp/out
	local code
	: >"$stub/calls"
	rm -f "$stub"/n-* # each run starts its fixture sequences at call 1
	PR_WAIT_GH="$tmp/gh" STUB_DIR="$stub" PR_WAIT_RETRY_DELAY=${PR_WAIT_RETRY_DELAY:-0} \
		bash "$script" "$@" -R o/r >"$tmp/out" 2>"$tmp/err"
	code=$?
	printf '%s|exit %s' "$(tail -n 1 "$tmp/out")" "$code"
}
lines() { wc -l <"$tmp/out" | tr -d ' '; }
calls() { grep -c "${1:-}" "$stub/calls" | tr -d ' '; }

# --- ci ----------------------------------------------------------------------

reset
fx pulls_7 "$(pr "$A")"
fx "commits_${A}_check-runs" "$(runs hooks:completed:success test:completed:skipped)"
fx "commits_${A}_status" "$(statuses)"
record "ci #7 aaaaaaaaaaaa: green 2 passed|exit 0" 'ci: every check passed' "$(run ci 7 --head "$A" --interval 0)"
record 1 'ci: one line for one state' "$(lines)"

fx "commits_${A}_check-runs" "$(runs hooks:completed:success lint:completed:failure test:in_progress:)"
record "ci #7 aaaaaaaaaaaa: failed lint (failure)|exit 1" 'ci: a failed check ends the wait at once' "$(run ci 7 --head "$A" --interval 0)"

fx "commits_${A}_check-runs" "$(runs hooks:completed:success)"
fx "commits_${A}_status" "$(statuses deploy:error)"
record "ci #7 aaaaaaaaaaaa: failed deploy (error)|exit 1" 'ci: a failed commit status fails it too' "$(run ci 7 --head "$A" --interval 0)"

reset
fx pulls_7 "$(pr "$A")"
fx "commits_${A}_check-runs.1" "$(runs)"
fx "commits_${A}_check-runs.2" "$(runs hooks:queued:)"
fx "commits_${A}_check-runs.3" "$(runs hooks:completed:stale)"
fx "commits_${A}_check-runs" "$(runs hooks:completed:success)"
fx "commits_${A}_status.1" "$(statuses)"
fx "commits_${A}_status.2" "$(statuses deploy:pending)"
fx "commits_${A}_status" "$(statuses deploy:success)"
record "ci #7 aaaaaaaaaaaa: green 2 passed|exit 0" 'ci: no checks yet, then pending, then green' "$(run ci 7 --head "$A" --interval 0)"
record "ci #7 aaaaaaaaaaaa: registering no checks reported yet" 'ci: the first line waits for checks to register' "$(head -n 1 "$tmp/out")"
record "ci #7 aaaaaaaaaaaa: pending 2 of 2 running: hooks, deploy" 'ci: a queued run and a pending status are pending' "$(sed -n 2p "$tmp/out")"
record "ci #7 aaaaaaaaaaaa: pending 1 of 2 running: hooks" 'ci: a stale conclusion is pending' "$(sed -n 3p "$tmp/out")"
record 4 'ci: one line per state change' "$(lines)"

reset
fx pulls_7 "$(pr "$A")"
fx "commits_${A}_check-runs" "$(runs)"
fx "commits_${A}_status" "$(statuses)"
record "ci #7 aaaaaaaaaaaa: none no check registered after 1s|exit 5" 'ci: no check ever registers (an empty combined status reads pending)' \
	"$(run ci 7 --head "$A" --interval 1s --settle 1s)"

# The head: GitHub can show the old one for a moment after a push, and a
# head that moves after it was seen ends the wait.
reset
fx pulls_7.1 "$(pr "$B")"
fx pulls_7 "$(pr "$A")"
fx "commits_${A}_check-runs" "$(runs hooks:completed:success)"
fx "commits_${A}_status" "$(statuses)"
record "ci #7 aaaaaaaaaaaa: green 1 passed|exit 0" 'ci: the PR catches up to the pushed head' "$(run ci 7 --head "$A" --interval 0)"
record "ci #7 aaaaaaaaaaaa: syncing the PR still shows $B" 'ci: while it shows the old head, it says so' "$(head -n 1 "$tmp/out")"
record 0 'ci: and reads no checks of the old head' "$(calls "commits_$B")"

reset
fx pulls_7.1 "$(pr "$A")"
fx pulls_7.2 "$(pr "$A")"
fx pulls_7 "$(pr "$B")"
fx "commits_${A}_check-runs" "$(runs hooks:in_progress:)"
fx "commits_${A}_status" "$(statuses)"
record "ci #7 aaaaaaaaaaaa: moved the head is now $B|exit 3" 'ci: a head that moves mid-wait' "$(run ci 7 --head "$A" --interval 0)"

reset
fx pulls_7 "$(pr "$B")"
record "ci #7 aaaaaaaaaaaa: moved the head is $B, not this one, after 1s|exit 3" 'ci: a head the PR never shows' \
	"$(run ci 7 --head "$A" --interval 1s --settle 1s)"

reset
fx pulls_7 "$(pr "$A" '' null unknown closed '"2026-11-19T00:00:00Z"')"
record "ci #7 aaaaaaaaaaaa: closed PR #7 is merged; nothing to wait for|exit 2" 'ci: a merged PR is an error, not a wait' "$(run ci 7 --head "$A" --interval 0)"

# Timeout: still pending when time runs out.
reset
fx pulls_7 "$(pr "$A")"
fx "commits_${A}_check-runs" "$(runs hooks:in_progress:)"
fx "commits_${A}_status" "$(statuses)"
record "ci #7 aaaaaaaaaaaa: timeout after 2s; last: pending 1 of 1 running: hooks|exit 4" 'ci: a timeout names the last state' \
	"$(run ci 7 --head "$A" --interval 1s --timeout 2s)"
record 1 'ci: and goes to stderr too' "$(grep -c 'timeout after 2s' "$tmp/err")"

# --- reads that fail ---------------------------------------------------------

# The #351 case: a check whose read errors on every call. It must end, with
# gh's error shown, not spin.
reset
fx pulls_7 "$(pr "$A")"
before=$SECONDS
got=$(STUB_FAIL='accepts at most 1 arg(s), received 4' run ci 7 --head "$A" --interval 0)
record "ci #7 aaaaaaaaaaaa: error a read failed 3 times in a row: accepts at most 1 arg(s), received 4|exit 2" \
	'errors: a read that keeps failing ends the wait' "$got"
record 3 'errors: after three tries (PR_WAIT_ATTEMPTS)' "$(calls)"
record yes "errors: gh's error is shown on each try" "$([ "$(grep -c 'accepts at most 1 arg' "$tmp/err")" -ge 3 ] && echo yes || echo no)"
record yes 'errors: in seconds' "$([ $((SECONDS - before)) -le 5 ] && echo yes || echo no)"
record "ci #7 aaaaaaaaaaaa: error a read failed 2 times in a row: accepts at most 1 arg(s), received 4|exit 2" \
	'errors: PR_WAIT_ATTEMPTS sets the tries' "$(PR_WAIT_ATTEMPTS=2 STUB_FAIL='accepts at most 1 arg(s), received 4' run ci 7 --head "$A" --interval 0)"
before=$SECONDS
PR_WAIT_RETRY_DELAY=1 STUB_FAIL=boom run ci 7 --head "$A" --interval 0 >/dev/null
record yes 'errors: the retry delay doubles (1s, then 2s)' "$([ $((SECONDS - before)) -ge 3 ] && echo yes || echo no)"

fx "commits_${A}_check-runs" "$(runs hooks:completed:success)"
fx "commits_${A}_status" "$(statuses)"
record "ci #7 aaaaaaaaaaaa: green 1 passed|exit 0" 'errors: one failed read is retried, then the wait goes on' \
	"$(STUB_FAIL_ONCE="commits_${A}_check-runs" run ci 7 --head "$A" --interval 0)"
record 1 'errors: and the retry says so on stderr' "$(grep -c 'read failed (try 1 of 3)' "$tmp/err")"

fx pulls_7 'not json'
got=$(run ci 7 --head "$A" --interval 0)
case $got in # jq words its parse error its own way
"ci #7 aaaaaaaaaaaa: error a read failed 3 times in a row: pr-wait.sh: unexpected reply from GitHub: jq: parse error"*"|exit 2") got=ok ;;
esac
record ok 'errors: a reply that is not JSON is a failed read' "$got"
fx pulls_7 '{"number":7}'
record "ci #7 aaaaaaaaaaaa: error a read failed 3 times in a row: pr-wait.sh: GitHub's reply for PR #7 has no head sha or state|exit 2" \
	'errors: a reply without a head is a failed read' "$(run ci 7 --head "$A" --interval 0)"

# --- review (Copilot) --------------------------------------------------------

green='### 🟢 Approval recommended

Nothing to change.'
reset
fx pulls_7 "$(pr "$A")"
fx pulls_7_reviews "[$(review 11 "$A" 2026-11-19T01:00:00Z "$green")]"
fx pulls_7_reviews_11_comments '[]'
record "review #7 aaaaaaaaaaaa: clean review 11: Approval recommended|exit 0" 'review: a green review with nothing in it' "$(run review 7 --head "$A" --interval 0)"

fx pulls_7_reviews_11_comments '[{"id":1}]'
record "review #7 aaaaaaaaaaaa: findings review 11: Approval recommended, 1 comments, body sections counting 0|exit 1" \
	'review: a green verdict with a comment of its own has findings' "$(run review 7 --head "$A" --interval 0)"

fx pulls_7_reviews_11_comments '[]'
fx pulls_7_reviews "[$(review 11 "$A" 2026-11-19T01:00:00Z "<!-- ccr-overview-v2 -->
## Copilot review overview

### 🟢 Approval recommended
<details><summary><strong>Previously missed (2)</strong></summary>")]"
record "review #7 aaaaaaaaaaaa: findings review 11: Approval recommended, 0 comments, body sections counting 2|exit 1" \
	'review: a green v2 verdict with body entries has findings' "$(run review 7 --head "$A" --interval 0)"

fx pulls_7_reviews "[$(review 10 "$B" 2026-11-19T00:00:00Z "$green"),$(review 11 "$A" 2026-11-19T01:00:00Z '### 🟡 Changes recommended

Two moderate findings.')]"
record "review #7 aaaaaaaaaaaa: findings review 11: Changes recommended, 0 comments, body sections counting 0|exit 1" \
	'review: a yellow verdict has findings, even with no threads' "$(run review 7 --head "$A" --interval 0)"

# Pending, by request and then by its check run, then the review lands.
reset
fx pulls_7.1 "$(pr "$A" Copilot)"
fx pulls_7 "$(pr "$A")"
fx pulls_7_reviews.1 '[]'
fx pulls_7_reviews.2 '[]'
fx pulls_7_reviews "[$(review 11 "$A" 2026-11-19T01:00:00Z "$green")]"
fx "commits_${A}_check-runs" "$(runs copilot-pull-request-reviewer:in_progress:)"
fx pulls_7_reviews_11_comments '[]'
record "review #7 aaaaaaaaaaaa: clean review 11: Approval recommended|exit 0" 'review: pending, then the review lands' "$(run review 7 --head "$A" --interval 0)"
record "review #7 aaaaaaaaaaaa: pending requested or running" 'review: one line while pending, by request or by run' "$(head -n 1 "$tmp/out")"
record 2 'review: and one for the review' "$(lines)"

# Idle: a review of an older head only, and nothing pending.
reset
fx pulls_7 "$(pr "$A")"
fx pulls_7_reviews "[$(review 10 "$B" 2026-11-19T00:00:00Z "$green")]"
fx "commits_${A}_check-runs" "$(runs hooks:completed:success copilot-pull-request-reviewer:completed:success)"
record "review #7 aaaaaaaaaaaa: idle Copilot is neither requested nor running, for 1s|exit 5" 'review: a bot that never starts ends the wait (--idle)' \
	"$(run review 7 --head "$A" --interval 1s --idle 1s)"
record "review #7 aaaaaaaaaaaa: quiet Copilot is neither requested nor running; waiting up to 1s for copilot to start" \
	'review: it waits --idle first' "$(head -n 1 "$tmp/out")"

# Unable to review: reported at once, unless a retry was requested after it.
unable='Copilot was unable to review this pull request because the user who requested the review has reached their quota limit.'
reset
fx pulls_7 "$(pr "$A")"
fx pulls_7_reviews "[$(review 12 "$A" 2026-11-19T02:00:00Z "$unable")]"
fx "commits_${A}_check-runs" "$(runs)"
fx issues_7_timeline '[{"event":"review_requested","requested_reviewer":{"login":"Copilot"},"created_at":"2026-11-19T01:59:00Z"}]'
record "review #7 aaaaaaaaaaaa: unable review 12: Copilot was unable to review this head|exit 5" 'review: an unable body' "$(run review 7 --head "$A" --interval 0)"
fx pulls_7_reviews "[$(review 12 "$A" 2026-11-19T02:00:00Z "<!-- ccr-overview-v2 -->
## Copilot review overview

$unable")]"
record "review #7 aaaaaaaaaaaa: unable review 12: Copilot was unable to review this head|exit 5" 'review: an unable v2 body' "$(run review 7 --head "$A" --interval 0)"
fx issues_7_timeline '[{"event":"review_requested","requested_reviewer":{"login":"Copilot"},"created_at":"2026-11-19T02:01:00Z"}]'
record "review #7 aaaaaaaaaaaa: idle a retry was requested after unable review 12, and nothing is pending, for 1s|exit 5" \
	'review: a retry that never starts is idle, not unable' "$(run review 7 --head "$A" --interval 1s --idle 1s)"
fx pulls_7.1 "$(pr "$A" Copilot)"
fx pulls_7_reviews.2 "[$(review 12 "$A" 2026-11-19T02:00:00Z "$unable")]"
fx pulls_7_reviews "[$(review 12 "$A" 2026-11-19T02:00:00Z "$unable"),$(review 13 "$A" 2026-11-19T02:05:00Z "$green")]"
fx pulls_7_reviews_13_comments '[]'
record "review #7 aaaaaaaaaaaa: clean review 13: Approval recommended|exit 0" 'review: a pending retry, then a real review' "$(run review 7 --head "$A" --interval 0)"

reset
fx pulls_7 "$(pr "$A")"
fx pulls_7_reviews '[]'
fx pulls_7.2 "$(pr "$B")"
fx "commits_${A}_check-runs" "$(runs copilot-pull-request-reviewer:in_progress:)"
record "review #7 aaaaaaaaaaaa: moved the head is now $B|exit 3" 'review: a head that moves mid-wait' "$(run review 7 --head "$A" --interval 0)"

# --- mergeable ---------------------------------------------------------------

reset
fx pulls_7.1 "$(pr "$A")"
fx pulls_7.2 "$(pr "$A" '' true unknown)"
fx pulls_7 "$(pr "$A" '' true behind)"
record "mergeable #7 aaaaaaaaaaaa: mergeable MERGEABLE BEHIND|exit 0" 'mergeable: computing, then known (in gh spelling)' "$(run mergeable 7 --interval 0)"
record "mergeable #7 aaaaaaaaaaaa: computing UNKNOWN UNKNOWN" 'mergeable: UNKNOWN in both fields is still computing' "$(head -n 1 "$tmp/out")"
record "mergeable #7 aaaaaaaaaaaa: computing MERGEABLE UNKNOWN" 'mergeable: and in either one' "$(sed -n 2p "$tmp/out")"
record 3 'mergeable: one line per change' "$(lines)"

fx pulls_7 "$(pr "$A" '' false dirty)"
record "mergeable #7 aaaaaaaaaaaa: conflicting CONFLICTING DIRTY|exit 1" 'mergeable: conflicting' "$(run mergeable 7 --interval 0)"

reset
fx pulls_7.1 "$(pr "$A")"
fx pulls_7 "$(pr "$B" '' true clean)"
record "mergeable #7 aaaaaaaaaaaa: moved the head is now $B|exit 3" 'mergeable: pins the head it reads first' "$(run mergeable 7 --interval 0)"
record "mergeable #7 aaaaaaaaaaaa: moved the head is now $B|exit 3" 'mergeable: or the --head given' "$(run mergeable 7 --head "$A" --interval 0)"

# --- usage and repo ----------------------------------------------------------

reset
fx pulls_7 "$(pr "$A" '' true clean)"
usage() { # usage <args...>: "exit <n>", plus "+msg" when stderr says why
	local got
	got=$(run "$@")
	printf 'exit %s%s' "${got##*exit }" "$([ -s "$tmp/err" ] && printf '+msg')"
}
record 'exit 2+msg' 'usage: an unknown subcommand' "$(usage wait 7)"
record 'exit 2+msg' 'usage: a PR that is not a number' "$(usage ci 7x --head "$A")"
record 'exit 2+msg' 'usage: ci needs --head' "$(usage ci 7)"
record 'exit 2+msg' 'usage: a short sha' "$(usage ci 7 --head aaaaaaa)"
record 'exit 2+msg' 'usage: a bad duration' "$(usage ci 7 --head "$A" --timeout soon)"
record 'exit 2+msg' 'usage: --idle is for review' "$(usage ci 7 --head "$A" --idle 1m)"
record 'exit 2+msg' 'usage: an option with no value' "$(usage ci 7 --head)"
record 'exit 2+msg' 'usage: an unknown bot' "$(usage review 7 --head "$A" --bot nobot)"
record 1 'usage: an unknown bot names the known ones' "$(grep -c 'known: copilot' "$tmp/err")"
record 0 'usage: and reads nothing' "$(calls)"

: >"$stub/calls"
PR_WAIT_GH="$tmp/gh" STUB_DIR="$stub" bash "$script" mergeable 7 -R ghe.example.com/o/r --interval 0 >/dev/null 2>&1
record 'api repos/o/r/pulls/7 --hostname ghe.example.com' '-R: a host goes to gh as --hostname' "$(head -n 1 "$stub/calls")"
PR_WAIT_GH="$tmp/gh" STUB_DIR="$stub" bash "$script" mergeable 7 -R 'o/r;x' --interval 0 >/dev/null 2>&1
record 2 '-R: a repo with shell characters is refused' "$?"

finish
