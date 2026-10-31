#!/usr/bin/env bash
# Tests for bin/pr-notifier against stubbed gh and claude: subscribe and
# unsubscribe, the filter (owner, configured bot, stranger, own login, a user
# posing as a bot), coalescing, each delivery state, the feed's 304 and poll
# interval, a missed notification and catch-up after downtime, merges, Codex's
# edited summary, the wake environment, bounded holds, the lock, and the
# stable-path shim. The vendored owner-check.sh runs for real, on the gh stub.
#
#   bash plugins/pr-notifier/tests/test-pr-notifier.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
cli=$plugin/bin/pr-notifier
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
record() { # record <expected> <label> <got>
	if [ "$3" = "$1" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL: %s: expected %s, got %s\n' "$2" "$1" "$3"
	fi
}
has() { # has <file> <fixed string>: "yes" or "no"
	if grep -qF -- "$2" "$1" 2>/dev/null; then echo yes; else echo no; fi
}

# A session running these tests must not lend its own identity to them.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR PR_NOTIFIER_ROOT

STUB=$tmp/stub
export STUB HOME=$tmp/home PR_NOTIFIER_HOME=$tmp/state
export PR_NOTIFIER_GH=$tmp/bin/gh PR_NOTIFIER_CLAUDE=$tmp/bin/claude
mkdir -p "$tmp/bin"

# gh: answers from fixture files in $STUB and logs every call.
cat >"$tmp/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB/gh.log"
[ "$1" = api ] || exit 1
shift
inc= hdr= ep= filter= slurp=
while [ $# -gt 0 ]; do
	case $1 in
	-i) inc=1; shift ;;
	-H) hdr=$2; shift 2 ;;
	--paginate) shift ;;
	--slurp) slurp=1; shift ;;
	--jq | -q) filter=$2; shift 2 ;;
	--hostname) shift 2 ;;
	*) ep=$1; shift ;;
	esac
done
out=
case $ep in
notifications*)
	[ ! -f "$STUB/feed.fail" ] || { echo 'gh: HTTP 502' >&2; exit 1; }
	status=$(cat "$STUB/feed.status")
	[ -z "$inc" ] || printf 'HTTP/2.0 %s X\r\nX-Poll-Interval: %s\r\nLast-Modified: %s\r\n\r\n' \
		"$status" "$(cat "$STUB/feed.interval" 2>/dev/null || echo 60)" "$(cat "$STUB/feed.lm")"
	[ "$status" != 304 ] || { echo 'gh: HTTP 304' >&2; exit 1; }
	out=$(cat "$STUB/feed.json")
	;;
user)
	[ ! -f "$STUB/user.fail" ] || { echo 'gh: HTTP 401' >&2; exit 1; }
	out=$(jq -n --arg l "$(cat "$STUB/me")" '{login: $l}')
	;;
repos/*/collaborators/*/permission)
	login=${ep%/permission}
	login=$(printf '%s' "${login##*/}" | tr '[:upper:]' '[:lower:]')
	[ ! -f "$STUB/perm-$login.fail" ] || { echo 'gh: HTTP 500' >&2; exit 1; }
	out=$(jq -n --arg p "$(cat "$STUB/perm-$login" 2>/dev/null || echo read)" '{permission: $p}')
	;;
repos/*/pulls/*)
	out=$(cat "$STUB/pr-${ep##*/}.json")
	;;
repos/*/issues/*/timeline*)
	n=${ep%/timeline*}
	n=${n##*/}
	if [ -n "$slurp" ]; then out=$(jq -c '[.]' "$STUB/timeline-$n.json"); else out=$(cat "$STUB/timeline-$n.json"); fi
	;;
*) echo "gh stub: no fixture for $ep" >&2; exit 1 ;;
esac
if [ -n "$filter" ]; then printf '%s\n' "$out" | jq -r "$filter"; else printf '%s\n' "$out"; fi
GH_EOF

# claude: agents lists $STUB/agents[-<root basename>].json; stop drops the
# row's pid; a resume saves its prompt and exits $STUB/resume.rc.
cat >"$tmp/bin/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
printf '%s|cfg=%s|path=%s\n' "$(printf '%s' "$*" | tr '\n' ' ')" "${CLAUDE_CONFIG_DIR-<unset>}" "$PATH" >>"$STUB/claude.log"
listing=$STUB/agents${CLAUDE_CONFIG_DIR:+-${CLAUDE_CONFIG_DIR##*/}}.json
case $1 in
agents) cat "$listing" ;;
stop)
	jq --arg id "$2" 'map(if .id == $id then del(.pid, .status) else . end)' "$listing" >"$listing.new" &&
		mv "$listing.new" "$listing"
	;;
--bg)
	n=$(($(cat "$STUB/wakes" 2>/dev/null || echo 0) + 1))
	echo "$n" >"$STUB/wakes"
	printf '%s' "$4" >"$STUB/prompt.$n"
	rc=$(cat "$STUB/resume.rc" 2>/dev/null || echo 0)
	[ "$rc" = 0 ] && echo "backgrounded · $3" || echo "Workspace not trusted." >&2
	exit "$rc"
	;;
