#!/usr/bin/env bash
# Budget-directive contract test (software-factory design, item 2e).
#
# The default profile's SPAWN_CAP payload closes with a `Budget:` briefing
# directive that gives a spawned implementer a stop condition; START Step 8
# records an overrun inside the Evidence block's `tests` string. This test
# pins the pieces a spawner and a checker rely on:
#
#   1. the SPAWN_CAP payload carries exactly one Budget line of the documented
#      shape (`Budget: wall_clock_min=<N> review_rounds=<M>`), as its last
#      clause, and stays free of the characters the profile forbids in the
#      payload (backtick, double quote, `$`, backslash);
#   2. the `budget_exceeded` clause START Step 8 appends to `tests` passes the
#      evidence checker's placeholder and shape rules (so an overrun record is
#      never rejected as a placeholder) and is itself parseable for metrics;
#   3. the surfaces that forward or honor the directive name it: START Steps 1
#      and 8, SPAWN Step 2, EPIC Step 5, and the two spawn commands.
#
# Stdlib only: bash, awk, jq. Run from anywhere: bash plugins/ticket-workflow/tests/test-budget-directive.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
skill_dir="$repo/plugins/ticket-workflow/skills/ticket-workflow"
skill="$skill_dir/SKILL.md"
profile="$skill_dir/profiles/default.md"
epic="$skill_dir/phases/epic.md"
commands="$repo/plugins/ticket-workflow/commands"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

failures=0
ok() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$((failures + 1)); }
assert() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
refute() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi; }

# The directive's documented shape: both keys, that order, digits, nothing else.
budget_re='^Budget: wall_clock_min=(0|[1-9][0-9]*) review_rounds=(0|[1-9][0-9]*)$'
# The overrun clause START Step 8 appends inside `tests` — trailing (Step 7
# says so), hence anchored to the end, and at most one per string.
overrun_re='budget_exceeded: (wall_clock_min|review_rounds) [0-9]+ of [0-9]+$'

# --- 1. the SPAWN_CAP payload ------------------------------------------------
# The payload is the text between the pair of double quotes in the first
# bullet of the profile's `## SPAWN_CAP` section (the quotes are the note's
# delimiters, not part of the payload). That bullet must hold exactly those
# two quotes — a third would be a quote *inside* the payload, which the
# extraction below could not tell from the closing delimiter. Lines are
# joined with spaces, as the spawn command's single double-quoted argument
# would carry them.
section_text() { # <file> <heading regex>: the section body up to the next `## `
	awk -v heading="$2" '
		!inside && $0 ~ heading { inside = 1; next }
		inside && /^## / { exit }
		inside { print }
	' "$1"
}
cap_bullet=$(section_text "$profile" '^## SPAWN_CAP[[:space:]]*$' | awk 'NR > 1 && /^- / { exit } { print }')
assert "SPAWN_CAP: the payload bullet holds exactly one pair of delimiting quotes" test "$(grep -o '"' <<<"$cap_bullet" | wc -l)" -eq 2
payload=$(tr '\n' ' ' <<<"$cap_bullet" | sed -E 's/^[^"]*"//; s/".*$//; s/  +/ /g; s/ $//')
assert "SPAWN_CAP: extracted a payload" test -n "$payload"
refute "SPAWN_CAP payload: no backtick, double quote, \$, or backslash" grep -q '[`"$\\]' <<<"$payload"
budget_line=$(grep -Eo 'Budget: [^"]*$' <<<"$payload" || true)
assert "SPAWN_CAP payload: ends with a Budget: directive" test -n "$budget_line"
assert "SPAWN_CAP payload: the Budget line has the documented shape" grep -Eq "$budget_re" <<<"$budget_line"
assert "SPAWN_CAP payload: exactly one Budget: directive" test "$(grep -o 'Budget:' <<<"$payload" | wc -l)" -eq 1
# The shape rule itself: what the spawner's merge must produce, and what it must not.
for good in 'Budget: wall_clock_min=180 review_rounds=5' 'Budget: wall_clock_min=0 review_rounds=0' 'Budget: wall_clock_min=60 review_rounds=1'; do
	assert "shape accepts '$good'" grep -Eq "$budget_re" <<<"$good"
