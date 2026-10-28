#!/usr/bin/env bash
# Tests for scripts/ledger.sh, which makes every ledger read and write the
# docs describe: add-decision and add-need (text on stdin), resolve, and list,
# the session-id lookup, the argument checks, and atomic writes. The script
# runs under the bash running this file, so `/bin/bash tests/test-ledger.sh`
# checks it under macOS's bash 3.2. Needs jq.
#
#   bash plugins/ledger/tests/test-ledger.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
script="$plugin/scripts/ledger.sh"
# The physical path: the script records $PWD, which a fresh bash takes from
# getcwd (macOS's temp directory is behind the /var symlink).
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
dir="$tmp/ledger"
sid=11111111-aaaa-bbbb-cccc-000000000001
other=22222222-aaaa-bbbb-cccc-000000000002
work="$tmp/work/repo-a"
mkdir -p "$work" "$tmp/bin"
. "$here/lib.sh"

# A stand-in for `claude agents --json --all`, which list --all reads names from.
cat >"$tmp/bin/claude" <<EOF
#!/bin/sh
[ "\$1 \$2 \$3" = "agents --json --all" ] || exit 2
printf '%s\n' '[{"id":"22222222","sessionId":"$other","name":"toolbox #212: merge it","state":"done"}]'
EOF
chmod +x "$tmp/bin/claude"

# Runs the script as session <id> with <stdin> and the arguments, under a clean
# environment from $work; prints the exit status. stdout and stderr are kept
# in $tmp/out and $tmp/err.
run_as() { # run_as <id> <stdin> <arg> ...
	local id=$1 input=$2
	shift 2
	(cd "$work" && printf '%s' "$input" | env -i PATH="$tmp/bin:$PATH" HOME="$tmp/home" TZ=UTC \
		CLAUDE_SESSION_LEDGER_DIR="$dir" CLAUDE_CODE_SESSION_ID="$id" "$BASH" "$script" "$@" >"$tmp/out" 2>"$tmp/err")
	echo "exit $?"
}
run() { run_as "$sid" "$@"; }

# The ledger of <id> (this session by default) as compact JSON lines joined
# by |, with each entry's at and resolved_at shown as T when they're
# ISO-8601 UTC timestamps; or none.
ledger() { # ledger [id]
	local file="$dir/${1:-$sid}.jsonl"
	[ -f "$file" ] || {
		printf none
		return
	}
	jq -c 'def t: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then "T" else . end;
		.at |= t | if has("resolved_at") then .resolved_at |= t else . end' "$file" | tr '\n' '|'
}

reset() { rm -rf "$dir"; }

# --- add-decision / add-need ------------------------------------------------

reset
record "exit 0" "add-decision: records" "$(run 'Ship it as its own plugin' add-decision)"
record "d1" "add-decision: prints the id" "$(cat "$tmp/out")"
record "{\"kind\":\"decision\",\"id\":\"d1\",\"text\":\"Ship it as its own plugin\",\"at\":\"T\",\"cwd\":\"$work\"}|" \
	"add-decision: the entry" "$(ledger)"
run $'Defer the cloud half\n' add-decision --ref '#208' >/dev/null
record "d2" "add-decision: numbered per kind" "$(cat "$tmp/out")"
record '"#208" "Defer the cloud half"' "add-decision: ref recorded, one trailing newline dropped" \
	"$(jq -r 'select(.id == "d2") | "\(.ref | tojson) \(.text | tojson)"' "$dir/$sid.jsonl")"
run 'Merge #212 when green' add-need --ref 'PR#212' >/dev/null
record "n1" "add-need: needs numbered on their own" "$(cat "$tmp/out")"
record "need PR#212" "add-need: kind and ref" \
	"$(jq -r 'select(.id == "n1") | "\(.kind) \(.ref)"' "$dir/$sid.jsonl")"
record "3" "add: entries kept in order" "$(jq -s length "$dir/$sid.jsonl")"

text=$'Say "finish" in `claude attach ab12` — $HOME stays\n\tsecond line'
reset
run "$text" add-need >/dev/null
record "$text" "add: quotes, backticks, \$ and lines kept literally" \
	"$(jq -j '.text' "$dir/$sid.jsonl")"
for ref in 'owner/repo#12' 'ABC-12' 'epic:40' '#7' 'x.y_z'; do
	reset
	record "exit 0 $ref" "add: ref $ref accepted" "$(run t add-need --ref "$ref") $(jq -r .ref "$dir/$sid.jsonl")"
