#!/usr/bin/env bash
# PreToolUse — role drift guards, keyed on this session's role marker (never
# on what the session says about itself: forgetting the role is exactly the
# drift being guarded).
#
# - planner: file edits and EnterWorktree escalate to a permission prompt
#   ("ask") rather than a hard deny, so an *unattended* planner can't silently
#   drift into implementation, while a human at the wheel approves with one
#   keystroke. Entering a worktree comes before the first edit, so the prompt
#   comes before any file is written. (EnterWorktree by name also creates the
#   worktree. A worktree made with `git worktree add` in Bash, as START makes
#   its own, exists before the prompt.) The prompt's reason is shown only
#   to the human, so each also carries one line of additionalContext, which
#   reaches the model even when the prompt is rejected (checked on Claude Code
#   2.1.293 with a permission-prompt tool that denied; the docs place it beside
#   the tool result when the call runs): a rejected call then tells the model
#   to file and spawn rather than retry. Every other documented worktree,
#   EPIC's and the FINISH intro's temporary checkout (which a planner runs for
#   a stacked or cloud child's PR) included, goes through `git worktree add` in
#   Bash, so the gate doesn't touch it: only START, an implementer's phase,
#   calls EnterWorktree.
#   File edits under a scratch or memory directory are a planner's own work
#   (an issue body for FILE, a memory note), so they get no decision here,
#   and Claude Code's own permission checks still apply to them: the
#   background job's directory ($CLAUDE_JOB_DIR), the system temp directory
#   (/tmp, /private/tmp, $TMPDIR), and the auto-memory directories
#   (<config>/projects/*/memory/). Both the path and the directories are
#   resolved first (symlinks and `..`, for a path that doesn't exist yet too),
#   so a symlinked ~/.claude still matches and /tmp/../<repo>/file doesn't. A
#   TMPDIR or job directory that holds $HOME counts as none. EnterWorktree
#   gets no such exemption, wherever the worktree is.
#
# - implementer: launching a session whose prompt *leads* with an
#   issue-spawning command is denied with a redirect to file + ping instead.
#   It covers a hand-rolled `claude --bg` or `claude -p` (Bash) and a cloud
#   `create_session` call (an MCP tool; PreToolUse receives its arguments as
#   tool_input). The
#   leading-command test is what separates an issue spawn from a helper
#   session, which the implementer charter allows: a helper's prompt leads with
#   its task. role-guard-launch.jq holds the test. Deny, not ask: an
#   implementer usually runs unattended, where a prompt would stall with nobody
#   to answer it; the human override is '/role none'.
#
# - any session, pinned or not: an in-process subagent (or any other agent
#   the harness runs inside this session, a teammate of the user's own agent
#   team included) shares this session, so its calls carry this session's id
#   and its Bash environment holds this session's CLAUDE_CODE_SESSION_ID. A
#   self-pin or /role it ran would rewrite this session's marker: a subagent
#   following a skill's START step would re-pin its parent. Its calls, and
#   only its calls, carry an agent_id (checked on Claude Code 2.1.282). So
#   such a call is denied when it would write the marker: a Bash command
#   that names scripts/role-marker.sh, which makes every marker write the
#   docs describe, followed by any subcommand but `show`, wherever it sits
#   outside quotes and heredocs (role-guard-marker-write.jq), or a file edit
#   in the roles directory. Reads pass (`role-marker.sh show`), so
#   the skill's guards still see the parent's role. Deny, not ask, with no
#   override: the write is never the subagent's to make. A write improvised
#   without the script passes; the docs show none.
#
# The role guards match the charters' stated philosophy: the guard is the
# unattended default, not a lock. The implementer check is a heuristic over the command
# text, not a shell parser. A prompt that opens with prose naming the skill
# file (the cloud slash-command workaround), one assembled at run time or
# read from a file (`< prompt.txt`, `cat prompt.txt |`), or a launch nested in
# another shell's string (`bash -c "..."`) passes it. The phase-entry guard in
# the skill is the primary check; this is the backstop.
#
# Fails open: any missing dependency, unreadable marker, or unparseable payload
# exits 0 (allow). This is a drift nudge, not a security control.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

