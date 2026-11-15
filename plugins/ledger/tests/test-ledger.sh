#!/usr/bin/env bash
# Tests for scripts/ledger.sh, which makes every ledger read and write the
# docs describe: add-decision and add-need (a Why line and text on stdin),
# resolve, and list, the session-id lookup, the argument checks, and atomic
# writes. The script runs under the bash running this file, so
# `/bin/bash tests/test-ledger.sh` checks it under macOS's bash 3.2. Needs jq.
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
mkdir -p "$work"
. "$here/lib.sh"

# The Why line every add needs (with_why adds it); tests of the Why line itself
# set NOWHY=1 and write their own.
WHY='Why: a test goal'
with_why() { # with_why <stdin> <subcommand>: <stdin>, with $WHY first for an add
	case "$2:${NOWHY:-}:$1" in
	add-*::Why:*) printf '%s' "$1" ;;
	add-*::*) printf '%s\n%s' "$WHY" "$1" ;;
	*) printf '%s' "$1" ;;
	esac
}

# Runs the script as session <id> with <stdin> and the arguments, under a clean
# environment from $work; prints the exit status. stdout and stderr are kept
# in $tmp/out and $tmp/err. An add's stdin gets $WHY first (with_why).
run_as() { # run_as <id> <stdin> <arg> ...
	local id=$1 input
	input=$(with_why "$2" "${3:-}"; printf x)
	input=${input%x}
	shift 2
	(cd "$work" && printf '%s' "$input" | env -i PATH="$PATH" HOME="$tmp/home" TZ=UTC \
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
record "{\"kind\":\"decision\",\"id\":\"d1\",\"why\":\"a test goal\",\"text\":\"Ship it as its own plugin\",\"at\":\"T\",\"cwd\":\"$work\"}|" \
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

for bad in '' 'a b' '$(id)' '-x' 'a;b' "$(printf 'x%.0s' $(seq 201))" \
	'#' '#0' '#07' 'a#' 'PR#x' 'a#1#2' \
	'https://github.com/acme/widgets/tree/main' 'https://github.com/acme/widgets/pull/' 'https://github.com/acme/widgets/pull/0'; do
	reset
	record "exit 1 none" "add: ref '${bad:0:40}' refused" "$(run t add-need --ref "$bad") $(ledger)"
done
# A GitHub issue or PR URL is stored as owner/repo#n, lowercased, whatever
# follows the number.
for url in 'https://github.com/Acme/Widgets/pull/12' 'https://github.com/acme/widgets/pull/12/files' \
	'https://github.com/acme/widgets/issues/12#issuecomment-1' 'https://ghe.example.com/acme/widgets/pull/12?w=1'; do
	reset
	record "exit 0 acme/widgets#12" "add: URL ref ${url#https://} stored as owner/repo#n" \
		"$(run t add-need --ref "$url") $(jq -r .ref "$dir/$sid.jsonl")"
done
# Invisible formatting characters are refused: a bidi override and isolate, a
# zero-width space and joiner, a line separator, a byte-order mark.
for ch in $'\xe2\x80\xae' $'\xe2\x81\xa6' $'\xe2\x80\x8b' $'\xe2\x80\x8d' $'\xe2\x80\xa8' $'\xef\xbb\xbf'; do
	reset
	record "exit 1 none" "add: an invisible formatting character ($(printf '%s' "$ch" | od -An -tx1 | tr -d ' '))" \
		"$(run "a${ch}b" add-need) $(ledger)"
done
record 1 "add: says what it refused" "$(grep -c 'invisible formatting character' "$tmp/err")"
reset
record "exit 0" "add: a plain em dash and an accent still pass" "$(run $'caf\xc3\xa9 \xe2\x80\x94 ok' add-need)"
reset
record "exit 1 none" "add: --ref with no value" "$(run t add-need --ref) $(ledger)"
record "exit 1 none" "add: an extra argument" "$(run t add-decision extra) $(ledger)"
record "exit 1 none" "add: empty text" "$(run '' add-decision) $(ledger)"
record "exit 1 none" "add: whitespace-only text" "$(run $' \n\t\n' add-decision) $(ledger)"
record "exit 1 none" "add: a control character" "$(run $'red \033[31m' add-decision) $(ledger)"
record "exit 1 none" "add: a carriage return" "$(run $'a\rb' add-decision) $(ledger)"
record "exit 1 none" "add: a C1 control as UTF-8 (CSI)" "$(run $'a\xc2\x9b2J' add-decision) $(ledger)"
# A NUL can't sit in a shell variable, so it's fed straight in: it's refused
# like any control character, not silently dropped.
for input in 'Why: w\nab\000cd' 'Why: a\000b\nthe text'; do
	record "exit 1 none" "add: a NUL ($input)" \
		"$(cd "$work" && printf "$input" | env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" \
			CLAUDE_CODE_SESSION_ID="$sid" "$BASH" "$script" add-need >/dev/null 2>"$tmp/err"; echo "exit $?") $(ledger)"
done
record 1 "add: a NUL says it's a control character" "$(grep -c 'control character' "$tmp/err")"
record "exit 0" "add: other UTF-8 is kept" "$(run $'caf\xc3\xa9 \xe2\x80\x94 ok' add-decision)"
reset
record "exit 0" "add: 4000 bytes accepted" "$(run "$(printf 'x%.0s' $(seq 4000))" add-decision)"
reset
record "exit 1 none" "add: over 4000 bytes refused" "$(run "$(printf 'x%.0s' $(seq 4001))" add-decision) $(ledger)"
record 1 "add: says why" "$(grep -c 'over 4000 bytes' "$tmp/err")"

# The Why line: the first line, kept apart from the text.
reset
run $'Why:   #208: status answers are rebuilt every time  \n\nReview PR #212\nthen say finish' add-need >/dev/null
record '"#208: status answers are rebuilt every time" "Review PR #212\nthen say finish"' \
	"add: the Why line is stored trimmed, the blank line after it dropped" \
	"$(jq -r '"\(.why | tojson) \(.text | tojson)"' "$dir/$sid.jsonl")"
reset
record "exit 1 none" "add: no Why line" "$(NOWHY=1 run 'Review PR #212' add-need) $(ledger)"
record 1 "add: no Why line says how" "$(grep -c "start the text with 'Why: <history and goal>'" "$tmp/err")"
record "exit 1 none" "add: a Why line not first" "$(NOWHY=1 run $'Review PR #212\nWhy: a goal' add-need) $(ledger)"
record "exit 1 none" "add: a lowercase why" "$(NOWHY=1 run $'why: a goal\nReview' add-need) $(ledger)"
record "exit 1 none" "add: an empty Why line" "$(NOWHY=1 run $'Why:  \t\nReview' add-need) $(ledger)"
record 1 "add: an empty Why line says so" "$(grep -c 'the Why line is empty' "$tmp/err")"
record "exit 1 none" "add: a Why line and nothing else" "$(NOWHY=1 run 'Why: a goal' add-decision) $(ledger)"
record 1 "add: nothing after the Why line says so" "$(grep -c 'the text after the Why line is empty' "$tmp/err")"
record "exit 1 none" "add: a Why line over 200 bytes" \
	"$(NOWHY=1 run "Why: $(printf 'x%.0s' $(seq 201))"$'\nReview' add-need) $(ledger)"
record "exit 0" "add: a 200-byte Why line" "$(NOWHY=1 run "Why: $(printf 'x%.0s' $(seq 200))"$'\nReview' add-need)"
reset
record "exit 1 none" "add: a control character in the Why line" "$(NOWHY=1 run $'Why: red \033[31m\nReview' add-need) $(ledger)"

# --- session id --------------------------------------------------------------

reset
record "exit 1" "no session id" \
	"$(cd "$work" && printf '%s\nt' "$WHY" | env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" \
		"$BASH" "$script" add-decision >/dev/null 2>"$tmp/err"; echo "exit $?")"