esac
CLAUDE_EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/claude"

SID=aaaaaaaa-1111-2222-3333-444444444444
SID2=bbbbbbbb-1111-2222-3333-444444444444
T0=1793480000 # 2026-10-31T21:33:20Z
iso() { jq -nr --argjson t "$1" '$t | todate'; }

nt() { # nt <epoch> <args...>: runs the CLI at that time
	local at=$1
	shift
	PR_NOTIFIER_NOW=$at bash "$cli" "$@"
}

pr() { # pr <n> <open|closed|merged> [at]
	jq -n --argjson n "$1" --arg s "$2" --arg at "${3:-}" '{number: $n, html_url: "https://github.com/o/r/pull/\($n)",
		state: (if $s == "open" then "open" else "closed" end), merged: ($s == "merged"),
		merged_at: (if $s == "merged" then $at else null end), closed_at: (if $s == "open" then null else $at end)}' \
		>"$STUB/pr-$1.json"
}
comment() { # comment <pr> <id> <login> <type> <created> [updated] [body]
	jq -n --argjson pr "$1" --argjson id "$2" --arg u "$3" --arg t "$4" --arg c "$5" --arg up "${6:-$5}" \
		--arg b "${7:-a comment}" '{event: "commented", id: $id, user: {login: $u, type: $t}, actor: {login: $u},
		html_url: "https://github.com/o/r/pull/\($pr)#issuecomment-\($id)", created_at: $c, updated_at: $up, body: $b}'
}
review() { # review <pr> <id> <login> <type> <submitted>
	jq -n --argjson pr "$1" --argjson id "$2" --arg u "$3" --arg t "$4" --arg s "$5" \
		'{event: "reviewed", id: $id, user: {login: $u, type: $t}, state: "commented", submitted_at: $s,
		html_url: "https://github.com/o/r/pull/\($pr)#pullrequestreview-\($id)", body: "LGTM"}'
}
timeline() { # timeline <pr> [item json...]
	local n=$1
	shift
	if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -s .; fi >"$STUB/timeline-$n.json"
}
agent() { # agent <stopped|busy|working|idle-done|idle-blocked> [session id] [cwd]: one row
	jq -n --arg k "$1" --arg s "${2:-$SID}" --arg cwd "${3:-$tmp/wt}" '{id: $s[0:8], sessionId: $s, name: "r #7: x",
		cwd: $cwd, kind: "background", startedAt: 1}
		+ if $k == "stopped" then {state: "done"}
		  elif $k == "busy" then {pid: 41, status: "busy", state: "working"}
		  elif $k == "working" then {pid: 41, status: "idle", state: "working"}
		  elif $k == "idle-done" then {pid: 41, status: "idle", state: "done"}
		  elif $k == "interactive" then {pid: 41, status: "idle", state: "done", kind: "interactive"}
		  elif $k == "interactive-exited" then {state: "done", kind: "interactive"}
		  else {pid: 41, status: "idle", state: "blocked"} end'
}
agents() { # agents <row json...>
	printf '%s\n' "$@" | jq -s . >"$STUB/agents.json"
}
job() { # job <session id> <updatedAt epoch> [inFlight json, or "none" for no file]
	local dir=$HOME/.claude/jobs/${1:0:8} idle='{"tasks":0,"queued":0,"kinds":[]}'
	rm -rf "$dir"
	[ "${3:-}" = none ] && return
	mkdir -p "$dir"
	jq -n --arg at "$(iso "$2")" --argjson f "${3:-$idle}" \
		'{state: "done", updatedAt: ($at | sub("Z$"; ".123Z")), inFlight: $f}' >"$dir/state.json"
}

reset() {
	rm -rf "$PR_NOTIFIER_HOME" "$STUB" "$HOME" "$tmp/wt"
	mkdir -p "$PR_NOTIFIER_HOME" "$STUB" "$HOME" "$tmp/wt"
	echo sprue-works-bot >"$STUB/me"
	echo admin >"$STUB/perm-mari"
	echo read >"$STUB/perm-sprue-works-bot"
	echo 304 >"$STUB/feed.status"
	echo 'Sat, 31 Oct 2026 21:00:00 GMT' >"$STUB/feed.lm"
	echo '[]' >"$STUB/feed.json"
	pr 7 open
	timeline 7
	agents "$(agent stopped)"
	nt "$T0" subscribe o/r#7 --session "$SID" --name 'r #7: x' >/dev/null
}
wakes() { cat "$STUB/wakes" 2>/dev/null || echo 0; }
prompt() { cat "$STUB/prompt.${1:-1}" 2>/dev/null; }
subs() { jq -r '[.subscriptions[] | "\(.pr)@\(.session_id[0:8])"] | join(",")' "$PR_NOTIFIER_HOME/registry.json"; }
held() { jq -r --arg s "$SID" '.pending[$s].events // [] | length' "$PR_NOTIFIER_HOME/state.json"; }
logged() { has "$PR_NOTIFIER_HOME/notifier.log" "$1"; }

