#!/usr/bin/env bash
# PreToolUse — role drift guards, keyed on this session's role marker (never
# on what the session says about itself: forgetting the role is exactly the
# drift being guarded).
#
# - planner: file edits escalate to a permission prompt ("ask") rather than a
#   hard deny, so an *unattended* planner can't silently drift into
#   implementation, while a human at the wheel approves with one keystroke.
#
# - implementer: launching a session whose prompt *leads* with an
#   issue-spawning command (/start-ticket, /start-epic, /spawn-tickets,
#   /spawn-epic, or their /ticket-workflow: forms) is denied with a redirect to
#   file + ping instead. It covers a hand-rolled `claude --bg` (Bash) and a
#   cloud `create_session` call (an MCP tool; PreToolUse receives its arguments
#   as tool_input). The leading-command test is what separates an issue spawn
#   from a helper session, which the implementer charter allows: a helper's
#   prompt leads with prose. Deny, not ask: an implementer usually runs
#   unattended, where a prompt would stall with nobody to answer it; the human
#   override is '/role none'.
#
# Both match the charters' stated philosophy: the guard is the unattended
# default, not a lock. The implementer check is a heuristic over the command
# text, not a shell parser; a prompt that opens with prose naming the skill
# file (the cloud slash-command workaround) or that is assembled at run time
# passes it, and a command that merely quotes such a launch in a heredoc can
# trip it (the deny reason says to pass that text through a file). The
# phase-entry guard in the skill is the primary check; this is the backstop.
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
case "$role" in
planner | implementer) ;;
*) exit 0 ;;
esac

# Defense in depth: hooks.json already filters on `matcher`, but a future
# matcher change shouldn't silently widen either guard.
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

# An issue-spawning command, as a whole word (so /start-tickets or
# /start-ticket-x don't count).
spawn_cmd='/(?:ticket-workflow:)?(?:start-ticket|start-epic|spawn-tickets|spawn-epic)(?![\w:-])'

implementer_reason="This session is pinned to the implementer charter (Role: implementer), which owns exactly one issue. Launching a session that leads with /start-ticket, /start-epic, /spawn-tickets, or /spawn-epic spawns work for an issue, and that allocation is your coordinator's call, not yours.

Instead: file the work (plain /make-ticket, no --spawn or --start), ping your Notify: spawner 'filed: #<n>, suggest spawning' (or 'blocked: ...' if it blocks your acceptance criteria), or note it on your issue/PR when no Notify: is wired, then return to your own issue.

A helper session for this issue's own work is fine: give it a prompt that leads with the task, not an issue-spawning command. If this command only quotes such a launch (a commit message or PR body), pass that text through a file instead. A human steering this session can override with '/role none'."

case "$role:$tool" in
planner:Edit | planner:Write | planner:MultiEdit | planner:NotebookEdit)
	decision=ask
	reason="This session is pinned to the planner charter (/role planner), which owns the whole initiative and delegates the work drawn on it.

Planners don't implement: file the work (/make-ticket) and hand it down (/spawn-epic, /spawn-tickets).

Approve to make this one edit anyway, or run '/role none' to drop the charter for the rest of the session."
	;;
implementer:Bash)
	# `claude` (or a path to it) in command position, so a prose mention
	# inside a quoted message doesn't count, with --bg later in the same
	# simple command, line continuations allowed ...
	launch_re='(?:\A|[;&|({\n])[ \t]*(?:(?:then|do|else|if|exec|nohup|command|time|env)[ \t]+|[A-Za-z_][A-Za-z0-9_]*=[^ \t\n]*[ \t]+)*(?:[^ \t\n;&|(){}]*/)?claude(?:[ \t]|\\\n)(?:[^\n;&|\\]|\\[\s\S])*?(?<=[ \t\n])--bg(?![\w-])'
	# ... and an issue-spawning command opening a prompt: right after a quote
	# (an inline argument or a variable assignment) or at a line start (a
	# heredoc body).
	lead_re=$'(?:\\A|["\'\n])[ \t]*'"$spawn_cmd"
	printf '%s' "$input" | jq -e --arg launch "$launch_re" --arg lead "$lead_re" \
		'(.tool_input.command // "") | test($launch) and test($lead)' >/dev/null 2>&1 || exit 0
	decision=deny
	reason=$implementer_reason
	;;
implementer:create_session | implementer:mcp__*__create_session)
	printf '%s' "$input" | jq -e --arg lead '\A\s*'"$spawn_cmd" \
		'(.tool_input.prompt // "") | test($lead)' >/dev/null 2>&1 || exit 0
	decision=deny
	reason=$implementer_reason
	;;
*) exit 0 ;;
esac

jq -n --arg decision "$decision" --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: $decision,
    permissionDecisionReason: $reason
  }
}'