record 1 "no session id: says why" "$(grep -c 'no session id' "$tmp/err")"
record "exit 0 d1" "CLAUDE_SESSION_ID is the fallback" \
	"$(cd "$work" && printf '%s\nt' "$WHY" | env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" \
		CLAUDE_SESSION_ID="$sid" "$BASH" "$script" add-decision >/dev/null 2>&1; echo "exit $?") $(jq -r .id "$dir/$sid.jsonl")"
reset
for bad in '../x' '.' 'a/b' 'a..b' 'a b'; do
	record "exit 1" "session id '$bad' refused" "$(run_as "$bad" t add-decision)"
done
record "none" "a refused session id writes nothing" "$(ls -A "$dir" 2>/dev/null || printf none)"
record "exit 0 $tmp/home/.claude/session-ledger/$sid.jsonl" "default directory under HOME" \
	"$(cd "$work" && printf '%s\nt' "$WHY" | env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_CODE_SESSION_ID="$sid" \
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

# A hand-edited line is left as it is: an id not of the script's form doesn't
# take part in numbering (n1.5 once broke the arithmetic and blocked every
# add), and a line that isn't an entry isn't stamped, even when its id or ref
# matches.
reset
mkdir -p "$dir"
cat >"$dir/$sid.jsonl" <<'EOF'
{"kind":"need","id":"n1.5","text":"an odd id","at":"2020-01-01T00:00:00Z"}
{"kind":"need","id":"n1e999","text":"a huge one","at":"2020-01-01T00:00:00Z"}
{"kind":"need","id":"n3","text":"a real one","at":"2020-01-01T00:00:00Z"}
{"kind":"need","id":"n3","text":5,"ref":"ABC-1","at":"2020-01-01T00:00:00Z"}
{"kind":"need","id":"n9","text":"bad ref type","ref":7,"at":"2020-01-01T00:00:00Z"}
EOF
record "exit 0 n4" "add: an odd id doesn't block numbering" "$(run 'next' add-need) $(cat "$tmp/out")"
record "exit 0" "resolve: the entry with the id" "$(run '' resolve n3)"
record "T none" "resolve: a malformed line with the same id is left alone" \
	"$(sed -n 3p "$dir/$sid.jsonl" | jq -r '.resolved_at // "none"' | sed 's/^[0-9].*Z$/T/') $(sed -n 4p "$dir/$sid.jsonl" | jq -r '.resolved_at // "none"')"