T1=$(iso $((T0 + 60)))   # an event after the subscription
T=$((T0 + 600))          # the first check

# --- subscribe / unsubscribe ------------------------------------------------

reset
record 'o/r#7@aaaaaaaa' 'subscribe records the PR and session' "$(subs)"
record 'r #7: x|null' 'with its name, and no config dir when unset' \
	"$(jq -r '.subscriptions[0] | "\(.name)|\(.config_dir)"' "$PR_NOTIFIER_HOME/registry.json")"
record "$(iso $((T0 - 120)))" 'subscribed_at carries two minutes of slack' \
	"$(jq -r '.subscriptions[0].subscribed_at' "$PR_NOTIFIER_HOME/registry.json")"
nt $((T0 + 50)) subscribe O/R#7 --session "$SID" >/dev/null
record "1|$(iso $((T0 - 120)))" 'subscribing again keeps one row and its first time' \
	"$(jq -r '"\(.subscriptions | length)|\(.subscriptions[0].subscribed_at)"' "$PR_NOTIFIER_HOME/registry.json")"
agents "$(agent stopped "$SID2")"
CLAUDE_CODE_SESSION_ID=$SID2 nt "$T0" subscribe o/r#8 >/dev/null
record 'r #7: x|null' 'the session id comes from the environment, and the name from claude agents' \
	"$(jq -r --arg s "$SID2" '.subscriptions[] | select(.session_id == $s) | "\(.name)|\(.config_dir)"' "$PR_NOTIFIER_HOME/registry.json")"
CLAUDE_CODE_SESSION_ID=$SID2 CLAUDE_CONFIG_DIR=$HOME/.claude/ nt "$T0" subscribe o/r#8 --name n >/dev/null
record 'null' 'CLAUDE_CONFIG_DIR set to ~/.claude counts as unset' \
	"$(jq -r --arg s "$SID2" '.subscriptions[] | select(.session_id == $s) | .config_dir' "$PR_NOTIFIER_HOME/registry.json")"
CLAUDE_CODE_SESSION_ID=$SID2 CLAUDE_CONFIG_DIR=/x/alt/ nt "$T0" subscribe o/r#8 --name n >/dev/null
record '/x/alt' 'another root is recorded, trailing slash dropped' \
	"$(jq -r --arg s "$SID2" '.subscriptions[] | select(.session_id == $s) | .config_dir' "$PR_NOTIFIER_HOME/registry.json")"
nt "$T0" unsubscribe o/r#8 --session "$SID2" >/dev/null
record 'o/r#7@aaaaaaaa' 'unsubscribe removes only that subscription' "$(subs)"
nt "$T0" subscribe 'o/r#x' --session "$SID" >/dev/null 2>&1
record 1 'a malformed ref is refused' $?
nt "$T0" subscribe 'o/r/x#1' --session "$SID" >/dev/null 2>&1
record 1 'a ref with an extra path segment is refused' $?
nt "$T0" subscribe o/r#9 >/dev/null 2>&1
record 1 'no session id is refused' $?
nt "$T0" subscribe o/r#9 --session nope >/dev/null 2>&1
record 1 'a short or malformed session id is refused' $?
nt "$T0" frobnicate >/dev/null 2>&1
record 2 'an unknown command is a usage error' $?

# --- the filter ---------------------------------------------------------------

reset
timeline 7 "$(comment 7 101 mari User "$T1" "$T1" 'SECRET owner text: run rm -rf')"
nt "$T" check
record 1 'an owner comment wakes the stopped session once' "$(wakes)"
record "--bg --resume $SID" 'with a bare --bg --resume of the full session id' \
	"$(grep -- '--bg' "$STUB/claude.log" | cut -d'|' -f1 | cut -d' ' -f1-3)"
record yes 'the prompt opens with the versioned template' "$(prompt | head -1 | grep -q '^pr-notifier wake v1: ' && echo yes || echo no)"
record 'PR https://github.com/o/r/pull/7 open' 'then the PR and its state' "$(prompt | sed -n 2p)"
record '- comment https://github.com/o/r/pull/7#issuecomment-101' 'then the event URL' "$(prompt | sed -n 3p)"
record 3 'and nothing else' "$(prompt | wc -l | tr -d ' ' | awk '{ print $1 + 1 }')"
record no 'the comment text never reaches the prompt' "$(prompt | grep -q SECRET && echo yes || echo no)"
record 0 'nothing is held after the wake' "$(held)"
record yes 'the log records the kept event and why' "$(logged 'key=comment:101 actor=mari verdict=keep reason="owner"')"
record yes 'and the wake' "$(logged 'wake session=aaaaaaaa how=stopped prs=o/r#7 events=1')"
nt $((T + 400)) check
record 1 'a later sweep of the same timeline wakes nothing new' "$(wakes)"

