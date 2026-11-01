#!/usr/bin/env bash
# Tests for scripts/pr-subscription.sh, which subscribes a session's PR to the
# pr-notifier (START Step 7) and unsubscribes it (FINISH Step 3), through the
# notifier's stable path. The notifier is replaced by a stub:
#   STUB_OUT     what the stub prints for subscribe/unsubscribe
#   STUB_RC      the exit code it gives them
#   STUB_STATUS  what `status --json` prints; STUB_STATUS_RC its exit code
# Every call is logged as "<args> sid=<CLAUDE_CODE_SESSION_ID>" to $STUB_ARGS.
# The doc cases run the one-liners the docs show, pulled out of them.
#
#   bash plugins/ticket-workflow/tests/test-pr-subscription.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
skill="$plugin/skills/ticket-workflow"
script="$plugin/scripts/pr-subscription.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

mkdir -p "$tmp/home/.local/bin"
stub="$tmp/home/.local/bin/pr-notifier"
cat >"$stub" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s sid=%s\n' "$*" "${CLAUDE_CODE_SESSION_ID:-}" >>"$STUB_ARGS"
if [ "$1" = status ]; then
	printf '%s\n' "${STUB_STATUS:-}"
	exit "${STUB_STATUS_RC:-0}"
fi
[ -z "${STUB_OUT:-}" ] || printf '%s\n' "$STUB_OUT"
exit "${STUB_RC:-0}"
STUB_EOF
chmod +x "$stub"
export STUB_ARGS="$tmp/args"
sid=0b2c4d6e-1111-4222-8333-444455556666

# run [VAR=value ...] -- [script args...]: runs the script in a clean
# environment (HOME is the fixture home, where the stub sits at the stable
# path), and leaves its exit code in $rc, its stdout in $out, and the stub's
# calls in $calls (one per line).
run() {
	local -a vars=()
	while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
	shift
	: >"$STUB_ARGS"
	out=$(env -i PATH="$PATH" HOME="$tmp/home" STUB_ARGS="$STUB_ARGS" "${vars[@]}" \
		bash "$script" "$@" 2>"$tmp/err")
	rc=$?
	calls=$(cat "$STUB_ARGS")
}
lines() { printf '%s' "$1" | grep -c ''; }

# --- subscribe ------------------------------------------------------------

run CLAUDE_CODE_SESSION_ID=$sid STUB_OUT="pr-notifier: subscribed 0b2c4d6e to maguerrieri/claude-toolbox#301" \
	-- subscribe https://github.com/maguerrieri/claude-toolbox/pull/301
record 0 "subscribe by URL: exit" "$rc"
record "subscribe maguerrieri/claude-toolbox#301 sid=$sid" "subscribe by URL: the notifier gets the ref, with the session's id" "$calls"
record "pr-subscription: pr-notifier: subscribed 0b2c4d6e to maguerrieri/claude-toolbox#301" \
	"subscribe by URL: relays the notifier's line" "$out"

run CLAUDE_CODE_SESSION_ID=$sid -- subscribe https://github.com/o/r/pull/7/
record "subscribe o/r#7 sid=$sid" "a trailing slash on the URL" "$calls"
record "pr-subscription: pr-notifier subscribe o/r#7: done" "a notifier that prints nothing still reads as done" "$out"

run CLAUDE_CODE_SESSION_ID=$sid -- subscribe Some-Org/repo.name#12
record "subscribe Some-Org/repo.name#12 sid=$sid" "subscribe by <owner>/<repo>#<n>" "$calls"

# Not a PR this notifier watches, or not a PR at all: a usage error, and the
# notifier never runs.
for bad in https://github.example.com/o/r/pull/7 https://github.com/o/r/issues/7 \
	https://github.com/o/r/pull/7/files 'o/r#7; rm -rf x' o/r 'o/.#7' 'o/..#7' '-o/r#7' ''; do
	run CLAUDE_CODE_SESSION_ID=$sid -- subscribe "$bad"
	record "2 0" "rejects '$bad'" "$rc $(lines "$calls")"
done
run CLAUDE_CODE_SESSION_ID=$sid -- subscribe o/r#1 o/r#2
record 2 "two PRs" "$rc"
run CLAUDE_CODE_SESSION_ID=$sid -- subscribe o/r#1 --all
record 2 "--all is for unsubscribe only" "$rc"
run CLAUDE_CODE_SESSION_ID=$sid -- resubscribe o/r#1
record 2 "an unknown subcommand" "$rc"

# --- skips: nothing to do, and nothing alarming ---------------------------

run CLAUDE_CODE_SESSION_ID=$sid CLAUDE_CODE_REMOTE=true -- subscribe o/r#1
record "0 0" "a cloud session skips, without calling the notifier" "$rc $(lines "$calls")"
record yes "the cloud skip says why" "$(case $out in *"cloud session"*) echo yes ;; *) echo "no: $out" ;; esac)"

mv "$stub" "$tmp/stub.away"
run CLAUDE_CODE_SESSION_ID=$sid -- subscribe o/r#1
record 0 "no notifier installed: exit 0" "$rc"
record "pr-subscription: pr-notifier isn't installed here ($tmp/home/.local/bin/pr-notifier), so o/r#1 wasn't subscribed; nothing wakes this session on it" \
	"no notifier installed: one plain line" "$out"
record "" "no notifier installed: nothing on stderr" "$(cat "$tmp/err")"
run CLAUDE_CODE_SESSION_ID=$sid -- unsubscribe o/r#1 --all
record 0 "no notifier installed: unsubscribe --all skips too" "$rc"
mv "$tmp/stub.away" "$stub"