record "exit 0" "resolve --ref: only entries are stamped" "$(run '' resolve --ref 'ABC-1')"
record "none" "resolve --ref: a malformed line under the ref is left alone" "$(sed -n 4p "$dir/$sid.jsonl" | jq -r '.resolved_at // "none"')"

# Past the last id of the form, numbering stops rather than repeat one.
reset
mkdir -p "$dir"
printf '%s\n' '{"kind":"need","id":"n999999999","text":"t","at":"2020-01-01T00:00:00Z"}' >"$dir/$sid.jsonl"
record "exit 1" "add: no need id left" "$(run 'one more' add-need)"
record 1 "add: no need id left says so" "$(grep -c 'used every need id' "$tmp/err")"
record "exit 0 d1" "add: a decision still numbers on its own" "$(run 'decided' add-decision) $(cat "$tmp/out")"

# A ledger path that is a directory fails every write, rather than taking
# the new ledger inside it and reporting success.
reset
mkdir -p "$dir/$sid.jsonl"
record "exit 1" "add: a ledger path that is a directory" "$(run 'lost' add-need)"
record 1 "add: a directory for a ledger says so" "$(grep -c 'not a regular file' "$tmp/err")"
record "" "add: nothing is written into it" "$(ls -A "$dir/$sid.jsonl")"
record "exit 1" "list: a ledger path that is a directory" "$(run '' list)"

# The cross-session forms are #316's: refused here.
record "exit 1" "resolve: --session is refused" "$(run '' resolve n1 --session "$other")"
record "exit 1" "resolve: an extra argument" "$(run '' resolve n1 n2)"

# --- list --------------------------------------------------------------------

reset
record "exit 0" "list: no ledger" "$(run '' list)"
record 1 "list: no ledger says so" "$(grep -c 'no entries' "$tmp/out")"

run 'Keep it local' add-decision --ref '#208' >/dev/null
run $'Why: the owner reviews before a merge\nReview PR #212\nthen say finish' add-need --ref '#212' >/dev/null
run 'Unlock 1Password' add-need >/dev/null
run '' resolve n2 >/dev/null
run '' list >/dev/null
expected="Open needs (1):
  n1 · DATE · #212
    Why: the owner reviews before a merge
    Review PR #212
    then say finish