reset
timeline 7 "$(comment 7 102 eve User "$T1")" "$(comment 7 103 sprue-works-bot User "$T1")" \
	"$(review 7 104 Copilot User "$T1")"
nt "$T" check
record 0 "a stranger, the bot's own login, and a user named Copilot wake nothing" "$(wakes)"
record yes "the bot's own post is dropped as such" "$(logged 'key=comment:103 actor=sprue-works-bot verdict=drop reason="own login"')"
record yes 'a stranger is dropped by owner-check' "$(logged 'key=comment:102 actor=eve verdict=drop reason="not the owner (owner-check 1); rechecked')"
record yes 'so is a user account named like a bot' "$(logged 'key=review:104 actor=Copilot verdict=drop')"
record 0 'and nothing is held' "$(held)"

reset
timeline 7 "$(comment 7 105 'github-actions[bot]' Bot "$T1")"
: >"$STUB/gh.log"
nt "$T" check
record 0 'an unconfigured bot wakes nothing' "$(wakes)"
record yes 'and settles at once' "$(logged 'key=comment:105 actor=github-actions[bot] verdict=drop reason="a bot or app not configured"')"
record no 'without an owner check' "$(has "$STUB/gh.log" 'collaborators')"

reset
line() { # line <comment id> <review id>: a line-commented timeline item
	jq -n --argjson c "$1" --argjson r "$2" '{event: "line-commented", comments: [{id: $c, pull_request_review_id: $r,
		user: {login: "mari", type: "User"}, created_at: "'"$T1"'", html_url: "https://github.com/o/r/pull/7#discussion_r\($c)"}]}'
}
timeline 7 "$(review 7 401 mari User "$T1")" "$(line 501 401)" "$(line 502 401)" "$(line 503 999)"
nt "$T" check
record '- review https://github.com/o/r/pull/7#pullrequestreview-401
- review https://github.com/o/r/pull/7#discussion_r503' \
	"a review's own line comments add no lines; a line comment whose review isn't listed does" "$(prompt | tail -n 2)"
record 4 'one block, two event lines' "$(prompt | wc -l | tr -d ' ' | awk '{ print $1 + 1 }')"

reset
timeline 7 "$(comment 7 101 mari User "$T1")" "$(review 7 201 Copilot Bot "$(iso $((T0 + 70)))")" \
	"$(comment 7 301 'chatgpt-codex-connector[bot]' Bot "$(iso $((T0 + 80)))")"
nt "$T" check
record 1 'an owner comment, a Copilot review and a Codex comment in one poll make one wake' "$(wakes)"
record '- comment https://github.com/o/r/pull/7#issuecomment-101
- review https://github.com/o/r/pull/7#pullrequestreview-201
- comment https://github.com/o/r/pull/7#issuecomment-301' 'listing all three, oldest first' "$(prompt | tail -n 3)"

reset
timeline 7 "$(comment 7 101 mari User "$(iso $((T0 - 300)))")"
nt "$T" check
record 0 'an event before the subscription wakes nothing' "$(wakes)"

reset
pr 8 open
timeline 8 "$(comment 8 801 mari User "$T1")"
nt "$T0" subscribe o/r#8 --session "$SID" >/dev/null
timeline 7 "$(comment 7 101 mari User "$T1")"
nt "$T" check
record 1 'events on two PRs for one session make one wake' "$(wakes)"
record 'PR https://github.com/o/r/pull/7 open|PR https://github.com/o/r/pull/8 open' 'with a block per PR' \
	"$(prompt | grep '^PR ' | paste -sd'|' -)"

reset
jq -n '{event: "commented", id: 109, user: {login: "mari", type: "User"}, created_at: "'"$T1"'",
	updated_at: "'"$T1"'", html_url: "https://evil.example/o/r/pull/7#x"}' >"$tmp/odd.json"
timeline 7 "$(cat "$tmp/odd.json")" "$(comment 7 110 mari User "$T1" "$T1" | jq '.html_url = "https://github.com/o/r/pull/70#issuecomment-110"')"
nt "$T" check
record '- comment https://github.com/o/r/pull/7
- comment https://github.com/o/r/pull/7' "a URL off the PR's own page becomes the PR's URL" "$(prompt | tail -n 2)"

# owner-check's exit 1 can mean a failed read, so it is retried for a while.
reset
touch "$STUB/perm-mari.fail"
timeline 7 "$(comment 7 101 mari User "$T1")"
nt "$T" check
record 0 'a failed owner check wakes nothing yet' "$(wakes)"
rm "$STUB/perm-mari.fail"
nt $((T + 400)) check
record 1 'and the next sweep, inside the retry window, wakes for it' "$(wakes)"
record yes 'logged as an owner on the recheck' "$(logged 'key=comment:101 actor=mari verdict=keep reason="owner"')"

