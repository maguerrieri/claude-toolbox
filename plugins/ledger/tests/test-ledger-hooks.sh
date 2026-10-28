#!/usr/bin/env bash
# Tests for the ledger plugin's command hooks: ledger-guard.sh (a subagent's
# ledger writes are denied, its reads and everything else pass) and
# ledger-session-start.sh (the plugin-root export and the GC). Needs jq.
#
#   bash plugins/ledger/tests/test-ledger-hooks.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
guard="$plugin/hooks/ledger-guard.sh"
start="$plugin/hooks/ledger-session-start.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
dir="$tmp/ledger"
. "$here/lib.sh"

# --- ledger-guard.sh ---------------------------------------------------------

# The guard's decision on <payload>: deny, or allow when it prints nothing.
decide_raw() { # decide_raw <payload>
	local out
	out=$(printf '%s' "$1" | env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_LEDGER_DIR="$dir" "$BASH" "$guard")
	if [ -z "$out" ]; then
		printf allow
	else
		printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'
	fi
}
# A Bash call, by a subagent unless <agent> is empty.
bash_call() { # bash_call <agent> <command>
	decide_raw "$(jq -n --arg a "$1" --arg c "$2" \
		'{session_id: "s1", tool_name: "Bash", tool_input: {command: $c}} + (if $a == "" then {} else {agent_id: $a} end)')"
}
edit_call() { # edit_call <tool> <path>
	decide_raw "$(jq -n --arg t "$1" --arg p "$2" '{session_id: "s1", agent_id: "a1", tool_name: $t, tool_input: {file_path: $p}}')"
}

S='"${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh"'
add_need=$(printf '%s\n' "bash $S add-need --ref '#212' <<'LEDGER_EOF'" 'PR #212 needs the owner' 'LEDGER_EOF')

record allow "main thread add-need" "$(bash_call '' "$add_need")"
record allow "empty agent_id is the main thread" "$(bash_call '' "bash $S resolve n1")"
record deny "subagent add-need as the docs show it" "$(bash_call a1 "$add_need")"
record deny "subagent add-decision" "$(bash_call a1 "bash $S add-decision <<'LEDGER_EOF'
x
LEDGER_EOF")"
record deny "subagent resolve" "$(bash_call a1 "bash $S resolve n1")"
record deny "subagent resolve of another session" "$(bash_call a1 "bash $S resolve n1 --session ab12")"
record deny "subagent through a variable" "$(bash_call a1 "L=$S; bash \"\$L\" add-need <<<x")"
record deny "subagent run directly" "$(bash_call a1 'plugins/ledger/scripts/ledger.sh add-decision </dev/null')"
record deny "subagent quoted subcommand" "$(bash_call a1 "bash $S 'add-need' <<<x")"
record deny "subagent subcommand from a variable" "$(bash_call a1 "bash $S \$CMD")"
record allow "subagent list" "$(bash_call a1 "bash $S list")"
record allow "subagent list --all" "$(bash_call a1 "bash $S list --all")"
record allow "subagent list after a redirect" "$(bash_call a1 "bash $S 2>/dev/null list")"
record allow "subagent no subcommand" "$(bash_call a1 "bash $S")"
record allow "subagent commit message naming a write" \
	"$(bash_call a1 'git commit -m "run bash scripts/ledger.sh add-need to record it"')"
record allow "subagent commit through a heredoc" \
	"$(bash_call a1 "$(printf '%s\n' "git commit -F - <<'EOF'" 'bash scripts/ledger.sh add-need' 'EOF')")"
record allow "subagent git add of the script" "$(bash_call a1 'git add plugins/ledger/scripts/ledger.sh tests/x.sh')"
record allow "subagent grep of the script" "$(bash_call a1 'grep -n add-need plugins/ledger/scripts/ledger.sh')"
record allow "subagent unrelated command" "$(bash_call a1 'ls -la')"