Decisions (1):
  d1 · DATE · #208
    Why: a test goal
    Keep it local
Resolved needs (1):
  n2 · DATE
    Why: a test goal
    Unlock 1Password"
record "$expected" "list: this session" \
	"$(sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}/DATE/' "$tmp/out")"
record "exit 1" "list: --all is refused" "$(run '' list --all)"
record "exit 1" "list: an unknown option" "$(run '' list --json)"
# A directory there but unreadable fails, rather than reading as no ledger.
if [ "$(id -u)" -ne 0 ]; then
	chmod 000 "$dir"
	record "exit 1" "list: an unreadable directory fails" "$(run '' list)"
	chmod 755 "$dir"
	record 1 "list: an unreadable directory says so" "$(grep -c 'the ledger directory could not be read' "$tmp/err")"
	record 0 "list: an unreadable directory claims no entries" "$(grep -c 'no entries' "$tmp/out")"
	# An unreadable ledger fails before printing anything.
	chmod 000 "$dir/$sid.jsonl"
	record "exit 1" "list: an unreadable ledger fails" "$(run '' list)"
	chmod 644 "$dir/$sid.jsonl"
	record "" "list: an unreadable ledger prints nothing" "$(cat "$tmp/out")"
fi


# --- writes are atomic and serialized ---------------------------------------

record "" "no temp files left behind (only ledgers and the lock file)" "$(ls -A "$dir" | grep -v -e '\.jsonl$' -e '^notes\.txt$' -e '^\.lock$')"

