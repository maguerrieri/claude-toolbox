#!/usr/bin/env bash
# Tests for how a session finds the identity its role marker is keyed on (the
# skill's Session roles: *Session identity*). They run the real snippets, pulled
# out of the docs, so the docs can't drift from what is tested:
#
# - the START Step 1 self-pin prefers the harness's CLAUDE_CODE_SESSION_ID over
#   the CLAUDE_SESSION_ID this plugin exports, and a child launched through the
#   spawn edge's `env -u CLAUDE_SESSION_ID` can't write its parent's marker;
# - the SessionStart hook exports CLAUDE_SESSION_ID only when the harness
#   doesn't set CLAUDE_CODE_SESSION_ID;
# - in every code block of the ticket-workflow and spawn docs, each claude
#   launch strips CLAUDE_SESSION_ID, and the marker is keyed only on the
#   resolved id;
# - the SessionStart matcher covers every documented source.
#
#   bash plugins/ticket-workflow/tests/test-session-identity.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
spawn_plugin=$(cd "$plugin/../spawn" && pwd)
skill="$plugin/skills/ticket-workflow"
roles_dir=$(mktemp -d)
trap 'rm -rf "$roles_dir"' EXIT
. "$here/lib.sh"

resolve='sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"'

# --- The self-pin, run as a child session --------------------------------

# START Step 1's self-pin, as an implementer recording issue 52.
self_pin=$(extract_block "$skill/SKILL.md" "grep -qxF 'issue: <id>'" |
	sed -e "s/<role>/implementer/g" -e "s/<id>/52/g")
record yes "self-pin snippet found in SKILL.md" "$([ -n "$self_pin" ] && echo yes || echo no)"

# Runs the self-pin as a child whose environment holds only the given
# variables, with the parent's marker (named `parent`) pinned as planner, then
# prints each marker as <name>=<content>, newlines as |. Arguments after the
# assignments are a launch prefix the child runs under, as env(1) takes them.
pin_as_child() { # pin_as_child [VAR=value ...] [prefix command ...]
	rm -f "$roles_dir"/*
	printf 'planner\n' >"$roles_dir/parent"
	env -i PATH="$PATH" CLAUDE_SESSION_ROLES_DIR="$roles_dir" "$@" bash -c "$self_pin"
	for f in "$roles_dir"/*; do
		[ -f "$f" ] && printf '%s=%s ' "$(basename "$f")" "$(tr '\n' '|' <"$f")"
	done
}

# A current CLI sets CLAUDE_CODE_SESSION_ID per session (overriding an inherited
# one), so a child pins its own marker even with the parent's export inherited.
record "child=implementer|issue: 52| parent=planner| " "native id wins over an inherited export" \
	"$(pin_as_child CLAUDE_CODE_SESSION_ID=child CLAUDE_SESSION_ID=parent)"

# The bug the spawn edge closes: an older CLI (no native id) whose hook didn't
# run, with the parent's export inherited, overwrites the parent's marker.
record "parent=implementer|issue: 52| " "unstripped inherited export overwrites the parent" \
	"$(pin_as_child CLAUDE_SESSION_ID=parent)"

# The same child launched through the spawn edge's prefix: it has no id at all,
# so it skips the pin and the parent's marker survives.
record "parent=planner| " "child launched through env -u CLAUDE_SESSION_ID can't write the parent's marker" \
	"$(pin_as_child CLAUDE_SESSION_ID=parent env -u CLAUDE_SESSION_ID)"

# An older CLI whose own hook ran: its export is its own id.
record "child=implementer|issue: 52| parent=planner| " "hook-exported id on an older CLI" \
	"$(pin_as_child CLAUDE_SESSION_ID=child)"

# No id at all: nothing is written.
record "parent=planner| " "no session id skips the write" "$(pin_as_child)"

# --- The SessionStart hook's export --------------------------------------

# Prints the variable names the hook appends to CLAUDE_ENV_FILE for session s1.
hook_exports() { # hook_exports [VAR=value ...]
	env_file="$roles_dir/env-file"
	: >"$env_file"
	jq -n '{session_id: "s1", source: "startup"}' |
		env -i PATH="$PATH" CLAUDE_SESSION_ROLES_DIR="$roles_dir" CLAUDE_ENV_FILE="$env_file" \
			CLAUDE_PLUGIN_ROOT="$plugin" "$@" bash "$plugin/hooks/role-session-start.sh" >/dev/null
	sed -n 's/^export \([A-Z_]*\)=.*/\1/p' "$env_file" | tr '\n' ' '
}

record "CLAUDE_TICKET_WORKFLOW_ROOT " "hook skips the export when the harness sets the id" \
	"$(hook_exports CLAUDE_CODE_SESSION_ID=s1)"
record "CLAUDE_SESSION_ID CLAUDE_TICKET_WORKFLOW_ROOT " "hook exports the id on an older CLI" \
	"$(hook_exports)"

# --- The docs' code blocks -----------------------------------------------