# The stable path, and only the stable path: no notifier there means none.
run CLAUDE_CODE_SESSION_ID=$sid PR_SUBSCRIPTION_CLI="$tmp/nowhere" -- subscribe o/r#1
record "0 0" "the override path missing reads as not installed" "$rc $(lines "$calls")"

# --- failures -------------------------------------------------------------

run -- subscribe o/r#1
record "1 0" "no session id: exit 1, the notifier never runs" "$rc $(lines "$calls")"
record "pr-subscription: no session id (CLAUDE_CODE_SESSION_ID), so o/r#1 wasn't subscribed" "no session id: says so" "$out"

run CLAUDE_CODE_SESSION_ID=$sid STUB_RC=1 STUB_OUT=$'pr-notifier: another pr-notifier command has held the lock\nfor five minutes' \
	-- subscribe o/r#1
record 1 "the notifier fails: exit 1" "$rc"
record "pr-subscription: pr-notifier subscribe o/r#1 failed (exit 1): pr-notifier: another pr-notifier command has held the lock for five minutes" \
	"the notifier fails: its output on one line" "$out"

# --- unsubscribe ----------------------------------------------------------

run CLAUDE_CODE_SESSION_ID=$sid -- unsubscribe https://github.com/o/r/pull/9
record "0 unsubscribe o/r#9 sid=$sid" "unsubscribe this session" "$rc $calls"

other=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
status='{"subscriptions":[
 {"pr":"o/r#9","session_id":"'$sid'","name":"a"},
 {"pr":"o/r#10","session_id":"'$other'","name":"b"},
 {"pr":"o/r#9","session_id":"'$other'","name":"c"}],"pending":{},"feed":{}}'
run STUB_STATUS="$status" -- unsubscribe O/R#9 --all
record 0 "--all: exit" "$rc"
record "status --json sid=
unsubscribe O/R#9 --session $sid sid=
unsubscribe O/R#9 --session $other sid=" \
	"--all: every session on the PR (matched case-insensitively), none on another, with no session id needed" "$calls"
record 2 "--all: one line per session" "$(lines "$out")"

run STUB_STATUS='{"subscriptions":[{"pr":"o/r#10","session_id":"'$other'"}]}' -- unsubscribe o/r#9 --all
record "0 pr-subscription: no subscriptions on o/r#9" "--all with none on the PR" "$rc $out"

run STUB_STATUS='{"subscriptions":[]}' STUB_STATUS_RC=1 -- unsubscribe o/r#9 --all
record "1 1" "--all when status fails: exit 1, no unsubscribe" "$rc $(lines "$calls")"

run STUB_STATUS='not json' -- unsubscribe o/r#9 --all
record "1 1" "--all when status isn't a listing: exit 1, no unsubscribe" "$rc $(lines "$calls")"

run STUB_STATUS="$status" STUB_RC=1 -- unsubscribe o/r#9 --all
record "1 3" "--all keeps going past a failed unsubscribe, and fails" "$rc $(lines "$calls")"

# --- every run prints exactly one line, or one per session for --all -----

for args in "subscribe o/r#1" "unsubscribe o/r#1"; do
	run CLAUDE_CODE_SESSION_ID=$sid STUB_OUT=$'line one\nline two' -- ${args}
	record 1 "one line of output: $args" "$(lines "$out")"
done

# --- the docs' one-liners --------------------------------------------------

# Prints the first line inside a fenced code block of <file> that ends with
# <text> (so `unsubscribe <pr url>` doesn't match the `--all` line).
fenced_line() { # fenced_line <file> <text>
	awk -v text="$2" '
		/^[ \t]*```/ { in_block = !in_block; next }
		in_block && length($0) >= length(text) &&
			substr($0, length($0) - length(text) + 1) == text { print; exit }
	' "$1"
}

# Runs the fenced line of <file> that ends with <text>, as the docs show it,
# with its placeholders filled in and the plugin root pointing at this checkout.
run_doc() { # run_doc <file> <text> [VAR=value ...]
	local file=$1 text=$2 line
	shift 2
	line=$(fenced_line "$file" "$text" | sed -e 's|<pr url>|https://github.com/o/r/pull/5|g')
	record yes "doc line found: $text in ${file#"$skill"/}" "$([ -n "$line" ] && echo yes || echo no)"
	: >"$STUB_ARGS"
	env -i PATH="$PATH" HOME="$tmp/home" STUB_ARGS="$STUB_ARGS" CLAUDE_TICKET_WORKFLOW_ROOT="$plugin" "$@" \
		bash -c "$line" >/dev/null 2>&1
	calls=$(cat "$STUB_ARGS")
}

run_doc "$skill/SKILL.md" 'pr-subscription.sh" subscribe <pr url>' CLAUDE_CODE_SESSION_ID=$sid
record "subscribe o/r#5 sid=$sid" "START Step 7's subscribe runs as documented" "$calls"
run_doc "$skill/notifier.md" 'pr-subscription.sh" subscribe <pr url>' CLAUDE_CODE_SESSION_ID=$sid
record "subscribe o/r#5 sid=$sid" "notifier.md's subscribe runs as documented" "$calls"
run_doc "$skill/notifier.md" 'pr-subscription.sh" unsubscribe <pr url>' CLAUDE_CODE_SESSION_ID=$sid
record "unsubscribe o/r#5 sid=$sid" "notifier.md's unsubscribe runs as documented" "$calls"
run_doc "$skill/phases/finish.md" 'pr-subscription.sh" unsubscribe <pr url> --all' \
	STUB_STATUS='{"subscriptions":[{"pr":"o/r#5","session_id":"'$other'"}]}'
record "status --json sid=
unsubscribe o/r#5 --session $other sid=" "FINISH Step 3's unsubscribe --all runs as documented" "$calls"

finish
