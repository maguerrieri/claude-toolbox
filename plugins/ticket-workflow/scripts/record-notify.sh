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
#   [ -n "${CLAUDE_TICKET_WORKFLOW_ROOT:-}" ] &&
#     bash "$CLAUDE_TICKET_WORKFLOW_ROOT/scripts/record-notify.sh" <<'NOTIFY_NAME_EOF'
#   <session name>
#   NOTIFY_NAME_EOF
#
# It replaces any earlier notify: line (a re-brief naming a new spawner wins)
# and keeps the role (first line) and issue: lines in place. It records
# nothing, prints why on stderr, and exits 1 when there is no marker to add to
# or the name fails notify_name_ok, the check role-session-start.sh applies
# before printing it.
set -uo pipefail
# Bytes, not characters: grep must not treat a marker as binary over its
# encoding, and the trim below must match notify_name_ok's C-locale classes.
export LC_ALL=C

skip() {
	printf 'record-notify: %s; nothing recorded\n' "$1" >&2
	exit 1
}

# shellcheck source=notify-name.sh
. "$(dirname "${BASH_SOURCE[0]}")/notify-name.sh" || skip 'notify-name.sh is missing'

name=$(head -n 1)
# Trim surrounding whitespace, which notify_name_ok refuses.
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

notify_name_ok "$name" ||
	skip 'the name is empty, over 200 bytes, or has a control character, a backtick, or a line break'

# Rebuild the marker without its notify: lines. A failed read must not become
# a marker whose first line (the role) is blank, so require the rest to read.
rest=$(grep -v '^notify: ' "$marker") && [ -n "$rest" ] || skip 'the marker could not be read'
printf '%s\nnotify: %s\n' "$rest" "$name" >"$marker.tmp" && mv "$marker.tmp" "$marker" ||
	skip 'the marker could not be written'
