#!/usr/bin/env bash
# role-marker.sh — every read and write of this session's role marker that the
# ticket-workflow docs describe. The marker is one file per session under the
# roles directory: the role on its first line, then any `issue: <id>` lines a
# self-pinned implementer recorded, then at most one `notify: <session name>`
# line. The hooks read it (role-session-start.sh, role-guard.sh); nothing but
# this script writes it.
#
#   role-marker.sh show                         print the marker (nothing if none)
#   role-marker.sh pin <role> [--issue <id>]    pin a role (START/EPIC Step 1, /role)
#   role-marker.sh unpin                        delete the marker (/role none)
#   role-marker.sh notify <<'NOTIFY_NAME_EOF'   record the Notify: target
#   <session name>
#   NOTIFY_NAME_EOF
#
# The docs run it as `bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/role-marker.sh" …`;
# the SessionStart hook sets that variable.
#
# pin keeps the marker when its first line already names <role>, so the other
# lines survive, and otherwise replaces it with the role alone. --issue (an
# implementer's only) then appends `issue: <id>` unless that line is there,
# compared ignoring case. A bad --issue (another role's, or an id outside
# letters, digits, - and _) still pins the role: only the issue line is
# skipped, and stderr says so.
# notify replaces any earlier notify: line and keeps the rest; the name comes
# on stdin, from a quoted heredoc, so no character of it reaches a shell as
# syntax. It must be one line (a single trailing newline aside) and pass
# notify_name_ok, the check role-session-start.sh applies before re-injecting
# it.
#
# The session id is the harness's own CLAUDE_CODE_SESSION_ID (Claude Code
# 2.1.132+), else the CLAUDE_SESSION_ID the SessionStart hook exports on older
# CLIs. The harness's comes first because a child launched from the Bash tool
# can inherit its parent's CLAUDE_SESSION_ID, while it always gets its own
# CLAUDE_CODE_SESSION_ID.
#
# Every write goes to a temp file in the roles directory and is renamed over
# the marker, so a reader never sees half of one, and ends with a newline.
# Exits 0 on success, including show and unpin finding no marker. Exits 1 with
# the reason on stderr when nothing was written or read: no session id, no
# marker for notify, a bad argument.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
# Bytes, not characters: grep must not treat a marker as binary over its
# encoding, and the trim below must match notify_name_ok's C-locale classes.
export LC_ALL=C

cmd=${1:-}
here=$(dirname "${BASH_SOURCE[0]}")

fail() {
	case "$cmd" in
	pin | unpin | notify) printf 'role-marker %s: %s; nothing written\n' "$cmd" "$1" >&2 ;;
	*) printf 'role-marker %s: %s\n' "${cmd:-(no subcommand)}" "$1" >&2 ;;
	esac
	exit 1
}

usage='usage: role-marker.sh show | pin <planner|epic-coordinator|implementer> [--issue <id>] | unpin | notify (name on stdin)'

# shellcheck source=marker-lib.sh
. "$here/marker-lib.sh" 2>/dev/null || fail 'marker-lib.sh is missing'

