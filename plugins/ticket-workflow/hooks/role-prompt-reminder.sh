#!/usr/bin/env bash
# UserPromptSubmit — a one-line charter reminder for a pinned planner or
# epic-coordinator, attached to every prompt.
#
# The charter enters context at SessionStart and when /role reads it, which
# can be several turns before the decision it governs. When a prompt arrives,
# a skill's own procedure can take over: a freshly pinned planner asked to
# "add that to AGENTS.md" ran conventions:repo-instructions, entered a
# worktree and wrote the file, and only the edit gate's prompt stopped it.
# This puts the tier's actor test next to the prompt instead: a request names
# an outcome, and at these tiers the actor for an outcome is a filed issue plus
# a spawn, unless the owner names the session itself or runs the command for
# it there.
#
# An implementer gets nothing: its tier is the one that implements. Every
# prompt pays for these tokens, so each reminder stays one short line, printed
# as plain stdout, which Claude Code adds to the prompt's context.
#
# Fails open: no marker, an unreadable marker, or an unsafe or missing session
# id prints nothing and exits 0. It must never block a prompt.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

input=$(cat)

hook_dir=${BASH_SOURCE[0]%/*}
[ "$hook_dir" != "${BASH_SOURCE[0]}" ] || hook_dir=.

# shellcheck source=../scripts/marker-lib.sh
. "$hook_dir/../scripts/marker-lib.sh" 2>/dev/null || exit 0
marker_roles_dir || exit 0

# This runs before every prompt in every session, so it starts no jq. A bash
# regex reads the session id. Its first match is the real field: this input
# has no nested objects, and a JSON string can't hold the unescaped quotes the
# pattern needs, so the prompt text can't supply a match.
id_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]+)"'
[[ $input =~ $id_re ]] || exit 0
session_id=${BASH_REMATCH[1]}
# Anything but a plain token must not reach the marker path.
marker_id_ok "$session_id" || exit 0

marker="$roles_dir/$session_id"
[ -f "$marker" ] || exit 0

role=$(marker_role "$marker") || exit 0

# Each tier's delegation, as its charter's actor test words it.
case "$role" in
planner) delegate="file it (/make-ticket) and hand it down (/spawn-epic, /spawn-tickets)" ;;
epic-coordinator) delegate="re-brief the child that owns it (message its running session, resume a stopped one), or file it (/make-ticket) and hand it down (/spawn-tickets)" ;;
*) exit 0 ;;
esac
printf '%s\n' "Pinned role: $role. A request to fix, add, change or build something names an outcome, not an actor: $delegate. Do it yourself only when the owner names you (\"do it here\", \"fix it yourself\") or runs the command for it here themself (/start-ticket)."