reset
timeline 7 "$(comment 7 102 eve User "$T1")"
nt "$T" check
nt $((T + 2000)) check
record yes "a stranger's comment settles once the retry window ends" "$(logged 'key=comment:102 actor=eve verdict=drop reason="not the owner (owner-check 1); settled"')"
nt $((T + 2400)) check
record 2 'and is never checked again (its two lines: the first drop and the settle)' \
	"$(grep -c 'key=comment:102' "$PR_NOTIFIER_HOME/notifier.log")"

reset
touch "$STUB/user.fail"
timeline 7 "$(comment 7 101 mari User "$T1")"
nt "$T" check
record 0 "without the sessions' own login, nothing is filtered" "$(wakes)"
record true 'and the PR stays dirty for the next check' "$(jq -r '.prs["o/r#7"].dirty' "$PR_NOTIFIER_HOME/state.json")"
rm "$STUB/user.fail"
nt $((T + 60)) check
record 1 'which then wakes' "$(wakes)"

# --- the PR's own state, and Codex's edited summary -------------------------------

reset
pr 7 merged "$(iso $((T0 + 90)))"
nt "$T" check
record 'PR https://github.com/o/r/pull/7 merged|- merged https://github.com/o/r/pull/7' 'a merge wakes, whoever merged' \
	"$(prompt | tail -n 2 | paste -sd'|' -)"
record '' 'and the final wake ends the subscription' "$(subs)"

reset
pr 7 closed "$(iso $((T0 - 600)))"
nt "$T" check
record '0|' 'a subscription made after the PR closed is dropped without a wake' "$(wakes)|$(subs)"

reset
agents "$(agent busy)"
pr 7 closed "$(iso $((T0 + 90)))"
nt "$T" check
record '0|1' 'a close while the session is busy is held' "$(wakes)|$(held)"
pr 7 open
agents "$(agent stopped)"
nt $((T + 400)) check
record 'PR https://github.com/o/r/pull/7 open|- closed https://github.com/o/r/pull/7' \
	'reopened before delivery: the wake shows the PR as last read' "$(prompt | tail -n 2 | paste -sd'|' -)"
record 'o/r#7@aaaaaaaa' 'and the subscription survives the held close' "$(subs)"

# Edits of comments posted before the subscription.
reset
pre=$(iso $((T0 - 300)))
timeline 7 "$(comment 7 101 mari User "$pre")" "$(comment 7 102 eve User "$pre")"
nt "$T" check
record 0 'unedited comments from before the subscription wake nothing' "$(wakes)"
timeline 7 "$(comment 7 101 mari User "$pre" "$(iso $((T + 100)))")" "$(comment 7 102 eve User "$pre" "$(iso $((T + 100)))")"
nt $((T + 400)) check
record 1 "the owner's later edit of one wakes" "$(wakes)"
record '- edited https://github.com/o/r/pull/7#issuecomment-101' 'as an edit, and the stranger'"'"'s edit adds nothing' "$(prompt | tail -n 1)"
nt $((T + 800)) check
record 1 'the same edit wakes once' "$(wakes)"
timeline 7 "$(comment 7 101 mari User "$pre" "$(iso $((T + 900)))")" "$(comment 7 102 eve User "$pre" "$(iso $((T + 100)))")"
nt $((T + 1200)) check
record 2 'a second edit wakes again' "$(wakes)"
nt $((T + 2500)) check
record yes "the stranger's edit settles after the retry window" "$(logged 'key=comment:102 actor=eve verdict=drop reason="edit, not the owner (owner-check 1); settled"')"

# An owner check that fails for a whole retry window settles that edit only.
reset
touch "$STUB/perm-mari.fail"
timeline 7 "$(comment 7 101 mari User "$pre")"
nt "$T" check
timeline 7 "$(comment 7 101 mari User "$pre" "$(iso $((T + 100)))")"
nt $((T + 400)) check
nt $((T + 2400)) check
record 0 'an edit whose owner check fails for the whole window wakes nothing' "$(wakes)"
rm "$STUB/perm-mari.fail"
timeline 7 "$(comment 7 101 mari User "$pre" "$(iso $((T + 2500)))")"
nt $((T + 2800)) check
record 1 'but the next edit of that comment is checked afresh, and wakes' "$(wakes)"

reset
timeline 7 "$(comment 7 101 mari User "$(iso $((T0 - 300)))" "$(iso $((T0 + 60)))")"
nt "$T" check
record '- edited https://github.com/o/r/pull/7#issuecomment-101' 'an edit already made when the notifier first reads the comment wakes too' "$(prompt | tail -n 1)"