# Check every argument before touching anything.
role='' issue='' issue_skipped='' name=''
case "$cmd" in
show | unpin)
	[ $# -eq 1 ] || fail "$usage"
	;;
pin)
	[ $# -ge 2 ] || fail "$usage"
	role=$2
	case "$role" in
	planner | epic-coordinator | implementer) ;;
	*) fail "unknown role '$role' (planner, epic-coordinator, or implementer)" ;;
	esac
	shift 2
	# A bad --issue never costs the role its pin: the issue line is skipped and
	# stderr says why. (An unquoted `--issue #52` reaches here with no value,
	# since the shell reads `#52` as a comment.)
	if [ $# -gt 0 ]; then
		[ "$1" = --issue ] && [ $# -le 2 ] || fail "$usage"
		issue=${2-}
		issue=${issue#\#}
		if [ "$role" != implementer ]; then
			issue_skipped='only an implementer records an issue'
		else
			case "$issue" in
			'' | [!A-Za-z0-9]* | *[!A-Za-z0-9_-]*) issue_skipped='the issue id is missing or not just letters, digits, - and _ (GitHub 52, Jira ABC-12)' ;;
			*) [ "${#issue}" -le 64 ] || issue_skipped='the issue id is over 64 characters' ;;
			esac
		fi
		[ -z "$issue_skipped" ] || issue=''
	fi
	;;
notify)
	[ $# -eq 1 ] || fail "$usage"
	# shellcheck source=notify-name.sh
	. "$here/notify-name.sh" 2>/dev/null || fail 'notify-name.sh is missing'
	# The name comes from a heredoc; from a terminal, reading would only block.
	[ ! -t 0 ] || fail "$usage"
	# All of stdin, kept exact (the x stops $(...) from stripping trailing
	# newlines), less one trailing newline: a second line is refused, not cut
	# off, so a heredoc holding two names records neither.
	name=$(
		cat
		printf x
	)
	name=${name%x}
	name=${name%$'\n'}
	case "$name" in
	*$'\n'*) fail 'the name is more than one line' ;;
	esac
	# Trim surrounding whitespace, which notify_name_ok refuses.
	name=${name#"${name%%[![:space:]]*}"}
	name=${name%"${name##*[![:space:]]}"}
	notify_name_ok "$name" ||
		fail 'the name is empty, over 200 bytes, or has a control character, a backtick, or a line break'
	;;
*) fail "$usage" ;;
esac

sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
[ -n "$sid" ] || fail 'no session id (neither CLAUDE_CODE_SESSION_ID nor CLAUDE_SESSION_ID is set)'
marker_id_ok "$sid" || fail 'the session id is not a plain token'
marker_roles_dir || fail 'neither CLAUDE_SESSION_ROLES_DIR nor HOME is set'
marker="$roles_dir/$sid"

# write_marker <content>: <content> and a newline, through a temp file beside
# the marker and a rename over it.
write_marker() {
	local tmp
	mkdir -p "$roles_dir" 2>/dev/null || fail 'the roles directory could not be created'
	tmp=$(mktemp "$roles_dir/.$sid.XXXXXX" 2>/dev/null) || fail 'no temp file could be created in the roles directory'
	if printf '%s\n' "$1" >"$tmp" && mv -f "$tmp" "$marker"; then
		return 0
	fi
	rm -f "$tmp"
	fail 'the marker could not be written'
}

case "$cmd" in
show)
	[ -f "$marker" ] || {
		echo 'role-marker show: this session has no role marker' >&2
		exit 0
	}
	cat "$marker" || fail 'the marker could not be read'
	# A marker without a trailing newline still ends its output with one.
	[ -z "$(tail -c 1 "$marker")" ] || echo
	;;
unpin)
	rm -f "$marker" || fail 'the marker could not be removed'
	;;
pin)
	current=
	if [ -f "$marker" ]; then
		current=$(cat "$marker") || fail 'the marker could not be read'
	fi
	content=$role
	[ "$(marker_role_of "$current")" = "$role" ] && content=$current
	# Case-insensitive, as the one-issue guard compares Jira keys. The new line
	# goes before any notify: line, keeping the layout the header gives.
	if [ -n "$issue" ] && ! printf '%s\n' "$content" | grep -qixF "issue: $issue"; then
		notify_lines=$(printf '%s\n' "$content" | grep '^notify: ')
		content="$(printf '%s\n' "$content" | grep -v '^notify: ')"$'\n'"issue: $issue"
		[ -z "$notify_lines" ] || content="$content"$'\n'"$notify_lines"
	fi
	# An unchanged marker is left alone.
	[ "$content" = "$current" ] || write_marker "$content"
	[ -z "$issue_skipped" ] ||
		printf 'role-marker pin: pinned %s, but recorded no issue: %s\n' "$role" "$issue_skipped" >&2
	;;
notify)
	[ -f "$marker" ] || fail 'this session has no role marker, so the target stays in context only'
	# A failed read must not become a marker whose first line (the role) is
	# blank, so require the rest to read.
	rest=$(grep -v '^notify: ' "$marker") && [ -n "$rest" ] || fail 'the marker could not be read'
	write_marker "$rest"$'\n'"notify: $name"
	;;
esac
