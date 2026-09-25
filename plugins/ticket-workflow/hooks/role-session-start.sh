#!/usr/bin/env bash
# SessionStart — session-id export + charter re-injection.
#
# Two jobs:
#
# 1. Export CLAUDE_SESSION_ID, the fallback key for `/role`'s marker, on CLIs
#    that don't set CLAUDE_CODE_SESSION_ID (Claude Code before 2.1.132). The
#    marker snippets prefer the harness's variable: each session sets its own,
#    while this export is an ordinary variable that a child launched from the
#    Bash tool inherits. So it is written only when the harness's is missing,
#    and the spawn edges strip it for those older CLIs. CLAUDE_ENV_FILE is
#    writable from SessionStart *only*.
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

# 1. Hand this plugin's root, which only a hook knows, to subsequent Bash
#    commands, so /role can locate the charters. Hand them the session id too
#    unless the harness sets CLAUDE_CODE_SESSION_ID (hooks and Bash get the
#    same value), since the snippets would ignore the export then: that is how
#    /role keys its marker on an older CLI. CLAUDE_ENV_FILE expects
#    `export KEY=value` lines.
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

# The role is the first line: a self-pinned implementer's marker records its
# issue on a second line (`issue: <id>`), which must not run into the role.
role=$(head -n 1 "$marker" 2>/dev/null | tr -d '[:space:]') || exit 0

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
