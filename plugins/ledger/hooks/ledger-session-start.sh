#!/usr/bin/env bash
# SessionStart — hand the plugin root to Bash commands, and reap old ledgers.
#
# 1. Export CLAUDE_LEDGER_ROOT, which the docs run scripts/ledger.sh from.
#    Only a hook knows CLAUDE_PLUGIN_ROOT, and CLAUDE_ENV_FILE is writable
#    from SessionStart only. ledger.sh keys the ledger on the harness's
#    CLAUDE_CODE_SESSION_ID; on a CLI that doesn't set it (before 2.1.132),
#    export CLAUDE_SESSION_ID too, as ticket-workflow's hook does, so the
#    ledger works without that plugin. (A child launched from the Bash tool
#    inherits that export; the spawn edges strip it.)
#
# 2. Opportunistic GC: ledgers outlive their sessions and nothing else reaps
#    them. Delete those untouched for 30 days, after touching this session's
#    own so a still-live session doesn't lose an old one. Only in the default
#    location: an overridden directory (test scaffolding, or a misconfigured
#    broad path) must never have its contents deleted by this hook.
#
# Fails open: this hook must never block a session from starting.
set -uo pipefail

input=$(cat)

# The session id, read with a bash regex: only a plain token may name a file.
session_id=
id_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]+)"'
if [[ $input =~ $id_re ]]; then
	case "${BASH_REMATCH[1]}" in
	. | *..*) ;;
	*) session_id=${BASH_REMATCH[1]} ;;
	esac
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
	{
		[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] &&
			printf 'export CLAUDE_LEDGER_ROOT=%q\n' "$CLAUDE_PLUGIN_ROOT"
		[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -z "$session_id" ] ||
			printf 'export CLAUDE_SESSION_ID=%q\n' "$session_id"
	} >>"$CLAUDE_ENV_FILE" 2>/dev/null || true
fi

[ -z "${CLAUDE_SESSION_LEDGER_DIR:-}" ] && [ -n "${HOME:-}" ] || exit 0
dir="$HOME/.claude/session-ledger"
[ -d "$dir" ] || exit 0

[ -z "$session_id" ] || [ ! -f "$dir/$session_id.jsonl" ] || touch "$dir/$session_id.jsonl" 2>/dev/null

# A ledger, a temp file a killed write left behind, or a lock file (which
# every write touches, so one in use is never this old).
find "$dir" -maxdepth 1 -type f \( -name '*.jsonl' -o -name '.*.jsonl.*' \) -mtime +30 -delete 2>/dev/null || true
