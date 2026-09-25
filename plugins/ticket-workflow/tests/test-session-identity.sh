#!/usr/bin/env bash
# Tests for how a session finds the identity its role marker is keyed on (the
# skill's Session roles: *Session identity*). They run the real snippets, pulled
# out of the docs, so the docs can't drift from what is tested:
#
# - the START Step 1 self-pin prefers the harness's CLAUDE_CODE_SESSION_ID over
#   the CLAUDE_SESSION_ID this plugin exports, and a child launched through the
#   spawn edge's `env -u CLAUDE_SESSION_ID` can't write its parent's marker;
# - the SessionStart hook exports CLAUDE_SESSION_ID only when the harness
#   doesn't already set CLAUDE_CODE_SESSION_ID to the same id;
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

# Prints the fenced code block of <file> that contains the fixed string <text>.
extract_block() { # extract_block <file> <text>
	awk -v text="$2" '
		/^[ \t]*```/ {
			if (in_block) { if (hit) { printf "%s", buf; exit } in_block = 0; next }
			in_block = 1; buf = ""; hit = 0; next
		}
		in_block { buf = buf $0 "\n"; if (index($0, text)) hit = 1 }
	' "$1"
}

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

record "CLAUDE_TICKET_WORKFLOW_ROOT " "hook skips the export when the harness sets the same id" \
	"$(hook_exports CLAUDE_CODE_SESSION_ID=s1)"
record "CLAUDE_SESSION_ID CLAUDE_TICKET_WORKFLOW_ROOT " "hook exports the id on an older CLI" \
	"$(hook_exports)"
record "CLAUDE_SESSION_ID CLAUDE_TICKET_WORKFLOW_ROOT " "hook exports the id when the harness's differs" \
	"$(hook_exports CLAUDE_CODE_SESSION_ID=other)"

# --- The docs' code blocks -----------------------------------------------

# Scans every fenced code block in the given files and prints one line per
# violation, then `launches=<n>`:
# - a line that launches claude with --bg or -p must strip CLAUDE_SESSION_ID;
# - any other mention of CLAUDE_SESSION_ID or CLAUDE_CODE_SESSION_ID must be the
#   resolve line itself, so the marker is keyed on nothing else;
# - a block that uses $sid must assign it (a Bash call doesn't inherit it).
scan_blocks() { # scan_blocks <file> ...
	awk -v resolve="$resolve" '
		function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
		function end_block(   i, uses, assigns) {
			uses = 0; assigns = 0
			for (i = 1; i <= n; i++) {
				if (index(block[i], "$sid")) uses = 1
				if (trim(block[i]) == resolve) assigns = 1
			}
			if (uses && !assigns) printf "%s:%d: block uses $sid without assigning it\n", FILENAME, start
			in_block = 0
		}
		FNR == 1 { in_block = 0 }
		/^[ \t]*```/ { if (in_block) end_block(); else { in_block = 1; n = 0; start = FNR } next }
		in_block {
			block[++n] = $0
			stripped = index($0, "env -u CLAUDE_SESSION_ID claude")
			if ($0 ~ /claude (--bg|-p)( |$)/) {
				launches++
				if (!stripped) printf "%s:%d: launch without env -u CLAUDE_SESSION_ID\n", FILENAME, FNR
			} else if ($0 ~ /CLAUDE_(CODE_)?SESSION_ID/ && trim($0) != resolve) {
				printf "%s:%d: session id used outside the resolve line\n", FILENAME, FNR
			}
		}
		END { printf "launches=%d\n", launches }
	' "$@"
}

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