# Twenty adds at once, twice over, with resolves among them: every entry
# lands, numbered without a repeat. (A lock that could be deleted and remade
# lost entries here: a waiter that saw a holder exit removed its successor's.)
reset
run 'first' add-need >/dev/null
run 'second' add-need >/dev/null
for batch in 1 2; do
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		(cd "$work" && printf '%s\nneed %s.%s' "$WHY" "$batch" "$i" | env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" \
			CLAUDE_CODE_SESSION_ID="$sid" "$BASH" "$script" add-need >/dev/null 2>&1) &
	done
	run '' resolve "n$batch" >/dev/null &
	wait
done
record "42 42 2" "concurrent writes: none lost, ids unique, the resolves kept" \
	"$(jq -s '"\(length) \([.[].id] | unique | length) \([.[] | select(.resolved_at)] | length)"' -r "$dir/$sid.jsonl")"

# hold_lock <seconds>: hold the ledger directory's lock from a background
# process for <seconds>, as a write in progress does; sets holder to its pid.
hold_lock() {
	mkdir -p "$dir"
	(
		exec 9>>"$dir/.lock"
		perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or die; flock($f, LOCK_EX) or die'
		exec sleep "$1"
	) &
	holder=$!
	# Until the lock is taken: a non-blocking try fails while it's held.
	until ! perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)' "$dir/.lock"; do
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
	(cd "$repo_dir" && with_why "$1" "$2" | env -i PATH="$PATH" HOME="$tmp/home" \
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
# A trailing slash on origin's URL doesn't leave the ref unqualified.
git -C "$repo_dir" remote set-url origin https://github.com/acme/widgets.git/
in_repo 'a trailing slash' add-decision --ref '#14' >/dev/null
record "acme/widgets#14" "add: an origin with a trailing slash" "$(jq -r 'select(.id == "d2") | .ref' "$dir/$sid.jsonl")"
git -C "$repo_dir" remote set-url origin https://github.com/acme/widgets
record "exit 0" "add: outside a checkout a bare ref stays" "$(run 'no repo' add-need --ref '#12')"
record "#12" "add: outside a checkout, the ref as given" "$(jq -r 'select(.id == "n5") | .ref' "$dir/$sid.jsonl")"
# GitHub ignores an owner's and a repo's case, so a qualified ref's are
# lowercased, whatever origin or the caller spelled.
git -C "$repo_dir" remote set-url origin git@github.com:Acme/Widgets.git
reset
in_repo 'from a mixed-case origin' add-need --ref '#14' >/dev/null
in_repo 'given mixed case' add-need --ref 'Other/Repo#5' >/dev/null
in_repo 'a jira ref' add-need --ref 'ABC-12' >/dev/null
record "acme/widgets#14 other/repo#5 ABC-12" "add: a qualified ref's owner and repo are lowercased, other refs kept" \
	"$(jq -r .ref "$dir/$sid.jsonl" | tr '\n' ' ' | sed 's/ $//')"
git -C "$repo_dir" remote set-url origin git@github.com:acme/widgets.git

# --- resolve --ref -----------------------------------------------------------

# Every open need of this session's under the ref is resolved, and their ids
# printed; another ref's, a need already resolved, and another session's
# ledger are left alone.
reset
mkdir -p "$dir"
cat >"$dir/$sid.jsonl" <<EOF
{"kind":"need","id":"n1","why":"w","text":"the hand-back","ref":"acme/widgets#12","at":"2020-01-01T10:00:00Z"}
{"kind":"need","id":"n2","why":"w","text":"done","ref":"acme/widgets#12","at":"2020-01-01T10:00:00Z","resolved_at":"2020-01-01T11:00:00Z"}
{"kind":"need","id":"n3","why":"w","text":"blocked on #12","ref":"acme/widgets#12","at":"2020-01-01T10:30:00Z"}
{"kind":"need","id":"n4","why":"w","text":"another PR","ref":"acme/widgets#13","at":"2020-01-01T10:00:00Z"}
EOF
cat >"$dir/$other.jsonl" <<EOF
{"kind":"need","id":"n1","why":"w","text":"theirs","ref":"acme/widgets#12","at":"2020-01-01T10:00:00Z"}
EOF
record "exit 0" "resolve --ref: this session's open needs under it" "$(in_repo '' resolve --ref '#12')"
record "n1 n3" "resolve --ref: prints the ids it stamped" "$(tr '\n' ' ' <"$tmp/out" | sed 's/ $//')"
record "n1 n2:2020-01-01T11:00:00Z n3" "resolve --ref: those stamped, the old stamp kept" \
	"$(jq -r 'select(.resolved_at) | "\(.id)\(if .id == "n2" then ":" + .resolved_at else "" end)"' "$dir/$sid.jsonl" | tr '\n' ' ' | sed 's/ $//')"
record "none" "resolve --ref: another session's ledger left alone" "$(jq -r '.resolved_at // "none"' "$dir/$other.jsonl")"
record "exit 0 n4" "resolve --ref: matched whatever the case of its owner and repo" \
	"$(run '' resolve --ref 'ACME/Widgets#13') $(cat "$tmp/out")"
record "exit 0" "resolve --ref: nothing open under the ref" "$(in_repo '' resolve --ref '#99')"
record 1 "resolve --ref: says so" "$(grep -c 'no open need has the ref acme/widgets#99' "$tmp/err")"
record "exit 1" "resolve --ref: a bad ref" "$(run '' resolve --ref 'a b')"
record "exit 1" "resolve --ref: with a need id" "$(run '' resolve --ref '#12' n1)"
record "exit 1" "resolve --ref: needs a session id" \
	"$(cd "$work" && env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" \
		"$BASH" "$script" resolve --ref 'ABC-12' >/dev/null 2>&1; echo "exit $?")"
reset
record "exit 0" "resolve --ref: no ledger yet" "$(run '' resolve --ref 'ABC-12')"

# The lock is the directory's, so a write to one ledger waits on a write to
# another.
reset
run 'mine' add-need >/dev/null
hold_lock 1
started=$(date +%s)
record "exit 0" "a held lock holds another session's write too" "$(run_as "$other" 'theirs' add-need)"
record yes "another session's write waited for it" "$([ $(($(date +%s) - started)) -ge 1 ] && echo yes)"
wait "$holder"

# A ref is checked again once its repo is added: one that a write could store
# is one resolve --ref takes.
long=$(printf 'r%.0s' $(seq 197))
git -C "$repo_dir" remote set-url origin "git@github.com:acme/$long.git"
reset
record "exit 1 none" "add: a ref over 200 bytes with its repo" "$(in_repo 'x' add-need --ref '#12') $(ledger)"
record 1 "add: a long qualified ref says so" "$(grep -c 'the ref is over 200 bytes' "$tmp/err")"

finish
