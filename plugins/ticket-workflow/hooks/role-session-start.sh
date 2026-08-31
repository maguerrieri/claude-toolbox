#!/usr/bin/env bash
# Claude ROLE_STATE SessionStart implementation — session-id export + charter
# re-injection. Codex role state is prompt-durable and does not use this hook.
#
# Two jobs:
#
# 1. Export CLAUDE_SESSION_ID. Claude Code does not expose the session id to the
#    Bash tool, and CLAUDE_ENV_FILE is writable from SessionStart *only* — so
#    this is the one place `/role` can be given a session-scoped key to write
#    its marker under.
#
# 2. Re-inject the charter. A role pinned by `/role` lives in a marker file, but
#    the charter text itself lives in the conversation — which `/compact` and
#    `/clear` discard and `--resume` never had. Re-emitting it on those sources
#    is what makes a role durable rather than merely initial. (stdout from a
#    SessionStart hook is injected as session context.)
#
# Fails open: this hook must never block a session from starting.
set -uo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$session_id" ] || exit 0

# Session ids are opaque tokens from Claude Code; anything with a path
# separator or dot-dot must not reach the marker-path construction.
case "$session_id" in
*[!A-Za-z0-9._-]* | *..*) exit 0 ;;
esac

# 1. Hand the session id — and this plugin's root, which only a hook knows — to
#    subsequent Bash commands. This is how /role keys its marker and locates the
#    charters. CLAUDE_ENV_FILE expects `export KEY=value` lines.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
	{
		printf 'export CLAUDE_SESSION_ID=%q\n' "$session_id"
		[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] &&
			printf 'export CLAUDE_TICKET_WORKFLOW_ROOT=%q\n' "$CLAUDE_PLUGIN_ROOT"
	} >>"$CLAUDE_ENV_FILE" 2>/dev/null || true
fi

# Fail open (not an unbound-variable abort) when neither the override nor HOME
# is available.
[ -n "${CLAUDE_SESSION_ROLES_DIR:-}${HOME:-}" ] || exit 0
roles_dir="${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}"
marker="$roles_dir/$session_id"

# Refresh THIS session's marker before GC runs: a still-live session must not
# have its own pin reaped just because it was set >30 days ago.
[ -f "$marker" ] && touch "$marker" 2>/dev/null || true

# Opportunistic GC: markers outlive their sessions and nothing else reaps them.
# Only in the DEFAULT location — an overridden roles dir (test scaffolding, or a
# misconfigured broad path) must never have its contents deleted by this hook.
if [ -z "${CLAUDE_SESSION_ROLES_DIR:-}" ] && [ -d "$roles_dir" ]; then
	find "$roles_dir" -type f -mtime +30 -delete 2>/dev/null || true
fi

[ -f "$marker" ] || exit 0

role=$(tr -d '[:space:]' <"$marker" 2>/dev/null) || exit 0

# Whitelist the role before using it in a path or printf: a corrupt/hostile
# marker must not become a traversal or context-injection channel.
case "$role" in
planner | epic-coordinator | implementer) ;;
*) exit 0 ;;
esac

charter="${CLAUDE_PLUGIN_ROOT:-}/skills/ticket-workflow/roles/${role}.md"
[ -f "$charter" ] || exit 0

printf 'This session is pinned to the **%s** role charter (set earlier via `/role %s`; re-attached at session start — after resume, /clear, or compaction). It governs this session until `/role none`.\n\n' "$role" "$role"
cat "$charter"