# Scans every fenced code block in the given files and prints one line per
# violation, then `launches=<n>`:
# - each command (split on ; && || | ( ) and backticks, with line continuations
#   joined) that runs claude with --bg, --background, -p or --print is a
#   launch, and must strip CLAUDE_SESSION_ID;
# - any other mention of CLAUDE_SESSION_ID or CLAUDE_CODE_SESSION_ID must be the
#   resolve line itself, so the marker is keyed on nothing else;
# - a block that uses $sid must assign it (a Bash call doesn't inherit it);
# - a block must be closed.
scan_blocks() { # scan_blocks <file> ...
	awk -v resolve="$resolve" '
		function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
		function end_block(   i, uses, assigns) {
			uses = 0; assigns = 0
			for (i = 1; i <= n; i++) {
				if (index(block[i], "$sid")) uses = 1
				if (trim(block[i]) == resolve) assigns = 1
			}
			if (uses && !assigns) printf "%s:%d: block uses $sid without assigning it\n", file, start
			in_block = 0
		}
		function check_line(text, at,   segs, k, i, cmd, rest) {
			k = split(text, segs, /;|&&|\|\||\||\(|\)|`/)
			for (i = 1; i <= k; i++) {
				cmd = " " segs[i] " "
				if (cmd !~ /[ \t\/]claude[ \t]/ || cmd !~ /[ \t](--bg|--background|-p|--print)[ \t]/) continue
				launches++
				if (cmd !~ /env -u CLAUDE_SESSION_ID[ \t]+[^ \t]*claude[ \t]/)
					printf "%s:%d: launch without env -u CLAUDE_SESSION_ID\n", file, at
			}
			rest = text
			gsub(/env -u CLAUDE_SESSION_ID/, "", rest)
			if (rest ~ /CLAUDE_(CODE_)?SESSION_ID/ && trim(text) != resolve)
				printf "%s:%d: session id used outside the resolve line\n", file, at
		}
		FNR == 1 && in_block { printf "%s:%d: unterminated code block\n", file, start; end_block() }
		/^[ \t]*```/ {
			if (in_block) end_block()
			else { in_block = 1; n = 0; start = FNR; file = FILENAME; pending = "" }
			next
		}
		in_block {
			block[++n] = $0
			if (pending == "") pending_at = FNR
			if ($0 ~ /\\$/) { pending = pending substr($0, 1, length($0) - 1) " "; next }
			check_line(pending $0, pending_at)
			pending = ""
		}
		END {
			if (in_block) { printf "%s:%d: unterminated code block\n", file, start; end_block() }
			printf "launches=%d\n", launches
		}
	' "$@"
}

# The scanner itself, on fixtures: each prints the number of violations.
fixture="$roles_dir/fixture.md"
scan_fixture() { # scan_fixture <block text>
	printf '```bash\n%s\n```\n' "$1" >"$fixture"
	scan_blocks "$fixture" | grep -vc '^launches='
}
record 0 "scan: a stripped launch passes" "$(scan_fixture 'env -u CLAUDE_SESSION_ID claude --bg "a"')"
record 1 "scan: an unstripped launch" "$(scan_fixture 'claude --bg "a"')"
record 1 "scan: --bg after other flags" "$(scan_fixture 'claude --name "x" --bg "$p"')"
record 1 "scan: a launch split across lines" "$(scan_fixture "$(printf 'claude \\\n  --bg "$p"')")"
record 1 "scan: a second launch on a stripped line" \
	"$(scan_fixture 'env -u CLAUDE_SESSION_ID claude --bg "a"; claude -p "b"')"
record 0 "scan: mkdir -p and .claude paths are not launches" "$(scan_fixture 'mkdir -p "$HOME/.claude/x" --bg')"
record 1 "scan: a raw session-id marker path" "$(scan_fixture 'cat "$roles_dir/$CLAUDE_SESSION_ID"')"
record 1 "scan: \$sid used without assigning it" "$(scan_fixture 'cat "$roles_dir/$sid"')"
printf '```bash\n%s\n' "$resolve" >"$fixture"
record 1 "scan: an unterminated block" "$(scan_blocks "$fixture" | grep -vc '^launches=')"

docs=()
while IFS= read -r f; do docs+=("$f"); done < <(find "$plugin" "$spawn_plugin" -name '*.md' | sort)
scan=$(scan_blocks "${docs[@]}")
record "" "doc code-block violations" "$(printf '%s\n' "$scan" | grep -v '^launches=')"
launches=$(printf '%s\n' "$scan" | sed -n 's/^launches=//p')
record yes "doc code blocks hold the local launches (found $launches)" "$([ "$launches" -ge 5 ] && echo yes || echo no)"

# Each known launch site still has its launch in a code block, so moving one
# into prose can't pass the scan vacuously.
for f in "$skill/SKILL.md" "$skill/phases/epic.md" "$plugin/commands/spawn-epic.md" "$spawn_plugin/skills/spawn/backends/local.md"; do
	record yes "${f#"$plugin/../"} has a launch in a code block" \
		"$([ "$(scan_blocks "$f" | sed -n 's/^launches=//p')" -gt 0 ] && echo yes || echo no)"
done

# --- The SessionStart matcher ----------------------------------------------

# The sources Claude Code documents as of 2.1.282. A new one needs adding here
# and to hooks.json by hand: this can't discover it.
matcher=$(jq -r '.hooks.SessionStart[0].matcher' "$plugin/hooks/hooks.json")
for source in startup resume clear compact fork; do
	record yes "SessionStart matcher covers documented source $source" \
		"$(printf '%s' "$source" | grep -qxE "$matcher" && echo yes || echo no)"
done

finish
