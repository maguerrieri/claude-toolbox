#!/usr/bin/env bash
# Tests for how a session finds the identity its role marker is keyed on (the
# skill's Session roles: *Session identity*). They run the real snippets, pulled
# out of the docs, so the docs can't drift from what is tested:
#
# - the START Step 1 self-pin prefers the harness's CLAUDE_CODE_SESSION_ID over
#   the CLAUDE_SESSION_ID this plugin exports, and a child launched through the
#   spawn edge's `env -u CLAUDE_SESSION_ID` can't write its parent's marker;
# - every local launch line strips CLAUDE_SESSION_ID;
# - no snippet keys the marker on anything but the resolved id;
# - the SessionStart matcher covers every source Claude Code reports.
#
#   bash plugins/ticket-workflow/tests/test-session-identity.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin="$here/.."
skill="$plugin/skills/ticket-workflow"
spawn_local="$plugin/../spawn/skills/spawn/backends/local.md"
roles_dir=$(mktemp -d)
trap 'rm -rf "$roles_dir"' EXIT
pass=0
fail=0

record() { # record <expected> <label> <got>
	if [ "$3" = "$1" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL: %s: expected %s, got %s\n' "$2" "$1" "$3"
	fi
}

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

# A current CLI sets CLAUDE_CODE_SESSION_ID per session, so a child pins its
# own marker even when it inherited the parent's CLAUDE_SESSION_ID unstripped.
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

# Every local launch line strips the spawner's CLAUDE_SESSION_ID. Each file must
# have at least one launch line, so a moved snippet can't pass vacuously.
for f in "$skill/SKILL.md" "$skill/phases/epic.md" "$plugin/commands/spawn-epic.md" "$spawn_local"; do
	label=${f#"$plugin/"}
	launches=$(grep -c 'claude --bg --name' "$f")
	stripped=$(grep -c 'env -u CLAUDE_SESSION_ID claude --bg --name' "$f")
	record yes "$label has a local launch line" "$([ "$launches" -gt 0 ] && echo yes || echo no)"
	record "$launches" "$label launch lines that strip CLAUDE_SESSION_ID" "$stripped"
done

# Every marker path is built from the resolved id, and every file that builds
# one resolves it the same way.
resolve='sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"'
for f in "$skill/SKILL.md" "$skill/phases/epic.md" "$plugin/commands/spawn-epic.md" "$plugin/commands/role.md"; do
	label=${f#"$plugin/"}
	record 0 "$label marker paths keyed on a raw variable" \
		"$(grep -c 'roles_dir/\$CLAUDE_\|roles_dir/\${CLAUDE_' "$f")"
	if grep -q 'roles_dir/\$sid' "$f"; then
		record yes "$label resolves sid" "$(grep -qF "$resolve" "$f" && echo yes || echo no)"
	fi
done

# The SessionStart matcher covers every source Claude Code reports.
matcher=$(jq -r '.hooks.SessionStart[0].matcher' "$plugin/hooks/hooks.json")
for source in startup resume clear compact fork; do
	record yes "SessionStart matcher covers $source" \
		"$(printf '%s' "$source" | grep -qxE "$matcher" && echo yes || echo no)"
done

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
