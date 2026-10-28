#!/usr/bin/env bash
# PreToolUse — keep in-process subagents from writing their parent's ledger.
#
# An in-process subagent (or any other agent the harness runs inside this
# session) shares this session: its Bash environment holds the same
# CLAUDE_CODE_SESSION_ID (checked on Claude Code 2.1.312), so a
# `ledger.sh add-need` it ran would land in the parent's ledger, recording a
# need the parent never stopped for. Its calls, and only its calls, carry an
# agent_id. So such a call is denied when it would write the ledger: a Bash
# command that runs scripts/ledger.sh with any subcommand but `list`
# (ledger-guard-write.jq has the rule), or a file edit in the ledger
# directory. Reads pass. Deny, not ask: the write is never the subagent's.
#
# Fails open: any missing dependency or unparseable payload exits 0 (allow).
# This is a drift backstop, not a security control.
set -uo pipefail

input=$(cat)

# Only a subagent's call is judged; every other call leaves here without
# starting jq.
agent_re='"agent_id"[[:space:]]*:[[:space:]]*"[^"]'
[[ $input =~ $agent_re ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

hook_dir=${BASH_SOURCE[0]%/*}
[ "$hook_dir" != "${BASH_SOURCE[0]}" ] || hook_dir=.

[ -n "${CLAUDE_SESSION_LEDGER_DIR:-}${HOME:-}" ] || exit 0
ledger_dir="${CLAUDE_SESSION_LEDGER_DIR:-$HOME/.claude/session-ledger}"

# in_ledger_dir <dir>: is <dir> the ledger directory? -ef compares the
# directory itself, so a `..` segment, a doubled slash or a symlink can't slip
# past. A ledger directory that doesn't exist yet has nothing for -ef to find,
# so then the normalized paths are compared, and the names (ignoring case)
# with their parents by -ef.
in_ledger_dir() {
	[ "$1" -ef "$ledger_dir" ] && return 0
	[ -d "$ledger_dir" ] && return 1
	norm() { printf '%s' "$1" | sed -e 's://*:/:g' -e 's:/\./:/:g' -e 's:/\.$::' -e 's:/$::' | tr '[:upper:]' '[:lower:]'; }
	local got want
	got=$(norm "$1")
	want=$(norm "$ledger_dir")
	[ "$got" = "$want" ] && return 0
	[ "${got##*/}" = "${want##*/}" ] && [ "$(dirname -- "$1")" -ef "$(dirname -- "$ledger_dir")" ]
}

write=no
if [[ $input == *ledger.sh* ]] &&
	printf '%s' "$input" | jq -e -f "$hook_dir/ledger-guard-write.jq" >/dev/null 2>&1; then
	write=yes
else
	file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null) || exit 0
	if [ -n "$file_path" ] && in_ledger_dir "${file_path%/*}"; then
		write=yes
	fi
fi
[ "$write" = yes ] || exit 0

jq -n --arg reason "This call would write the session ledger, and it comes from an in-process subagent or other in-process agent (its hook input carries an agent_id). You run inside your parent's session and share its session id, so the ledger is the parent session's, not yours.

Don't record decisions or needs yourself: report them in your final answer, and the parent records what belongs in its ledger. Reading it (ledger.sh list) is fine. If this command only mentions the script (a commit message, an echo), keep the mention inside quotes or pass the text through a file." '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