done

for bad in '' 'a b' '$(id)' '-x' 'a;b' "$(printf 'x%.0s' $(seq 101))"; do
	reset
	record "exit 1 none" "add: ref '${bad:0:12}' refused" "$(run t add-need --ref "$bad") $(ledger)"
done
reset
record "exit 1 none" "add: --ref with no value" "$(run t add-need --ref) $(ledger)"
record "exit 1 none" "add: an extra argument" "$(run t add-decision extra) $(ledger)"
record "exit 1 none" "add: empty text" "$(run '' add-decision) $(ledger)"
record "exit 1 none" "add: whitespace-only text" "$(run $' \n\t\n' add-decision) $(ledger)"
record "exit 1 none" "add: a control character" "$(run $'red \033[31m' add-decision) $(ledger)"
record "exit 1 none" "add: a carriage return" "$(run $'a\rb' add-decision) $(ledger)"
record "exit 1 none" "add: a C1 control as UTF-8 (CSI)" "$(run $'a\xc2\x9b2J' add-decision) $(ledger)"
record "exit 0" "add: other UTF-8 is kept" "$(run $'caf\xc3\xa9 \xe2\x80\x94 ok' add-decision)"
reset
record "exit 0" "add: 4000 bytes accepted" "$(run "$(printf 'x%.0s' $(seq 4000))" add-decision)"
reset
record "exit 1 none" "add: over 4000 bytes refused" "$(run "$(printf 'x%.0s' $(seq 4001))" add-decision) $(ledger)"
record 1 "add: says why" "$(grep -c 'over 4000 bytes' "$tmp/err")"

# --- session id --------------------------------------------------------------

reset
record "exit 1" "no session id" \
	"$(cd "$work" && printf t | env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" \
		"$BASH" "$script" add-decision >/dev/null 2>"$tmp/err"; echo "exit $?")"
record 1 "no session id: says why" "$(grep -c 'no session id' "$tmp/err")"
record "exit 0 d1" "CLAUDE_SESSION_ID is the fallback" \
	"$(cd "$work" && printf t | env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" \
		CLAUDE_SESSION_ID="$sid" "$BASH" "$script" add-decision >/dev/null 2>&1; echo "exit $?") $(jq -r .id "$dir/$sid.jsonl")"
reset
for bad in '../x' '.' 'a/b' 'a..b' 'a b'; do
	record "exit 1" "session id '$bad' refused" "$(run_as "$bad" t add-decision)"
done
record "none" "a refused session id writes nothing" "$(ls -A "$dir" 2>/dev/null || printf none)"
record "exit 0 $tmp/home/.claude/session-ledger/$sid.jsonl" "default directory under HOME" \
	"$(cd "$work" && printf t | env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_CODE_SESSION_ID="$sid" \
		"$BASH" "$script" add-decision >/dev/null 2>&1; echo "exit $?") $(ls "$tmp/home/.claude/session-ledger/"*)"

# --- resolve -----------------------------------------------------------------

