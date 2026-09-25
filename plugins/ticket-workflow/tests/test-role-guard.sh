#!/usr/bin/env bash
# Tests for hooks/role-guard.sh: pipe crafted PreToolUse payloads in, with an
# isolated CLAUDE_SESSION_ROLES_DIR, and check the decision it prints (no
# output = allow). The last section checks that hooks/role-session-start.sh
# reads the role from the same markers. Needs jq, like the hooks themselves.
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

# The marker is written with this format; '%s' drops the trailing newline.
marker_fmt='%s\n'

# Prints allow, ask, or deny for a raw payload, with <role> pinned (or none).
# <role> is the whole marker content, so it can carry an issue line.
decide_raw() {
	rm -f "$roles_dir/$sid"
	[ "$1" = none ] || printf "$marker_fmt" "$1" >"$roles_dir/$sid"
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
bash_case deny implementer "env prefix and assignment" 'env FOO=1 BAR=2 claude --bg "/start-ticket 7"'
bash_case deny implementer "spawn edge's env -u prefix" 'env -u CLAUDE_SESSION_ID claude --bg --name x "/start-ticket 7"'
bash_case deny implementer "after then" 'if true; then claude --bg "/start-ticket 7"; fi'
bash_case deny implementer "command substitution" 'out=$(claude --bg "/start-ticket 7")'
bash_case deny implementer "backtick substitution" 'x=`claude --bg "/start-ticket 5"`'
bash_case deny implementer "unquoted prompt" 'claude --bg /start-ticket 5'
bash_case deny implementer "prompt after --" 'claude --bg -- /start-ticket 5'
bash_case deny implementer "wrapper command" 'caffeinate -i nice claude --bg "/start-ticket 5"'
bash_case deny implementer "negation" '! claude --bg "/start-ticket 5"'
bash_case deny implementer "separators inside a quoted --name" 'claude --name "fix a|b; c&d" --bg "/start-ticket 5"'
bash_case deny implementer "colon after the command" 'claude --bg "/start-ticket: 5"'
bash_case deny implementer "/make-ticket --start" 'claude --bg "/make-ticket Fix flaky CI --start"'
bash_case deny implementer "/make-ticket --spawn right after the command" 'claude --bg "/make-ticket --spawn Fix flaky CI"'
bash_case deny implementer "prompt from a command-substitution heredoc" "$(printf '%s\n' 'p="$(cat <<'"'"'EOF'"'"'' '/spawn-tickets 3 5' 'EOF' ')"' 'claude --bg "$p"')"
bash_case deny implementer "inline command-substitution heredoc prompt" "$(printf '%s\n' 'claude --bg "$(cat <<'"'"'EOF'"'"'' '/start-ticket 5 Role: implementer' 'EOF' ')"')"
bash_case deny implementer "apostrophe in an earlier comment" "$(printf '%s\n' "# don't do this" "claude --bg '/start-ticket 5'")"
bash_case deny implementer "last assignment wins (spawn)" 'p="Investigate X"; p="/start-ticket 5"; claude --bg "$p"'
bash_case deny implementer "claude through a \$HOME path" '$HOME/.local/bin/claude --bg "/start-ticket 5"'
bash_case deny implementer "quoted \$HOME path" '"$HOME/.local/bin/claude" --bg "/start-ticket 5"'
bash_case deny implementer "claude -p" 'claude -p "/start-ticket 5"'
bash_case deny implementer "backgrounded claude -p" 'nohup claude -p "/start-ticket 5" &'
bash_case deny implementer "prompt after a variadic option and another flag" 'claude --add-dir a b --bg "/start-ticket 5"'
bash_case deny implementer "unquoted command-substitution heredoc" "$(printf '%s\n' "p=\$(cat <<'EOF'" '/spawn-tickets 3 5' 'EOF' ')' 'claude --bg "$p"')"
bash_case deny implementer "prompt from a stdin heredoc" "$(printf '%s\n' "claude -p <<'EOF'" '/start-ticket 5' 'EOF')"
bash_case deny implementer "stdin heredoc with a redirect on its line" "$(printf '%s\n' "claude -p <<'EOF' 2>/dev/null" '/start-ticket 5' 'EOF')"
bash_case deny implementer "prompt from a here-string" 'claude -p <<< "/start-ticket 5"'
bash_case deny implementer "prompt read from a here-string" 'read -r p <<< "/start-ticket 5"; claude --bg "$p"'
bash_case deny implementer "prompt piped from echo" 'echo "/start-ticket 5" | claude -p'
bash_case deny implementer "prompt piped from printf" "printf '%s\\n' '/start-ticket 5' | claude -p --output-format json"
bash_case deny implementer "prompt piped from a heredoc" "$(printf '%s\n' "cat <<'EOF' | claude -p" '/start-ticket 5' 'EOF')"
bash_case deny implementer "redirect before the prompt" 'claude --bg 2>/dev/null "/start-ticket 5"'
bash_case deny implementer "spaced redirects before the prompt" 'claude --bg > /tmp/log 2>&1 "/start-ticket 5"'
bash_case deny implementer "value of an option --help doesn't list" 'claude --bg --max-turns 5 "/start-ticket 5"'
bash_case deny implementer "partly quoted prompt" 'for id in 3 5; do claude --bg "/start-ticket "$id; done'
bash_case deny implementer "variable followed by more text" 'cmd=/spawn-tickets; claude --bg "$cmd 3 5"'
bash_case deny implementer "/make-ticket --spawn with directive lines after it" "$(printf '%s\n' 'claude --bg "/make-ticket Fix flaky CI --spawn' 'Notify: repo x"')"
bash_case deny implementer "stripped-identity launch" 'env -u CLAUDE_SESSION_ID claude --bg --name "x" "/start-ticket 5"'

# Implementer: helpers and everything else pass.
bash_case allow implementer "helper whose prompt leads with prose" "$helper"
bash_case allow implementer "helper through the spawn edge's env -u prefix" 'env -u CLAUDE_SESSION_ID claude --bg --name "helper: flaky build" "Investigate the flaky build; report back only."'
bash_case allow implementer "plain command" 'git status'
bash_case allow implementer "claude agents" 'claude agents'
bash_case allow implementer "claude with neither --bg nor -p" 'claude "/start-ticket 5"'
bash_case allow implementer "not a whole command word" 'claude --bg "/start-tickets-report 5"'
bash_case allow implementer ".claude path, not the claude CLI" 'ls .claude --bg "/start-ticket 5"'
bash_case allow implementer "mentions only" 'gh pr comment 5 --body "a claude --bg helper that leads with prose passes"'
bash_case allow implementer "prose mention beside a quoted command" "gh pr comment 5 --body 'denies a \`claude --bg\` launch like \"/start-ticket 5\"'"
bash_case allow implementer "issue command in an earlier command's message" 'git commit -m "/start-ticket docs"; claude --bg "Investigate X, report back"'
bash_case allow implementer "escaped quotes inside a helper prompt" 'claude --bg "Investigate why \"/start-ticket 5\" fails; report back"'
bash_case allow implementer "helper prompt with a line that starts with a command" "$(printf '%s\n' 'claude --bg "Investigate X.' '/start-ticket 5 fails on Y; report back"')"
bash_case allow implementer "launch quoted in a PR body heredoc" "$(printf '%s\n' 'gh pr create --body-file - <<'"'"'EOF'"'"'' 'claude --bg "/start-ticket 5"' 'EOF')"
bash_case allow implementer "plain /make-ticket (filing only)" 'claude --bg "/make-ticket Fix flaky CI"'
bash_case allow implementer "launch nested in bash -c (documented gap)" 'bash -c "claude --bg /start-ticket 5"'
bash_case allow implementer "--spawn mentioned mid-description" 'claude --bg "/make-ticket Document the --spawn flag behavior"'
bash_case allow implementer "--start only inside another option's value" 'claude --bg "/make-ticket X" --name "a --start b"'
bash_case allow implementer "issue command as a --name value" 'claude --bg --name "/start-ticket helper" "Investigate X"'
bash_case allow implementer "unquoted helper prompt mentioning a command" 'claude --bg Investigate why /start-ticket fails'
bash_case allow implementer "last assignment wins (helper)" 'p="/start-ticket 5"; p="Investigate X"; claude --bg "$p"'
bash_case allow implementer "launch only in a trailing comment" 'echo hi # claude --bg "/start-ticket 5"'
bash_case allow implementer "piped input with a positional helper prompt" 'git log -5 | claude -p "Summarize these commits"'
bash_case allow implementer "helper prompt piped from echo" 'echo "Investigate X" | claude -p'
bash_case allow implementer "helper prompt after an unlisted option's value" 'claude --bg --max-turns 5 "Investigate X"'
bash_case allow implementer "helper prompt with a trailing redirect" 'claude --bg "Investigate X" 2>/dev/null'
bash_case allow implementer "variable assigned only after the launch" 'claude --bg "${cmd} 3 5"; cmd=/spawn-tickets'
bash_case allow implementer "launch written to a file by a heredoc" "$(printf '%s\n' "cat <<'EOF' >notes.md" 'claude -p "/start-ticket 5"' 'EOF')"
bash_case allow implementer "process substitutions" 'diff <(sort a) <(sort b)'
cloud_case deny implementer "prompt leading with /start-ticket" '/start-ticket 52 Implement and test.  Role: implementer'
cloud_case deny implementer "leading whitespace, namespaced /spawn-epic" '  /ticket-workflow:spawn-epic 40'
cloud_case deny implementer "/make-ticket --spawn" '/make-ticket Fix flaky CI --spawn'
cloud_case allow implementer "helper prompt" 'Investigate why the build flakes; report findings back only.'
cloud_case allow implementer "prose-opened skill prompt (documented gap)" 'Run the epic 40. Read SKILL.md and follow the EPIC phase for: 40'
record allow "implementer bare create_session" "$(decide implementer create_session prompt 'Investigate X; report back only.')"
record deny "implementer bare create_session" "$(decide implementer create_session prompt '/start-ticket 9')"
record allow "implementer Edit" "$(decide implementer Edit file_path /repo/x)"

# A self-pinned implementer's marker records its issue on a second line (START
# Step 1). The role is the first line only, so both guards still fire.
two_line_implementer=$'implementer\nissue: 52'
record deny "two-line implementer marker, spawn" "$(decide "$two_line_implementer" Bash command "$spawn_ticket")"
record allow "two-line implementer marker, helper" "$(decide "$two_line_implementer" Bash command "$helper")"
record allow "two-line implementer marker, Edit" "$(decide "$two_line_implementer" Edit file_path /repo/x)"
record ask "two-line planner marker, Edit" "$(decide $'planner\nissue: 52' Edit file_path /repo/x)"
record deny "implementer marker without a trailing newline" "$(marker_fmt='%s' decide implementer Bash command "$spawn_ticket")"

# Other roles, or no marker: the implementer guard doesn't apply.
bash_case allow none "no marker" "$spawn_ticket"
bash_case allow epic-coordinator "coordinator spawns children" "$spawn_ticket"
bash_case allow planner "planner spawns" "$spawn_ticket"
cloud_case allow epic-coordinator "coordinator cloud spawn" '/start-ticket 52'
record ask "planner Edit (existing guard)" "$(decide planner Edit file_path /repo/x)"
record allow "coordinator Edit" "$(decide epic-coordinator Edit file_path /repo/x)"

# The PreToolUse matcher names mcp__.*__create_session, so Claude Code reads it
# as a regex and tests it unanchored: it must be anchored to keep tools that
# merely contain a guarded name out.
matcher=$(jq -r '.hooks.PreToolUse[0].matcher' "$here/../hooks/hooks.json")
matches() { jq -rn --arg m "$matcher" --arg t "$1" 'if ($t | test($m)) then "match" else "no match" end'; }
for tool in Edit Write MultiEdit NotebookEdit Bash create_session mcp__Claude_Code_Remote__create_session; do
	record match "PreToolUse matcher: $tool" "$(matches "$tool")"
done
for tool in TodoWrite BashOutput KillBash mcp__ide__Edit_file mcp__x__create_session_log; do
	record "no match" "PreToolUse matcher: $tool" "$(matches "$tool")"
done

# Fail open.
record allow "unsafe session id" "$(decide_raw implementer '{"session_id":"../x","tool_name":"Bash","tool_input":{"command":"claude --bg \"/start-ticket 1\""}}')"
record allow "malformed payload" "$(decide_raw implementer 'not json')"
out=$(printf '%s' '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"claude --bg /start-ticket 1"}}' |
	CLAUDE_SESSION_ROLES_DIR="$roles_dir/missing" bash "$guard")
record allow "no roles directory" "${out:-allow}"

# role-session-start.sh re-injects the charter the marker's first line names.
session_start="$here/../hooks/role-session-start.sh"

# Prints the role whose charter the hook re-injected on resume, or none.
injects() { # injects <marker content>
	printf '%s' "$1" >"$roles_dir/$sid"
	jq -n --arg sid "$sid" '{session_id: $sid, source: "resume"}' |
		CLAUDE_SESSION_ROLES_DIR="$roles_dir" CLAUDE_PLUGIN_ROOT="$here/.." CLAUDE_ENV_FILE='' bash "$session_start" |
		sed -n 's/^This session is pinned to the \*\*\([a-z-]*\)\*\* role charter.*/\1/p' | grep . || echo none
}

record implementer "session start: one-line marker" "$(injects $'implementer\n')"
record implementer "session start: two-line marker" "$(injects $'implementer\nissue: 52\n')"
record epic-coordinator "session start: two-line coordinator marker" "$(injects $'epic-coordinator\nissue: 40\n')"
record implementer "session start: no trailing newline" "$(injects 'implementer')"
record none "session start: unknown role" "$(injects $'bogus\n')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