hook_dir=${BASH_SOURCE[0]%/*}
[ "$hook_dir" != "${BASH_SOURCE[0]}" ] || hook_dir=.

# The roles directory, the session-id check, and the role read, shared with
# role-marker.sh. Fail open (not an unbound-variable abort) when neither the
# override nor HOME is available.
# shellcheck source=../scripts/marker-lib.sh
. "$hook_dir/../scripts/marker-lib.sh" 2>/dev/null || exit 0
marker_roles_dir || exit 0

emit() { # emit <decision> <reason> [<context for the model>]
	jq -n --arg decision "$1" --arg reason "$2" --arg context "${3:-}" '{
  hookSpecificOutput: ({
    hookEventName: "PreToolUse",
    permissionDecision: $decision,
    permissionDecisionReason: $reason
  } + (if $context == "" then {} else {additionalContext: $context} end))
}'
}

# in_roles_dir <dir>: is <dir> the roles directory? -ef compares the directory
# itself, so a `..` or `.` segment, a doubled slash, a symlink, or a case
# variant on a case-insensitive disk can't slip past. A roles directory that
# doesn't exist yet has nothing for -ef to find, so then the normalized paths
# are compared, and the names (ignoring case) with their parents by -ef.
in_roles_dir() {
	[ "$1" -ef "$roles_dir" ] && return 0
	[ -d "$roles_dir" ] && return 1
	norm() { printf '%s' "$1" | sed -e 's://*:/:g' -e 's:/\./:/:g' -e 's:/\.$::' -e 's:/$::' | tr '[:upper:]' '[:lower:]'; }
	local got want
	got=$(norm "$1")
	want=$(norm "$roles_dir")
	[ "$got" = "$want" ] && return 0
	[ "${got##*/}" = "${want##*/}" ] && [ "$(dirname -- "$1")" -ef "$(dirname -- "$roles_dir")" ]
}

# edit_path sets file_path to the path a file edit (Edit, Write, MultiEdit,
# NotebookEdit) names, or to nothing. A bash regex reads it, and jq only a path
# with JSON escapes in it, which the regex can't.
edit_path() {
	local path_re='"(file_path|notebook_path)"[[:space:]]*:[[:space:]]*"([^"\\]*)"'
	file_path=
	if [[ $input =~ $path_re ]]; then
		file_path=${BASH_REMATCH[2]}
	elif [[ $input == *'"file_path"'* || $input == *'"notebook_path"'* ]]; then
		file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
	fi
}