done
for bad in 'Budget: review_rounds=1' 'Budget: wall_clock_min=60' 'Budget: review_rounds=1 wall_clock_min=60' 'Budget: wall_clock_min=-1 review_rounds=1' 'Budget: wall_clock_min=1.5 review_rounds=1' 'Budget: wall_clock_min=60 review_rounds=1 extra' 'Budget: wall_clock_min=08 review_rounds=1' 'Budget: wall_clock_min=abc review_rounds=1' 'Budget:'; do
	refute "shape rejects '$bad'" grep -Eq "$budget_re" <<<"$bad"
done

# --- 2. the overrun record inside the Evidence block --------------------------
# Same predicates the evidence-block test enforces for `tests`/`docs`, applied
# to the strings START Step 8 writes on a budget stop.
placeholder_def='def placeholder: test("^\\s*(TODO|TBD|n/?a)\\s*$"; "i") or test("<[^>]*>");'
no_placeholders="$placeholder_def ([.tests, .docs] | all(placeholder | not))"
strings_nonempty='[.tests, .docs] | all(type == "string" and length > 0)'
wall_clock_digits='.wall_clock_min | test("^[0-9]+$")'
overrun_block=$(jq -n '{
	tests: "bash plugins/ticket-workflow/tests/test-evidence-block.sh (passed); budget_exceeded: review_rounds 2 of 1",
	docs: "no doc impact",
	wall_clock_min: "47"
}')
clock_block=$(jq -n '{
	tests: "none: budget exceeded before Step 6; budget_exceeded: wall_clock_min 181 of 180",
	docs: "not checked: budget exceeded before Step 6",
	wall_clock_min: "181"
}')
for label in overrun_block clock_block; do
	block=${!label}
	assert "$label: overrun clause is not a placeholder" jq -e "$no_placeholders" <<<"$block"
	assert "$label: tests/docs stay non-empty strings" jq -e "$strings_nonempty" <<<"$block"
	assert "$label: wall_clock_min stays a digit string" jq -e "$wall_clock_digits" <<<"$block"
	assert "$label: the clause is parseable for metrics" grep -Eq "$overrun_re" <<<"$(jq -r .tests <<<"$block")"
	assert "$label: exactly one overrun clause" test "$(grep -o 'budget_exceeded:' <<<"$(jq -r .tests <<<"$block")" | wc -l)" -eq 1
done
refute "an overrun clause that is not trailing is rejected" grep -Eq "$overrun_re" <<<'x (passed); budget_exceeded: review_rounds 2 of 1 stale'
refute "two overrun clauses are rejected" test "$(grep -o 'budget_exceeded:' <<<'budget_exceeded: review_rounds 2 of 1; budget_exceeded: review_rounds 2 of 1' | wc -l)" -eq 1
assert "a budget-free tests string carries no overrun clause" test -z "$(grep -Eo "$overrun_re" <<<'bash tests/x.sh (passed)' || true)"
refute "an overrun clause without counts is rejected" grep -Eq "$overrun_re" <<<'budget_exceeded: review_rounds'
refute "an overrun clause naming an unknown budget is rejected" grep -Eq "$overrun_re" <<<'budget_exceeded: tokens 2 of 1'