codex() { # codex <created> <updated> <status> [commit]
	comment 7 301 'chatgpt-codex-connector[bot]' Bot "$1" "$2" "<!-- codex-pull-request-review-summary -->
<!-- codex-review-state:v1 {\"code_review\":{\"commit_sha\":\"${4:-abc}\",\"status\":\"$3\"}} -->
## Codex Review Summary"
}
reset
timeline 7 "$(codex "$(iso $((T0 - 900)))" "$(iso $((T0 - 900)))" running)"
nt "$T" check
record 0 "Codex's summary from before the subscription wakes nothing" "$(wakes)"
timeline 7 "$(codex "$(iso $((T0 - 900)))" "$(iso $((T + 100)))" completed)"
nt $((T + 400)) check
record 1 'its edit to a completed review wakes' "$(wakes)"
record '- review https://github.com/o/r/pull/7#issuecomment-301' 'as a review, at the summary' "$(prompt | tail -n 1)"
timeline 7 "$(codex "$(iso $((T0 - 900)))" "$(iso $((T + 800)))" running def)"
nt $((T + 1200)) check
record 1 'a later edit to a running review wakes nothing' "$(wakes)"
timeline 7 "$(codex "$(iso $((T0 - 900)))" "$(iso $((T + 1300)))" completed def)"
nt $((T + 1600)) check
record 2 'and its completion for a new commit wakes again' "$(wakes)"

# --- delivery states ----------------------------------------------------------

deliver_case() { # deliver_case <agent kind> [job updatedAt] [inFlight or none]
	reset
	agents "$(agent "$1")"
	[ -z "${2:-}" ] || job "$SID" "$2" "${3:-}"
	timeline 7 "$(comment 7 101 mari User "$T1")"
	nt "$T" check
}
stopped_after_start() { # the claude.log verbs, in order, from the resume's point of view
	awk -F'|' '{ split($1, a, " "); printf "%s%s", (NR > 1 ? "," : ""), (a[1] == "--bg" ? "resume" : a[1]) }' "$STUB/claude.log"
}

deliver_case busy
record '0|1' 'busy: held, no wake' "$(wakes)|$(held)"
record yes 'and logged' "$(logged 'hold session=aaaaaaaa reason=busy status=busy state=working')"
agents "$(agent stopped)"
nt $((T + 60)) check
record 1 'once it stops, the held event is delivered' "$(wakes)"

deliver_case working
record '0|1' 'live and mid-turn (state working): held' "$(wakes)|$(held)"

deliver_case idle-done $((T - 3600))
record 1 'live and idle (done), quiet for an hour: woken' "$(wakes)"
record 'agents,agents,stop,agents,resume' 'by stop, a check that it stopped, then resume' "$(stopped_after_start)"
record yes 'and the stop names the short id' "$(has "$STUB/claude.log" 'stop aaaaaaaa|')"

deliver_case idle-blocked $((T - 3600))
record 1 'live and blocked waiting on the user (the hand-back): woken' "$(wakes)"

deliver_case idle-blocked $((T - 60))
record '0|1' 'live and idle with activity a minute ago: held for attached viewers' "$(wakes)|$(held)"
record yes 'as recent activity' "$(logged 'reason=recent-activity')"

deliver_case idle-done $((T - 3600)) '{"tasks":1,"queued":0,"kinds":["local_bash"]}'
record '0|1' 'live and idle with background work in flight: held' "$(wakes)|$(held)"
record no 'and never stopped' "$(has "$STUB/claude.log" stop)"

deliver_case idle-done $((T - 3600)) '{"tasks":0,"queued":0,"kinds":["monitor"]}'
record 0 'a monitor counts as work in flight' "$(wakes)"

deliver_case idle-done $((T - 3600)) none
record '0|1' 'no job state to read: held as in flight' "$(wakes)|$(held)"
record yes 'and logged as unknown' "$(logged 'reason=in-flight=unknown')"

deliver_case interactive $((T - 3600))
record '0|1' 'a live interactive session is never stopped: held' "$(wakes)|$(held)"
record no 'no stop is sent to it' "$(has "$STUB/claude.log" stop)"
agents "$(agent interactive-exited)"
nt $((T + 60)) check
record 1 'once it has exited, it is resumed' "$(wakes)"

reset
agents "$(agent stopped "$SID" "$tmp/gone")"
timeline 7 "$(comment 7 101 mari User "$T1")"
nt "$T" check
record '0|' "the session's cwd is gone: no resume, and it is unsubscribed" "$(wakes)|$(subs)"
record yes 'logged' "$(logged 'drop session=aaaaaaaa reason=cwd-gone')"

reset
agents "$(agent stopped "$SID2")"
timeline 7 "$(comment 7 101 mari User "$T1")"
nt "$T" check
record '0|' 'no row for the session: unsubscribed' "$(wakes)|$(subs)"

reset
echo 1 >"$STUB/resume.rc"
timeline 7 "$(comment 7 101 mari User "$T1")"
nt "$T" check
record '1|1' 'a refused resume keeps the event' "$(wakes)|$(held)"
record yes 'and logs why' "$(logged 'wake-failed session=aaaaaaaa rc=1 detail="Workspace not trusted.')"
echo 0 >"$STUB/resume.rc"
nt $((T + 60)) check
record '2|0' 'and the next check delivers it' "$(wakes)|$(held)"

reset
echo '{"broken": ' >"$STUB/agents.json"
timeline 7 "$(comment 7 101 mari User "$T1")"
nt "$T" check
record '0|1' "an unreadable claude agents listing holds" "$(wakes)|$(held)"

# --- the wake environment ---------------------------------------------------------

reset
nt "$T0" unsubscribe o/r#7 --session "$SID" >/dev/null
CLAUDE_CODE_SESSION_ID=$SID CLAUDE_CONFIG_DIR=$tmp/home/.claude-alt nt "$T0" subscribe o/r#7 --name x >/dev/null
agents "$(agent stopped)" && mv "$STUB/agents.json" "$STUB/agents-.claude-alt.json"
echo '{"wake_path": "/wake/bin:'"$PATH"'"}' >"$PR_NOTIFIER_HOME/config.json"
timeline 7 "$(comment 7 101 mari User "$T1")"
CLAUDE_CONFIG_DIR=/elsewhere CLAUDE_CODE_SESSION_ID=$SID2 nt "$T" check
record 1 'a session in another root is found and woken there' "$(wakes)"
record "cfg=$tmp/home/.claude-alt" 'with its CLAUDE_CONFIG_DIR' "$(grep -- '--bg' "$STUB/claude.log" | cut -d'|' -f2)"
record "path=/wake/bin:$PATH" 'and the configured PATH' "$(grep -- '--bg' "$STUB/claude.log" | cut -d'|' -f3)"
reset
timeline 7 "$(comment 7 101 mari User "$T1")"
CLAUDE_CONFIG_DIR=/elsewhere nt "$T" check >/dev/null
record 'cfg=<unset>' "the default root's session is woken with CLAUDE_CONFIG_DIR unset, whatever the checker's" \
	"$(grep -- 'agents' "$STUB/claude.log" | head -1 | cut -d'|' -f2)"

# --- the feed -----------------------------------------------------------------

reset
echo 200 >"$STUB/feed.status"
echo 'Sat, 31 Oct 2026 21:40:00 GMT' >"$STUB/feed.lm"
nt "$T" check
record 1 'the first poll is unconditional' "$(grep -c '^api -i notifications' "$STUB/gh.log")"
record 'Sat, 31 Oct 2026 21:40:00 GMT' 'and its Last-Modified is kept' "$(jq -r '.feed.last_modified' "$PR_NOTIFIER_HOME/state.json")"
echo 304 >"$STUB/feed.status"
: >"$STUB/gh.log"
nt $((T + 61)) check
record yes 'the next poll is conditional' "$(has "$STUB/gh.log" 'If-Modified-Since: Sat, 31 Oct 2026 21:40:00 GMT')"
record yes 'with the same URL, so a 304 is possible' "$(has "$STUB/gh.log" "since=$(iso $((T - 300)))")"
record no 'a 304 with no sweep due reads no PR' "$(has "$STUB/gh.log" 'pulls/7')"
record yes 'and is logged' "$(logged 'poll status=304')"
: >"$STUB/gh.log"
nt $((T + 100)) check
record no 'X-Poll-Interval is honored: no poll before it passes' "$(has "$STUB/gh.log" notifications)"
echo 200 >"$STUB/feed.status"
jq -n '[{reason: "author", subject: {type: "PullRequest", url: "https://api.github.com/repos/O/R/pulls/7"}},
	{reason: "author", subject: {type: "PullRequest", url: "https://api.github.com/repos/o/r/pulls/99"}}]' >"$STUB/feed.json"
