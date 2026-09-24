#!/usr/bin/env bash
# Tests for hooks/role-guard.sh: pipe crafted PreToolUse payloads in, with an
# isolated CLAUDE_SESSION_ROLES_DIR, and check the decision it prints (no
# output = allow). Needs jq, like the hook itself.
#
#   bash plugins/ticket-workflow/tests/test-role-guard.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
guard="$here/../hooks/role-guard.sh"
roles_dir=$(mktemp -d)
trap 'rm -rf "$roles_dir"' EXIT
sid=test-session
pass=0
fail=0

# Prints allow, ask, or deny for a raw payload, with <role> pinned (or none).
decide_raw() {
	rm -f "$roles_dir/$sid"
	[ "$1" = none ] || printf '%s\n' "$1" >"$roles_dir/$sid"
	out=$(printf '%s' "$2" | CLAUDE_SESSION_ROLES_DIR="$roles_dir" bash "$guard")
	if [ -z "$out" ]; then
		echo allow
	else
		printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'
	fi
}

# decide <role> <tool> <input field> <value>
decide() {
	decide_raw "$1" "$(jq -n --arg sid "$sid" --arg tool "$2" --arg field "$3" --arg value "$4" \
		'{session_id: $sid, tool_name: $tool, tool_input: {($field): $value}}')"
}

record() { # record <expected> <label> <got>
	if [ "$3" = "$1" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL: %s: expected %s, got %s\n' "$2" "$1" "$3"
	fi
}

bash_case() { # bash_case <expected> <role> <label> <command>
	record "$1" "$2 Bash: $3" "$(decide "$2" Bash command "$4")"
}

cloud_case() { # cloud_case <expected> <role> <label> <prompt>
	record "$1" "$2 create_session: $3" "$(decide "$2" mcp__Claude_Code_Remote__create_session prompt "$4")"
}

spawn_ticket='( cd "/repo" && claude --bg --name "repo #52: fix x" "/start-ticket 52 Implement and test.  Role: implementer" )'
helper='( cd "/repo" && claude --bg --name "helper: flaky build" "Investigate the flaky build for #147 (it fails under /start-ticket); report findings back only. Notify: repo #147: guard" )'

# Implementer: issue-spawning launches are denied.
bash_case deny implementer "claude --bg leading with /start-ticket" "$spawn_ticket"
bash_case deny implementer "namespaced /ticket-workflow:start-epic" 'claude --bg "/ticket-workflow:start-epic 40"'
bash_case deny implementer "single-quoted /spawn-tickets" "claude --bg --name x '/spawn-tickets 3 5'"
bash_case deny implementer "/spawn-epic" 'claude --bg "/spawn-epic 40 --finish"'
bash_case deny implementer "heredoc prompt in a variable" "$(printf '%s\n' "read -r -d '' p <<'PROMPT'" '/start-epic 40' 'Role: epic-coordinator' 'PROMPT' 'claude --bg --name "repo 40: epic" "$p"')"
bash_case deny implementer "line continuations" "$(printf '%s\n' 'claude \' '  --bg \' '  --name "x" \' '  "/start-ticket 7"')"
bash_case deny implementer "claude by path" '~/.local/bin/claude --bg "/start-ticket 7"'
bash_case deny implementer "prompt assigned to a variable first" 'p="/start-ticket 7"; claude --bg --name x "$p"'

# Implementer: helpers and everything else pass.
bash_case allow implementer "helper whose prompt leads with prose" "$helper"
bash_case allow implementer "plain command" 'git status'
bash_case allow implementer "claude agents" 'claude agents'
bash_case allow implementer "claude -p (not a bg spawn)" 'claude -p "/start-ticket 5"'
bash_case allow implementer "not a whole command word" 'claude --bg "/start-tickets-report 5"'
bash_case allow implementer ".claude path, not the claude CLI" 'ls .claude --bg "/start-ticket 5"'
bash_case allow implementer "mentions only" 'gh pr comment 5 --body "a claude --bg helper that leads with prose passes"'
cloud_case deny implementer "prompt leading with /start-ticket" '/start-ticket 52 Implement and test.  Role: implementer'
cloud_case deny implementer "leading whitespace, namespaced /spawn-epic" '  /ticket-workflow:spawn-epic 40'
cloud_case allow implementer "helper prompt" 'Investigate why the build flakes; report findings back only.'
cloud_case allow implementer "prose-opened skill prompt (documented gap)" 'Run the epic 40. Read SKILL.md and follow the EPIC phase for: 40'
record allow "implementer bare create_session" "$(decide implementer create_session prompt 'Investigate X; report back only.')"
record deny "implementer bare create_session" "$(decide implementer create_session prompt '/start-ticket 9')"
record allow "implementer Edit" "$(decide implementer Edit file_path /repo/x)"

# Other roles, or no marker: the implementer guard doesn't apply.
bash_case allow none "no marker" "$spawn_ticket"
bash_case allow epic-coordinator "coordinator spawns children" "$spawn_ticket"
bash_case allow planner "planner spawns" "$spawn_ticket"
cloud_case allow epic-coordinator "coordinator cloud spawn" '/start-ticket 52'
record ask "planner Edit (existing guard)" "$(decide planner Edit file_path /repo/x)"
record allow "coordinator Edit" "$(decide epic-coordinator Edit file_path /repo/x)"

# Fail open.
record allow "unsafe session id" "$(decide_raw implementer '{"session_id":"../x","tool_name":"Bash","tool_input":{"command":"claude --bg \"/start-ticket 1\""}}')"
record allow "malformed payload" "$(decide_raw implementer 'not json')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
