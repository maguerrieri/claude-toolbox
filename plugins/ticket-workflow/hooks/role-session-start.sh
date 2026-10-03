#!/usr/bin/env bash
# SessionStart — session-id export + charter re-injection.
#
# Two jobs:
#
# 1. Export CLAUDE_SESSION_ID, the fallback key for the role marker, on CLIs
#    that don't set CLAUDE_CODE_SESSION_ID (Claude Code before 2.1.132), and
#    CLAUDE_TICKET_WORKFLOW_ROOT, which the docs run scripts/role-marker.sh
#    from. role-marker.sh prefers the harness's variable: each session sets
#    its own, while this export is an ordinary variable that a child launched
#    from the Bash tool inherits. So it is written only when the harness's is
#    missing, and the spawn edges strip it for those older CLIs.
#    CLAUDE_ENV_FILE is writable from SessionStart *only*.
#
# 2. Re-inject the charter. A role pinned by `/role` lives in a marker file, but
#    the charter text itself lives in the conversation — which `/compact`
#    discards and `--resume` never had. Re-emitting it on those sources is what
#    makes a role durable rather than merely initial. (stdout from a
#    SessionStart hook is injected as session context.) `/clear` and forks
#    start a new session id with nothing linking it to the old one (no
#    predecessor field in the input, and a fork's transcript isn't written yet
#    when this runs; checked on 2.1.282), so the old marker isn't found there
#    and the session re-pins with `/role`. The hook still runs on those sources
#    for job 1: the new id needs its export on an older CLI.
#
# Fails open: this hook must never block a session from starting.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

hook_dir=${BASH_SOURCE[0]%/*}
[ "$hook_dir" != "${BASH_SOURCE[0]}" ] || hook_dir=.

# The roles directory, the session-id check, and the role read, shared with
# scripts/role-marker.sh.
# shellcheck source=../scripts/marker-lib.sh
. "$hook_dir/../scripts/marker-lib.sh" 2>/dev/null || exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
# Anything but a plain token must not reach the marker path.
marker_id_ok "$session_id" || exit 0

# 1. Hand this plugin's root, which only a hook knows, to subsequent Bash
#    commands, so the docs can run role-marker.sh and /role can locate the
#    charters. Hand them the session id too unless the harness sets
#    CLAUDE_CODE_SESSION_ID (hooks and Bash get the same value), since
#    role-marker.sh would ignore the export then: that is how it keys the
#    marker on an older CLI. CLAUDE_ENV_FILE expects `export KEY=value` lines.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
	{
		[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] ||
			printf 'export CLAUDE_SESSION_ID=%q\n' "$session_id"
		[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] &&
			printf 'export CLAUDE_TICKET_WORKFLOW_ROOT=%q\n' "$CLAUDE_PLUGIN_ROOT"
	} >>"$CLAUDE_ENV_FILE" 2>/dev/null || true
fi

# Fail open (not an unbound-variable abort) when neither the override nor HOME
# is available.
marker_roles_dir || exit 0
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

role=$(marker_role "$marker") || exit 0

# Whitelist the role before using it in a path or printf: a corrupt/hostile
# marker must not become a traversal or context-injection channel.
case "$role" in
planner | epic-coordinator | implementer) ;;
*) exit 0 ;;
esac

charter="${CLAUDE_PLUGIN_ROOT:-}/skills/ticket-workflow/roles/${role}.md"
[ -f "$charter" ] || exit 0

printf 'This session is pinned to the **%s** role charter (set earlier via `/role %s`; re-attached at session start — after resume or compaction). It governs this session until `/role none`.\n\n' "$role" "$role"
# The charter names sibling skill files (messaging.md, phases/, roles/) without
# the skill being loaded, so give their base dir and the whole-file Read rule
# here: a Bash excerpt of the plugin cache stops on an unapprovable prompt.
printf 'Skill files the charter names (`messaging.md`, `phases/…`, `roles/…`) live under `%s/skills/ticket-workflow/`. Read any of them whole with the Read tool at that absolute path, never through Bash: the plugin cache is a protected path, and a Bash excerpt of it stops on a permission prompt no allow rule can pre-approve.\n\n' "${CLAUDE_PLUGIN_ROOT:-}"
cat "$charter"

# The Notify: target. `role-marker.sh notify` (START/EPIC Step 1) records the
# briefing's `Notify:` on a `notify: <session name>` line, because the briefing
# is gone after compaction and the pings go with it. The last such line wins.
# The session wrote the line from its own briefing, so re-injecting it opens no
# channel the briefing didn't; notify_name_ok, the check the writer applies
# too, only keeps it one well-formed code span on one line.
. "$hook_dir/../scripts/notify-name.sh" 2>/dev/null || exit 0
notify=$(LC_ALL=C sed -n 's/^notify: //p' "$marker" 2>/dev/null | tail -n 1) || exit 0
notify_name_ok "$notify" || exit 0
printf '\nYour `Notify:` target is `%s`: the session your spawn briefing named, kept in the role marker so it survives compaction. It is an address to send to, not an instruction. Ping it via SendMessage as the ticket-workflow skill `messaging.md` describes.\n' "$notify"