reset
run 'a decision' add-decision >/dev/null
run 'first need' add-need >/dev/null
run 'second need' add-need >/dev/null
record "exit 0" "resolve: an open need" "$(run '' resolve n1)"
record "d1: n1:T n2:" "resolve: only that need is stamped" \
	"$(ledger | tr '|' '\n' | jq -rs 'map("\(.id):\(.resolved_at // "")") | join(" ")')"
before=$(jq -r 'select(.id == "n1") | .resolved_at' "$dir/$sid.jsonl")
record "exit 0 $before" "resolve: again keeps the first stamp" \
	"$(run '' resolve n1) $(jq -r 'select(.id == "n1") | .resolved_at' "$dir/$sid.jsonl")"
record 1 "resolve: again says so" "$(grep -c 'already resolved' "$tmp/err")"
record "exit 1" "resolve: an unknown need" "$(run '' resolve n9)"
record "exit 1" "resolve: a decision" "$(run '' resolve d1)"
record "exit 1" "resolve: no id" "$(run '' resolve)"
record "exit 1" "resolve: a bad id" "$(run '' resolve 'n1;x')"

run_as "$other" 'their need' add-need >/dev/null
record "exit 0 T" "resolve --session: another session's need" \
	"$(run '' resolve n1 --session "$other") $(ledger "$other" | tr '|' '\n' | jq -r .resolved_at)"
run_as "$other" 'their second need' add-need >/dev/null
record "exit 0 T" "resolve --session: a unique prefix" \
	"$(run '' resolve n2 --session 2222) $(jq -r 'select(.id == "n2") | .resolved_at' "$dir/$other.jsonl" | sed 's/^[0-9].*Z$/T/')"
record "exit 1" "resolve --session: a prefix under four characters" "$(run '' resolve n2 --session 222)"
run_as 22229999 'x' add-need >/dev/null
record "exit 1" "resolve --session: an ambiguous prefix" "$(run '' resolve n1 --session 2222)"
record 1 "resolve --session: says it's ambiguous" "$(grep -c 'more than one' "$tmp/err")"
record "exit 1" "resolve --session: no such session" "$(run '' resolve n1 --session 3333)"
record "exit 1" "resolve --session: a path" "$(run '' resolve n1 --session ../x)"
record "exit 1" "resolve --session: no value" "$(run '' resolve n1 --session)"

# --- list --------------------------------------------------------------------

reset
record "exit 0" "list: no ledger" "$(run '' list)"
record 1 "list: no ledger says so" "$(grep -c 'no entries' "$tmp/out")"

run 'Keep it local' add-decision --ref '#208' >/dev/null
run $'Review PR #212\nthen say finish' add-need --ref '#212' >/dev/null
run 'Unlock 1Password' add-need >/dev/null
run '' resolve n2 >/dev/null
run '' list >/dev/null
expected="Open needs (1):
  n1 · DATE · #212
    Review PR #212
    then say finish
Decisions (1):
  d1 · DATE · #208
    Keep it local
Resolved needs (1):
  n2 · DATE
    Unlock 1Password"
record "$expected" "list: this session" \
	"$(sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}/DATE/' "$tmp/out")"

# Other sessions' ledgers, written as fixtures so their times are fixed: the
# listing puts the newest need first.
cat >"$dir/$other.jsonl" <<EOF
{"kind":"need","id":"n1","text":"Approve the permission prompt","at":"2020-01-01T10:00:00Z","cwd":"$tmp/work/repo-a"}
{"kind":"decision","id":"d1","text":"their decision","at":"2020-01-01T10:01:00Z","cwd":"$tmp/work/repo-a"}
{"kind":"need","id":"n2","text":"done already","at":"2020-01-01T10:02:00Z","cwd":"$tmp/work/repo-a","resolved_at":"2020-01-01T10:03:00Z"}
EOF
# repo-b's n2 shares this session's n1's ref, as a child's need and its
# spawner's copy do: one need, shown once, under the first recorded.
cat >"$dir/33333333-x.jsonl" <<EOF
{"kind":"need","id":"n1","text":"Pick a design","at":"2020-01-01T09:00:00Z","cwd":"$tmp/work/repo-b"}
not json
{"kind":"need","text":"no id","at":"2020-01-01T09:30:00Z"}
{"kind":"need","id":"n8","text":"a number for a ref","ref":5,"at":"2020-01-01T09:30:00Z"}
["an", "array"]
{"kind":"need","id":"n2","text":"Review PR #212","ref":"#212","at":"2020-01-01T08:00:00Z","cwd":"$tmp/work/repo-b"}
EOF
printf 'ignored\n' >"$dir/notes.txt"
record "exit 0" "list --all" "$(run '' list --all)"
labels=$(grep -E '^  [^ ]' "$tmp/out" | sed -E 's/^  //; s/ · [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}//')
record "repo-b (33333333) · n2 · #212
toolbox #212: merge it (22222222) · n1
repo-b (33333333) · n1
d1 · #208" "list --all: open needs across sessions, newest first, then this session's decisions" "$labels"
record 1 "list --all: a shared ref names the other copies" "$(grep -c '^    also: this session n1$' "$tmp/out")"
record 1 "list --all: header counts a shared ref once" "$(grep -c '^Open needs across sessions (3):$' "$tmp/out")"
record 1 "list --all: decisions header" "$(grep -c '^Decisions in this session (1):$' "$tmp/out")"
record 1 "list --all: a need's text" "$(grep -c '^    Pick a design$' "$tmp/out")"
record 0 "list --all: resolved needs left out" "$(grep -c 'Unlock 1Password\|done already' "$tmp/out")"
record 0 "list --all: other sessions' decisions left out" "$(grep -c 'their decision' "$tmp/out")"

# A claude whose listing fails leaves every session named by its directory.
mkdir -p "$tmp/bin-broken"
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin-broken/claude"
chmod +x "$tmp/bin-broken/claude"
record "exit 0" "list --all: claude agents failing" \
	"$(cd "$work" && env -i PATH="$tmp/bin-broken:$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" \
		CLAUDE_CODE_SESSION_ID="$sid" "$BASH" "$script" list --all >"$tmp/out" 2>"$tmp/err"; echo "exit $?")"
record 1 "list --all: falls back to the directory name" "$(grep -c '^  repo-a (22222222) · n1' "$tmp/out")"

# A claude that hangs is given five seconds, and then nobody is named.
mkdir -p "$tmp/bin-hung"
printf '#!/bin/sh\nexec sleep 30\n' >"$tmp/bin-hung/claude"
chmod +x "$tmp/bin-hung/claude"
started=$(date +%s)
record "exit 0" "list --all: claude agents hanging" \
	"$(cd "$work" && env -i PATH="$tmp/bin-hung:$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" \
		CLAUDE_CODE_SESSION_ID="$sid" "$BASH" "$script" list --all >"$tmp/out" 2>"$tmp/err"; echo "exit $?")"
record yes "list --all: done within ten seconds" "$([ $(($(date +%s) - started)) -lt 10 ] && echo yes)"
record 1 "list --all: a hung claude names nobody" "$(grep -c '^  repo-a (22222222) · n1' "$tmp/out")"
record "exit 0" "list --all: no session id still lists" \
	"$(cd "$work" && env -i PATH="$tmp/bin:$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" \
		"$BASH" "$script" list --all >"$tmp/out" 2>"$tmp/err"; echo "exit $?")"
record 0 "list --all: no session id marks no session as this one" "$(grep -c 'this session' "$tmp/out")"
record "exit 1" "list: an unknown option" "$(run '' list --json)"

# --- writes are atomic and serialized ---------------------------------------

record "" "no temp files left behind (only ledgers and their lock files)" "$(ls -A "$dir" | grep -v -e '\.jsonl$' -e '^notes\.txt$' -e '^\..*\.jsonl\.lock$')"

# Twenty adds at once, twice over, with resolves among them: every entry
# lands, numbered without a repeat. (A lock that could be deleted and remade
# lost entries here: a waiter that saw a holder exit removed its successor's.)
reset
run 'first' add-need >/dev/null
run 'second' add-need >/dev/null
for batch in 1 2; do
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		(cd "$work" && printf 'need %s.%s' "$batch" "$i" | env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" \
			CLAUDE_CODE_SESSION_ID="$sid" "$BASH" "$script" add-need >/dev/null 2>&1) &
	done
	run '' resolve "n$batch" --session "$sid" >/dev/null &
	wait
done
record "42 42 2" "concurrent writes: none lost, ids unique, the resolves kept" \
	"$(jq -s '"\(length) \([.[].id] | unique | length) \([.[] | select(.resolved_at)] | length)"' -r "$dir/$sid.jsonl")"

# hold_lock <seconds>: hold this session's ledger lock from a background
# process for <seconds>, as a write in progress does; sets holder to its pid.
hold_lock() {
	mkdir -p "$dir"
	(
		exec 9>>"$dir/.$sid.jsonl.lock"
		perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or die; flock($f, LOCK_EX) or die'
		exec sleep "$1"
	) &
	holder=$!
	# Until the lock is taken: a non-blocking try fails while it's held.
	until ! perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)' "$dir/.$sid.jsonl.lock"; do
		sleep 0.05
	done
}
# A held lock is waited for, and the write lands once it's released.
hold_lock 1
started=$(date +%s)
record "exit 0" "a held lock is waited out" "$(run 'after the wait' add-decision)"
record yes "a held lock is waited for" "$([ $(($(date +%s) - started)) -ge 1 ] && echo yes)"
wait "$holder"
# A killed holder's lock is free at once: the kernel dropped it.
hold_lock 30
kill -9 "$holder"
wait "$holder" 2>/dev/null
started=$(date +%s)
record "exit 0" "a killed holder's lock is free" "$(run 'after a crash' add-decision)"
record yes "a killed holder's lock is free at once" "$([ $(($(date +%s) - started)) -lt 3 ] && echo yes)"
# A holder that outlasts ten seconds is reported, and nothing is written.
hold_lock 15
before=$(wc -l <"$dir/$sid.jsonl")
record "exit 1" "a lock held past ten seconds" "$(run 'too late' add-decision)"
record 1 "a lock held past ten seconds: says so" "$(grep -c 'held the ledger for 10 seconds' "$tmp/err")"
record "$before" "a lock held past ten seconds: nothing written" "$(wc -l <"$dir/$sid.jsonl")"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# --- refs name their repo ----------------------------------------------------

# A checkout with an origin remote writes a bare #<n> as owner/repo#<n>.
repo_dir="$tmp/work/widgets"
mkdir -p "$repo_dir"
git -C "$repo_dir" init -q
git -C "$repo_dir" remote add origin git@github.com:acme/widgets.git
in_repo() { # in_repo <stdin> <arg>…: run as this session from $repo_dir
	(cd "$repo_dir" && printf '%s' "$1" | env -i PATH="$PATH" HOME="$tmp/home" \
		CLAUDE_SESSION_LEDGER_DIR="$dir" CLAUDE_CODE_SESSION_ID="$sid" "$BASH" "$script" "${@:2}" >"$tmp/out" 2>"$tmp/err")
	echo "exit $?"
}
reset
in_repo 'merge it' add-need --ref '#12' >/dev/null
in_repo 'a jira ref' add-need --ref 'ABC-12' >/dev/null
in_repo 'a full ref' add-need --ref 'other/repo#12' >/dev/null
in_repo 'a prefixed ref' add-need --ref 'PR#12' >/dev/null
record "acme/widgets#12 ABC-12 other/repo#12 PR#12" "add: a bare #<n> names the origin's repo, others are kept" \
	"$(jq -r .ref "$dir/$sid.jsonl" | tr '\n' ' ' | sed 's/ $//')"
git -C "$repo_dir" remote set-url origin https://github.com/acme/widgets
in_repo 'over https' add-decision --ref '#13' >/dev/null
record "acme/widgets#13" "add: an https remote" "$(jq -r 'select(.id == "d1") | .ref' "$dir/$sid.jsonl")"
record "exit 0" "add: outside a checkout a bare ref stays" "$(run 'no repo' add-need --ref '#12')"
record "#12" "add: outside a checkout, the ref as given" "$(jq -r 'select(.id == "n5") | .ref' "$dir/$sid.jsonl")"

# --- resolve --ref -----------------------------------------------------------

# The child's need and its spawner's copy, under the same ref, are both
# resolved; another repo's #12, and a need already resolved, are left alone.
cat >"$dir/$other.jsonl" <<EOF
{"kind":"need","id":"n1","text":"copy of acme #12","ref":"acme/widgets#12","at":"2020-01-01T10:00:00Z","cwd":"$repo_dir"}
{"kind":"need","id":"n2","text":"done","ref":"acme/widgets#12","at":"2020-01-01T10:00:00Z","resolved_at":"2020-01-01T11:00:00Z"}
EOF
record "exit 0" "resolve --ref: every open copy" "$(in_repo '' resolve --ref '#12')"
record "2" "resolve --ref: one line per ledger it touched" "$(wc -l <"$tmp/out" | tr -d ' ')"
record "n1 n2:2020-01-01T11:00:00Z" "resolve --ref: the other session's copy, and the old stamp kept" \
	"$(jq -r 'select(.resolved_at) | "\(.id)\(if .id == "n2" then ":" + .resolved_at else "" end)"' "$dir/$other.jsonl" | tr '\n' ' ' | sed 's/ $//')"
record "n1" "resolve --ref: this session's copy, and nothing else" \
	"$(jq -r 'select(.resolved_at) | .id' "$dir/$sid.jsonl")"
record "exit 0" "resolve --ref: nothing open under the ref" "$(in_repo '' resolve --ref '#99')"
record 1 "resolve --ref: says so" "$(grep -c 'no open need has the ref acme/widgets#99' "$tmp/err")"
record "exit 1" "resolve --ref: a bad ref" "$(run '' resolve --ref 'a b')"
record "exit 1" "resolve --ref: with a need id" "$(run '' resolve --ref '#12' n1)"
record "exit 0" "resolve --ref: no session id needed" \
	"$(cd "$work" && env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" \
		"$BASH" "$script" resolve --ref 'ABC-12' >/dev/null 2>&1; echo "exit $?")"

finish