# --- 3. the surfaces that forward or honor the directive -----------------------
start_text=$(sed -n '/^## START phase/,/^## FINISH phase/p' "$skill")
spawn_text=$(sed -n '/^## SPAWN phase/,/^## EPIC phase/p' "$skill")
assert "SKILL.md START Step 1 notes the Budget: directive" grep -q 'Note your budget' <<<"$start_text"
assert "SKILL.md START Step 8 carries the budget check" grep -q 'Budget check' <<<"$start_text"
assert "SKILL.md START Step 1 persists the budget beside the role marker" grep -q 'CLAUDE_SESSION_ID.budget' <<<"$start_text"
assert "SKILL.md START Step 8 records a no-PR stop on the ticket" grep -q 'durably on the ticket itself' <<<"$start_text"
assert "SKILL.md SPAWN Step 2 rejects a partial override over a cap with no budget" grep -q 'no.*`Budget:` line.*partial' <<<"$spawn_text"
assert "SKILL.md SPAWN Step 2 merges key-wise cap -> shared -> per-issue" grep -q 'cap → shared → per-issue' <<<"$spawn_text"
assert "SKILL.md SPAWN Step 2 validates overrides before launching" grep -q 'Validate before launching' <<<"$spawn_text"
assert "SKILL.md START Step 1 rejects a malformed Budget: line" grep -q 'briefing error' <<<"$start_text"
assert "SKILL.md START Step 8 uses a portable deadline poll, not timeout" grep -q 'deadline poll' <<<"$start_text"
refute "SKILL.md START Step 8 no longer relies on GNU timeout" grep -q 'timeout "\$((' <<<"$start_text"
assert "SKILL.md START Step 8 records the no-PR stop through the tracker COMMENT op" grep -q 'COMMENT(id, body)' <<<"$start_text"
assert "SKILL.md START recovery never infers a budget from the role marker" grep -q 'never infer one from the role marker' <<<"$start_text"
assert "SKILL.md START Step 1 writes the budget marker create-only" grep -q 'create-only on purpose' <<<"$start_text"
assert "SKILL.md START Step 8 captures the poll status errexit-safely" grep -q 'status=\$?' <<<"$start_text"
refute "SKILL.md START Step 8 does not test a bare \$? after the poll" grep -q 'gh pr checks <pr> >/dev/null 2>&1; \[ \$? ' <<<"$start_text"
assert "SKILL.md START Step 9 clears the budget marker" grep -q 'Clear the budget marker' <<<"$start_text"
assert "SKILL.md opt-outs name the no-PR recording path" grep -q 'no PR exists, recorded on the ticket' <<<"$start_text"
assert "profile qualifies the Evidence promise with the no-PR path" grep -q "no-PR path" "$profile"
assert "the SessionStart hook refreshes the budget sidecar" grep -q 'marker.budget' "$repo/plugins/ticket-workflow/hooks/role-session-start.sh"
assert "/role none clears the budget sidecar" grep -q 'CLAUDE_SESSION_ID.budget' "$commands/role.md"
assert "phases/epic.md Step 1 guards the session id before writing" grep -q 'CLAUDE_SESSION_ID" \] && mkdir -p' "$epic"
for tracker in github jira; do
	assert "trackers/$tracker.md defines COMMENT(id, body)" grep -q '^## COMMENT(id, body)' "$skill_dir/trackers/$tracker.md"
done
assert "phases/epic.md Step 1 persists the children's budget override" grep -q 'CLAUDE_SESSION_ID.budget' "$epic"
assert "SKILL.md START Step 7 documents the budget_exceeded clause" grep -q 'budget_exceeded' <<<"$start_text"
assert "SKILL.md START opt-outs list the budget stop" grep -q 'Budget exhausted' <<<"$start_text"
assert "SKILL.md SPAWN Step 2 merges a Budget: override" grep -q 'Budget:.*overrides' <<<"$spawn_text"
assert "phases/epic.md Step 5 replaces the cap Budget: line with the effective one" grep -q "\`Budget:\` line \*\*replaced\*\* by the effective one" "$epic"
assert "spawn-tickets accepts a Budget: override" grep -q 'Budget: wall_clock_min=<N> review_rounds=<M>' "$commands/spawn-tickets.md"
assert "spawn-epic accepts a Budget: override" grep -q 'Budget: wall_clock_min=<N> review_rounds=<M>' "$commands/spawn-epic.md"
# The profile's own prose documents the shape a spawner must reproduce.
assert "profile documents the directive shape" grep -q 'Budget: wall_clock_min=<N> review_rounds=<M>' "$profile"

if [ "$failures" -gt 0 ]; then
	printf '\n%d failure(s)\n' "$failures"
	exit 1
fi
printf '\nall budget-directive checks passed\n'