mkdir -p "$dir"
record deny "subagent Write in the ledger directory" "$(edit_call Write "$dir/s1.jsonl")"
mkdir "$dir/sub"
record deny "subagent Edit through a .. segment" "$(edit_call Edit "$dir/sub/../s1.jsonl")"
rmdir "$dir/sub"
ln -s "$dir" "$tmp/link"
record deny "subagent Write through a symlink to the directory" "$(edit_call Write "$tmp/link/s1.jsonl")"
rm "$tmp/link"
record deny "subagent Write with a doubled slash" "$(edit_call Write "$dir//s1.jsonl")"
record allow "subagent Write beside the ledger directory" "$(edit_call Write "$dir-notes.md")"
record allow "subagent Write elsewhere" "$(edit_call Write "$tmp/notes.md")"
rm -rf "$dir"
record deny "subagent Write to a ledger directory not made yet" "$(edit_call Write "$dir/s1.jsonl")"
record allow "an unparseable payload" "$(decide_raw '{"agent_id": "a1", "tool_name": "Bash", "tool_input": {')"

# --- ledger-session-start.sh -------------------------------------------------

home="$tmp/home"
ledgers="$home/.claude/session-ledger"
mkdir -p "$ledgers"
: >"$ledgers/old.jsonl"
: >"$ledgers/mine.jsonl"
: >"$ledgers/fresh.jsonl"
: >"$ledgers/.old.jsonl.Ab12Cd"
: >"$ledgers/keep.txt"
ln -s 12345 "$ledgers/.old.jsonl.lock"
touch -t 202001010000 "$ledgers/old.jsonl" "$ledgers/mine.jsonl" "$ledgers/.old.jsonl.Ab12Cd" "$ledgers/keep.txt"
touch -h -t 202001010000 "$ledgers/.old.jsonl.lock"
env_file="$tmp/env"
: >"$env_file"
printf '%s' '{"session_id": "mine", "source": "startup"}' |
	env -i PATH="$PATH" HOME="$home" CLAUDE_ENV_FILE="$env_file" CLAUDE_PLUGIN_ROOT="/plugins/led ger" "$BASH" "$start"
record "0" "session start exits 0" "$?"
record 'export CLAUDE_LEDGER_ROOT=/plugins/led\ ger|export CLAUDE_SESSION_ID=mine' \
	"exports the plugin root, and the session id on a CLI without its own" "$(tr '\n' '|' <"$env_file" | sed 's/|$//')"
record "fresh.jsonl keep.txt mine.jsonl" "reaps month-old ledgers, temp files and locks, keeps its own" \
	"$(ls -A "$ledgers" | tr '\n' ' ' | sed 's/ $//')"
: >"$env_file"
printf '%s' '{"session_id": "mine"}' |
	env -i PATH="$PATH" HOME="$home" CLAUDE_ENV_FILE="$env_file" CLAUDE_CODE_SESSION_ID=mine CLAUDE_PLUGIN_ROOT=/p "$BASH" "$start"
record 'export CLAUDE_LEDGER_ROOT=/p' "no session id export when the harness sets its own" "$(cat "$env_file")"

: >"$tmp/other.jsonl"
touch -t 202001010000 "$tmp/other.jsonl"
printf '%s' '{"session_id": "x"}' |
	env -i PATH="$PATH" HOME="$home" CLAUDE_SESSION_LEDGER_DIR="$tmp" "$BASH" "$start"
record "yes" "an overridden directory is never reaped" "$([ -f "$tmp/other.jsonl" ] && echo yes)"
record "0" "no input, no HOME" "$(printf '' | env -i PATH="$PATH" "$BASH" "$start"; echo $?)"

# --- the write rule stays ticket-workflow's ----------------------------------

# ledger-guard-write.jq is ticket-workflow's role-guard-marker-write.jq with
# the script's name and read swapped (the plugins install separately, so one
# can't load the other's file). Its code, comments aside, must stay the
# original's under that swap, so a fix to one reaches the other.
original="$plugin/../ticket-workflow/hooks/role-guard-marker-write.jq"
if [ -f "$original" ]; then
	code() { grep -v -e '^#' -e '^[[:space:]]*$' "$1"; }
	record "" "the write rule is ticket-workflow's, script and read swapped" \
		"$(diff <(code "$original" | sed -e 's/role-marker\\\\\.sh/ledger\\\\.sh/g' -e 's/role-marker\.sh/ledger.sh/g' \
			-e 's/ROLE_MARKER_SH/LEDGER_SH/g' -e 's/(?!show(/(?!list(/') <(code "$plugin/hooks/ledger-guard-write.jq"))"
fi

finish