timeline 7 "$(comment 7 101 mari User "$(iso $((T + 90)))")"
nt $((T + 130)) check
record 1 'a thread on a subscribed PR has it read at once, without waiting for the sweep' "$(wakes)"
record yes 'and the log counts the match' "$(logged 'poll status=200 threads=2 matched=1')"
record "$(iso $((T - 300)))" 'a 200 within the hour leaves since alone, so the URL repeats' \
	"$(jq -r '.feed.since' "$PR_NOTIFIER_HOME/state.json")"

# A notification that never comes: the sweep still finds the owner's event.
reset
nt "$T" check
timeline 7 "$(comment 7 101 mari User "$(iso $((T + 30)))")"
nt $((T + 120)) check
record 0 'with no notification, nothing before the sweep is due' "$(wakes)"
nt $((T + 300)) check
record 1 'and the sweep wakes for it' "$(wakes)"

# Downtime: the next check catches up from the cursor it kept.
reset
echo 200 >"$STUB/feed.status"
nt "$T" check
: >"$STUB/gh.log"
jq -n '[{reason: "author", subject: {type: "PullRequest", url: "https://api.github.com/repos/o/r/pulls/7"}}]' >"$STUB/feed.json"
timeline 7 "$(comment 7 101 mari User "$(iso $((T + 3600)))")"
nt $((T + 10800)) check
record yes 'after three hours down, the poll asks from before the last one' "$(has "$STUB/gh.log" "since=$(iso $((T - 300)))")"
record 1 'and the event that arrived while down wakes' "$(wakes)"

reset
touch "$STUB/feed.fail"
timeline 7 "$(comment 7 101 mari User "$T1")"
nt "$T" check
record 1 'a failed poll still lets the sweep run' "$(wakes)"
record yes 'and is logged' "$(logged 'poll error status=none')"

