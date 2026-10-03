# shellcheck shell=bash
# Sourced by scripts/role-marker.sh and both hooks: where role markers live,
# which session ids may name one, and how a marker's role is read. The hooks
# take the session id from their input and role-marker.sh from the
# environment, so each finds the id itself and hands it to these.

# marker_roles_dir sets roles_dir to the marker directory, and fails when
# neither CLAUDE_SESSION_ROLES_DIR (the override tests use) nor HOME is set.
marker_roles_dir() {
	[ -n "${CLAUDE_SESSION_ROLES_DIR:-}${HOME:-}" ] || return 1
	# shellcheck disable=SC2034 # read by the scripts that source this
	roles_dir="${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}"
}

# marker_id_ok <id> succeeds when <id> is a plain token. Session ids are opaque
# tokens from Claude Code, and anything with a path separator, a dot-dot, or
# nothing but a dot must not reach a marker path.
marker_id_ok() {
	case "$1" in
	'' | . | *[!A-Za-z0-9._-]* | *..*) return 1 ;;
	esac
}

# marker_role_of <text> prints the role in <text>, a marker's content: its
# first line, whitespace stripped. Only that line is the role. A self-pinned
# implementer's marker records its issue on the next line (`issue: <id>`),
# which must not run into it.
marker_role_of() {
	local first=${1%%$'\n'*}
	printf '%s' "${first//[[:space:]]/}"
}

# marker_role <marker> prints the role of the marker file, as marker_role_of
# reads it.
marker_role() {
	marker_role_of "$(head -n 1 "$1" 2>/dev/null)"
}
