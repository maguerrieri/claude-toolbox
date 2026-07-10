#!/usr/bin/env bash
# PreToolUse — planner drift guard.
#
# A session pinned to the `planner` charter shouldn't edit files: it decomposes,
# files tickets, and spawns. This escalates an edit to a permission prompt
# ("ask") rather than a hard deny, so an *unattended* planner can't silently
# drift into implementation, while a human at the wheel approves with one
# keystroke. That matches the charters' stated philosophy: the guard is the
# unattended default, not a lock.
#
# Fails open: any missing dependency, unreadable marker, or unparseable payload
# exits 0 (allow). This is a drift nudge, not a security control.
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

# Fail open (not an unbound-variable abort) when neither the override nor HOME
# is available.
[ -n "${CLAUDE_SESSION_ROLES_DIR:-}${HOME:-}" ] || exit 0
roles_dir="${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}"
marker="$roles_dir/$session_id"
[ -f "$marker" ] || exit 0

role=$(tr -d '[:space:]' <"$marker" 2>/dev/null) || exit 0
[ "$role" = "planner" ] || exit 0

# Defense in depth: hooks.json already filters on `matcher`, but a future
# matcher change shouldn't silently widen the guard.
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case "$tool" in
Edit | Write | MultiEdit | NotebookEdit) ;;
*) exit 0 ;;
esac

reason="This session is pinned to the planner charter (/role planner), which owns the whole initiative and delegates the work drawn on it.

Planners don't implement: file the work (/make-ticket) and hand it down (/spawn-epic, /spawn-tickets).

Approve to make this one edit anyway, or run '/role none' to drop the charter for the rest of the session."

jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: $reason
  }
}'
