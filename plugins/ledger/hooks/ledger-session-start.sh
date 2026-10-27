#!/usr/bin/env bash
# SessionStart — hand the plugin root to Bash commands, and reap old ledgers.
#
# 1. Export CLAUDE_LEDGER_ROOT, which the docs run scripts/ledger.sh from.
#    Only a hook knows CLAUDE_PLUGIN_ROOT, and CLAUDE_ENV_FILE is writable
#    from SessionStart only. The session id needs no export: ledger.sh reads
#    the harness's CLAUDE_CODE_SESSION_ID (or ticket-workflow's fallback).
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

if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
	printf 'export CLAUDE_LEDGER_ROOT=%q\n' "$CLAUDE_PLUGIN_ROOT" >>"$CLAUDE_ENV_FILE" 2>/dev/null || true
fi

[ -z "${CLAUDE_SESSION_LEDGER_DIR:-}" ] && [ -n "${HOME:-}" ] || exit 0
dir="$HOME/.claude/session-ledger"
[ -d "$dir" ] || exit 0

# The session id, read with a bash regex: only a plain token may name a file.
id_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]+)"'
if [[ $input =~ $id_re ]]; then
	case "${BASH_REMATCH[1]}" in
	. | *..*) ;;
	*) [ -f "$dir/${BASH_REMATCH[1]}.jsonl" ] && touch "$dir/${BASH_REMATCH[1]}.jsonl" 2>/dev/null ;;
	esac
fi

# A ledger, or a temp file a killed write left behind.
find "$dir" -maxdepth 1 -type f \( -name '*.jsonl' -o -name '.*.jsonl.*' \) -mtime +30 -delete 2>/dev/null || true
