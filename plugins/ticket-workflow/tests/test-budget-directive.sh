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
# Anchored at the clause boundary as well as the end: `notbudget_exceeded: ...`
# must not satisfy the documented trailing `; budget_exceeded: ...` form.
overrun_re='(^|; )budget_exceeded: (wall_clock_min|review_rounds) [0-9]+ of [0-9]+$'

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
# Identical to the checker's own predicate (tests/test-evidence-block.sh): `n/a`
# literally, so a bare `na` is accepted there and must be accepted here too.
placeholder_def='def placeholder: test("^\\s*(TODO|TBD|n/a)\\s*$"; "i") or test("<[^>]*>");'
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
budget_doc="$skill_dir/budget.md"
assert "budget.md exists" test -f "$budget_doc"
# Prose greps run against a whitespace-collapsed copy: these files are hard-
# wrapped, so a phrase can straddle a line break and a raw grep would report a
# rule missing that is merely reflowed. Code-shaped greps stay line-oriented.
flatten() { tr '\n' ' ' <"$1" | tr -s ' '; }
budget_text=$(cat "$budget_doc" 2>/dev/null || true)
budget_prose=$(flatten "$budget_doc" 2>/dev/null || true)
epic_prose=$(flatten "$epic" 2>/dev/null || true)

# SKILL.md points at the mechanism rather than restating it (and stays under the
# ~500-line rule AGENTS.md sets for it).
assert "SKILL.md START Step 1 points at budget.md" grep -q 'read `budget.md` now' <<<"$start_text"
assert "SKILL.md START Step 8 points at budget.md" grep -q 'budget.md` carries it' <<<"$start_text"
assert "SKILL.md START Step 9 points at budget.md cleanup" grep -q "budget.md.*cleanup snippet" <<<"$start_text"
assert "SKILL.md opt-outs point at budget.md" grep -q 'as `budget.md` prescribes' <<<"$start_text"
assert "SKILL.md SPAWN Step 2 points at budget.md" grep -q 'read `budget.md`' <<<"$spawn_text"
assert "SKILL.md stays under the 500-line rule" test "$(wc -l <"$skill")" -lt 500
assert "AGENTS.md records SKILL.md's current size" grep -q "$(wc -l <"$skill") *$" <<<"$(grep -o '([0-9]* *$' "$repo/AGENTS.md" || echo "$(wc -l <"$skill") ")"
assert "SKILL.md unbudgeted watch is marked no-budget-only" grep -q 'no budget in play; see budget.md otherwise' <<<"$start_text"

# The mechanism itself.
assert "budget.md pins the directive grammar" grep -q 'Budget: wall_clock_min=<N> review_rounds=<M>' <<<"$budget_prose"
assert "budget.md forbids leading zeros" grep -q 'no leading zero' <<<"$budget_prose"
assert "budget.md fails closed on a malformed line" grep -q 'briefing error' <<<"$budget_prose"
assert "budget.md merges key-wise cap -> shared -> per-issue" grep -q 'cap → shared → per-issue' <<<"$budget_prose"
assert "budget.md validates overrides before launching" grep -q 'before launching anything' <<<"$budget_prose"
assert "budget.md keeps zero lines when the cap omits one" grep -q 'and \*\*none\*\* when a profile' <<<"$budget_prose"
assert "budget.md keys the marker to a run identity" grep -q 'run: <issue id> <branch>' <<<"$budget_text"
assert "budget.md captures the clock at the Step 1 note" grep -q 'same moment' <<<"$budget_prose"
assert "budget.md stores validated numbers, not placeholders" grep -q 'validated numbers\*\*, never the `<N>`/`<M>` placeholders' <<<"$budget_prose"
assert "budget.md replaces an invalid or foreign marker" grep -q 'is replaced instead' <<<"$budget_prose"
assert "budget.md keeps a valid same-run marker authoritative" grep -q 'valid marker for this run is authoritative' <<<"$budget_prose"
assert "budget.md counts the round before the push" grep -q 'before each fix push, never after' <<<"$budget_prose"
assert "budget.md never infers a budget from the role marker" grep -q 'Never infer one from the role marker' <<<"$budget_prose"
assert "budget.md uses a portable deadline poll" grep -q 'deadline=' <<<"$budget_text"
refute "budget.md does not rely on GNU timeout" grep -q 'timeout "\$((' <<<"$budget_text"
assert "budget.md avoids the zsh-reserved status name" grep -q 'poll_status' <<<"$budget_text"
refute "budget.md never assigns zsh's read-only status" grep -qE '(^|[^_])status=[^$]' <<<"$budget_text"
assert "budget.md replaces every --watch while budgeted" grep -q 'replaces \*every\* `--watch`' <<<"$budget_prose"
assert "budget.md records a no-PR stop via the tracker COMMENT op" grep -q 'COMMENT(id, body)' <<<"$budget_prose"
assert "budget.md clears the marker on every hand-back" grep -q 'every\*\* hand-back' <<<"$budget_prose"
assert "budget.md recomputes the path and guards the session id in cleanup" grep -q 'CLAUDE_SESSION_ID" \] && rm -f' <<<"$budget_text"

# Forwarding surfaces.
assert "phases/epic.md points at budget.md" grep -q 'Read `budget.md`' <<<"$epic_prose"
assert "phases/epic.md rejects a partial override before spawning" grep -q 'before spawning' <<<"$epic_prose"
assert "phases/epic.md clears the marker via budget.md cleanup" grep -q "budget.md.*cleanup snippet" <<<"$epic_prose"
assert "phases/epic.md keeps at most one Budget line" grep -q 'at most one' <<<"$epic_prose"
assert "/role none guards the session id before removing" grep -q 'CLAUDE_SESSION_ID" \] &&' "$commands/role.md"
assert "/role none clears the budget sidecar" grep -q 'CLAUDE_SESSION_ID.budget' "$commands/role.md"
assert "the SessionStart hook refreshes the budget sidecar" grep -q 'marker.budget' "$repo/plugins/ticket-workflow/hooks/role-session-start.sh"
assert "AGENTS.md records the zsh 'status' hazard" grep -q "\`status\` is the same trap" "$repo/AGENTS.md"

if [ "$failures" -gt 0 ]; then
	printf '\n%d failure(s)\n' "$failures"
	exit 1
fi
printf '\nall budget-directive checks passed\n'