# --- bounded holds, status, the lock --------------------------------------------------

reset
agents "$(agent busy)"
timeline 7 "$(comment 7 101 mari User "$T1")"
nt "$T" check
nt $((T + 1000)) check 2>"$tmp/err"
record '' 'no warning before the bound' "$(cat "$tmp/err")"
nt $((T + 1801)) check 2>"$tmp/err"
record yes 'a hold past the bound is surfaced on stderr' "$(has "$tmp/err" 'events for session aaaaaaaa held 30m')"
record yes 'and in the log' "$(logged 'stale session=aaaaaaaa held=30m')"
nt $((T + 1900)) check 2>"$tmp/err"
record '' 'once' "$(cat "$tmp/err")"
record 1 'the event is still held, not dropped' "$(held)"
nt $((T + 1900)) status >"$tmp/status"
record yes 'status lists the subscription' "$(has "$tmp/status" 'subscription o/r#7 session=aaaaaaaa name="r #7: x" root=default')"
record yes 'and the stale hold' "$(has "$tmp/status" 'held session=aaaaaaaa events=1 for=31m last=busy status=busy state=working STALE')"
record 1 'status --json is JSON' "$(nt "$T" status --json | jq '.subscriptions | length')"

reset
mkdir "$PR_NOTIFIER_HOME/lock" && echo $$ >"$PR_NOTIFIER_HOME/lock/pid"
timeline 7 "$(comment 7 101 mari User "$T1")"
nt "$T" check
record '0|yes' 'check skips while another command holds the lock' "$(wakes)|$(logged 'check skipped=locked')"
sh -c 'exit 0' &
dead=$!
wait "$dead"
echo "$dead" >"$PR_NOTIFIER_HOME/lock/pid"
nt "$T" check
record 1 "a dead holder's lock is taken over" "$(wakes)"
record no 'and released afterwards' "$([ -d "$PR_NOTIFIER_HOME/lock" ] && echo yes || echo no)"
record no 'with no takeover left behind' "$([ -d "$PR_NOTIFIER_HOME/lock.takeover" ] && echo yes || echo no)"

reset
mkdir "$PR_NOTIFIER_HOME/lock" "$PR_NOTIFIER_HOME/lock.takeover" && echo $$ >"$PR_NOTIFIER_HOME/lock/pid"
nt "$T0" subscribe o/r#8 --session "$SID" >/dev/null 2>&1 &
waiter=$!
sleep 2
record 'o/r#7@aaaaaaaa' 'subscribe waits while a live command holds the lock' "$(subs)"
rm -rf "$PR_NOTIFIER_HOME/lock" "$PR_NOTIFIER_HOME/lock.takeover"
wait "$waiter"
record 'o/r#7@aaaaaaaa,o/r#8@aaaaaaaa' 'and subscribes once it is released' "$(subs)"

reset
nt "$T0" unsubscribe o/r#7 --session "$SID" >/dev/null
: >"$STUB/gh.log"
nt "$T" check
record '' 'with no subscriptions, check calls nothing' "$(cat "$STUB/gh.log")"

# --- the stable-path shim, and the vendored owner-check ---------------------------------

shim=$plugin/scripts/pr-notifier-shim.sh
fake=$tmp/shimhome
for v in .claude/0.1.0 .claude/0.10.0 .claude/0.9.0 .claude-work/0.2.0; do
	d=$fake/${v%%/*}/plugins/cache/maguerrieri-toolbox/pr-notifier/${v#*/}/bin
	mkdir -p "$d"
	printf 'echo %s "$@"\n' "${v#*/}" >"$d/pr-notifier"
done
record '0.10.0 status' 'the shim runs the newest version across roots' "$(HOME=$fake sh "$shim" status)"
mkdir -p "$fake/.claude-work/plugins/cache/maguerrieri-toolbox/pr-notifier/0.11.0/bin"
echo 'echo 0.11.0' >"$fake/.claude-work/plugins/cache/maguerrieri-toolbox/pr-notifier/0.11.0/bin/pr-notifier"
record '0.11.0' 'including one in another root' "$(HOME=$fake sh "$shim")"
record 'pinned x' 'PR_NOTIFIER_ROOT pins a plugin directory' \
	"$(mkdir -p "$tmp/pin/bin" && echo 'echo pinned "$@"' >"$tmp/pin/bin/pr-notifier" && HOME=$fake PR_NOTIFIER_ROOT=$tmp/pin sh "$shim" x)"
HOME=$tmp/empty sh "$shim" status 2>/dev/null
record 127 'with nothing installed it fails plainly' $?

upstream=$plugin/../ticket-workflow/scripts/owner-check.sh
if [ -f "$upstream" ]; then
	record same 'the vendored owner-check.sh matches ticket-workflow'"'"'s' \
		"$(cmp -s "$upstream" "$plugin/scripts/owner-check.sh" && echo same || echo differs)"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
