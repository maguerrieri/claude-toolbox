#!/usr/bin/env bash
# Record this session's Notify: target in its role marker, as a
# `notify: <session name>` line (START Step 1's *Note your notifier*; EPIC
# Step 1 for a coordinator's own). role-session-start.sh re-injects it next to
# the charter after resume, /clear, or compaction, which the briefing that
# named it does not survive.
#
# The name comes on stdin from a quoted heredoc, so no character in it ever
# reaches the shell as syntax:
#
#   bash "$CLAUDE_TICKET_WORKFLOW_ROOT/scripts/record-notify.sh" <<'NOTIFY'
#   <session name>
#   NOTIFY
#
# It replaces any earlier notify: line (a re-brief naming a new spawner wins)
# and keeps the role (first line) and issue: lines in place. It records
# nothing, prints why on stderr, and exits 1 when there is no marker to add to
# or the name fails the check role-session-start.sh applies before printing it.
set -uo pipefail

skip() {
	printf 'record-notify: %s; nothing recorded\n' "$1" >&2
	exit 1
}

name=$(head -n 1)
# Trim surrounding whitespace: the hook refuses a name that has any.
name=${name#"${name%%[![:space:]]*}"}
name=${name%"${name##*[![:space:]]}"}

[ -n "${CLAUDE_SESSION_ID:-}" ] || skip 'CLAUDE_SESSION_ID is unset (the SessionStart hook did not run)'
case "$CLAUDE_SESSION_ID" in
*[!A-Za-z0-9._-]* | *..*) skip 'CLAUDE_SESSION_ID is not a plain token' ;;
esac
[ -n "${CLAUDE_SESSION_ROLES_DIR:-}${HOME:-}" ] || skip 'neither CLAUDE_SESSION_ROLES_DIR nor HOME is set'
roles_dir="${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}"
marker="$roles_dir/$CLAUDE_SESSION_ID"
[ -f "$marker" ] || skip 'this session has no role marker, so the target stays in context only'

# The same check as role-session-start.sh: the name is printed into session
# context inside a code span, so no control character (no second line) and no
# backtick (no way out of the span), and a length a session name can have.
case "$name" in
'') skip 'the name is empty' ;;
*[[:cntrl:]]* | *'`'*) skip 'the name has a control character or a backtick' ;;
esac
[ "${#name}" -le 200 ] || skip 'the name is longer than 200 characters'

# Rebuild the marker without its notify: lines. A failed read must not become
# a marker whose first line (the role) is blank, so require the rest to read.
rest=$(grep -v '^notify: ' "$marker") && [ -n "$rest" ] || skip 'the marker could not be read'
printf '%s\nnotify: %s\n' "$rest" "$name" >"$marker.tmp" && mv "$marker.tmp" "$marker" ||
	skip 'the marker could not be written'