# walk_path <path> [text] sets walked to the absolute <path> with `.`, `..`
# and repeated slashes resolved and, unless `text` is given, each existing
# symlink followed (a dangling one too, since a write creates its target).
# Each `..` drops the last part reached so far, which after a symlink is the
# physical directory, as the OS takes it. A part that doesn't exist is kept as
# written. With `text` nothing is read from disk: that is how a tool that
# normalizes a path before opening it (Node's path.resolve) takes it. Fails on
# a relative path or past 40 symlinks.
walk_path() {
	local todo=$1 out='' part target hops=0
	case $todo in /*) ;; *) return 1 ;; esac
	while [ -n "$todo" ]; do
		part=${todo%%/*}
		if [ "$part" = "$todo" ]; then todo=; else todo=${todo#*/}; fi
		case $part in
		'' | .) continue ;;
		..)
			out=${out%/*}
			continue
			;;
		esac
		if [ $# -eq 1 ] && [ -L "$out/$part" ]; then
			hops=$((hops + 1))
			[ "$hops" -le 40 ] || return 1
			target=$(readlink -- "$out/$part") || return 1
			case $target in /*) out= ;; esac
			todo=$target${todo:+/$todo}
			continue
		fi
		out=$out/$part
	done
	walked=${out:-/}
}

# in_scratch <walked path>: is it strictly inside a scratch or memory
# directory (the header's planner bullet)? Reads scratch_dirs and projects_dir,
# which scratch_path sets.
in_scratch() {
	local dir rest
	for dir in ${scratch_dirs[@]+"${scratch_dirs[@]}"}; do
		[[ $1 == "$dir"/?* ]] && return 0
	done
	[ -n "$projects_dir" ] || return 1
	rest=${1#"$projects_dir"/}
	[ "$rest" != "$1" ] || return 1
	dir=${rest%%/*}
	[[ -n $dir && $rest == "$dir"/memory/?* ]]
}

# scratch_path <path>: may a pinned planner edit <path> without the prompt?
# Both readings of the path must land in a scratch or memory directory: the
# OS's, and that of a tool that normalizes the path before opening it. They
# differ only after a symlink followed by `..`.
scratch_path() {
	local dir home=
	[ -n "${HOME:-}" ] && walk_path "$HOME" && home=$walked
	scratch_dirs=()
	for dir in "${CLAUDE_JOB_DIR:-}" /tmp /private/tmp "${TMPDIR:-}"; do
		[ -n "$dir" ] && walk_path "$dir" || continue
		# A directory that holds $HOME (or /) holds the user's checkouts too, so
		# a TMPDIR set that wide is no scratch directory.
		[[ $walked == / || $home == "$walked" || $home == "$walked"/* ]] && continue
		scratch_dirs+=("$walked")
	done
	projects_dir=
	if [ -n "${CLAUDE_CONFIG_DIR:-}${HOME:-}" ] &&
		walk_path "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" && [ "$walked" != / ]; then
		projects_dir=$walked
	fi
	walk_path "$1" && in_scratch "$walked" || return 1
	walk_path "$1" text && walk_path "$walked" && in_scratch "$walked"
}

# A subagent's marker write (the header's last bullet). This comes before the
# pinned-session check below, because a subagent that pins an unpinned parent
# makes the same mistake. The bash tests keep jq to subagent calls that could
# be one.
agent_re='"agent_id"[[:space:]]*:[[:space:]]*"[^"]'
if [[ $input =~ $agent_re ]]; then
	subagent_write=no
	if [[ $input == *role-marker.sh* ]] &&
		printf '%s' "$input" | jq -e -f "$hook_dir/role-guard-marker-write.jq" >/dev/null 2>&1; then
		subagent_write=yes
	else
		# A file edit in the roles directory.
		edit_path
		if [ -n "$file_path" ] && in_roles_dir "${file_path%/*}"; then
			subagent_write=yes
		fi
	fi
	if [ "$subagent_write" = yes ]; then
		emit deny "This call would write the role marker, and it comes from an in-process subagent or other in-process agent (its hook input carries an agent_id). You run inside your parent's session and share its session id, so the marker is the parent session's, not yours.

Skip the self-pin and the notify record (START Step 1, EPIC Step 1) and /role, and follow the charter your briefing names from context. Reading the marker (role-marker.sh show) is fine. If this command only mentions the script (a commit message, an echo), keep the mention inside quotes or pass the text through a file."
		exit 0
	fi
fi

# The matcher includes Bash, so this runs before every Bash call in every
# session. Find the session id with a bash regex and exit unless it has a
# marker, so an unpinned session never starts jq. jq re-reads the id below.
id_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]+)"'
[[ $input =~ $id_re ]] || exit 0
[ -f "$roles_dir/${BASH_REMATCH[1]}" ] || exit 0

fields=$(printf '%s' "$input" | jq -r '[.session_id // "", .tool_name // ""] | @tsv' 2>/dev/null) || exit 0
session_id=${fields%%$'\t'*}
tool=${fields#*$'\t'}
# Anything but a plain token must not reach the marker path.
marker_id_ok "$session_id" || exit 0

marker="$roles_dir/$session_id"
[ -f "$marker" ] || exit 0

role=$(marker_role "$marker") || exit 0

# Defense in depth: hooks.json already filters on `matcher`, but a future
# matcher change shouldn't silently widen either guard.
context=
case "$role:$tool" in
planner:Edit | planner:Write | planner:MultiEdit | planner:NotebookEdit | planner:EnterWorktree)
	decision=ask
	if [ "$tool" = EnterWorktree ]; then
		what="enter this worktree"
		dont="Planners don't open worktrees or implement"
		scratch=
	else
		edit_path
		if [ -n "$file_path" ] && scratch_path "$file_path"; then
			exit 0
		fi
		what="make this one edit"
		dont="Planners don't implement"
		scratch=" Scratch and memory files don't prompt: the job directory, /tmp, \$TMPDIR, and the auto-memory directories."
	fi
	reason="This session is pinned to the planner charter (/role planner), which owns the whole initiative and delegates the work drawn on it.

$dont: file the work (/make-ticket) and hand it down (/spawn-epic, /spawn-tickets).$scratch

Approve to $what anyway, or run '/role none' to drop the charter for the rest of the session."
	context="Pinned planner: this call asked the owner first. If they approved it, go ahead. If they rejected it, don't retry it or make the change another way: file the work (/make-ticket) and hand it down (/spawn-epic, /spawn-tickets)."
	;;
implementer:Bash | implementer:create_session | implementer:mcp__*__create_session)
	printf '%s' "$input" | jq -e -f "$hook_dir/role-guard-launch.jq" >/dev/null 2>&1 || exit 0
	decision=deny
	reason="This session is pinned to the implementer charter, which owns exactly one issue. Launching a session that leads with /start-ticket, /start-epic, /spawn-tickets, /spawn-epic, or /make-ticket --spawn or --start spawns work for an issue, and that allocation is your coordinator's call, not yours.

Instead: file the work (plain /make-ticket, no --spawn or --start), ping your Notify: spawner 'filed: #<n>, suggest spawning' (or 'blocked: ...' if it blocks your acceptance criteria), or note it on your issue/PR when no Notify: is wired, then return to your own issue.

A helper session for this issue's own work is fine: give it a prompt that leads with the task, not an issue-spawning command. If this command only quotes such a launch (a commit message or PR body), pass that text through a file. A human steering this session can override with '/role none'."
	;;
*) exit 0 ;;
esac

emit "$decision" "$reason" "$context"
