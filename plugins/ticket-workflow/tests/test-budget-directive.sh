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
budget_re='^Budget: wall_clock_min=(0|[1-9][0-9]{0,4}) review_rounds=(0|[1-9][0-9]{0,4})$'
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
for bad in 'Budget: review_rounds=1' 'Budget: wall_clock_min=60' 'Budget: review_rounds=1 wall_clock_min=60' 'Budget: wall_clock_min=-1 review_rounds=1' 'Budget: wall_clock_min=1.5 review_rounds=1' 'Budget: wall_clock_min=60 review_rounds=1 extra' 'Budget: wall_clock_min=08 review_rounds=1' 'Budget: wall_clock_min=abc review_rounds=1' 'Budget: wall_clock_min=123456 review_rounds=1' 'Budget:'; do
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
# BSD/macOS `wc -l` pads its output; GNU's does not. `test -eq` tolerates the
# padding but string interpolation does not, so normalize before building a
# pattern from a count.
line_count() { wc -l <"$1" | tr -d '[:space:]'; }
budget_text=$(cat "$budget_doc" 2>/dev/null || true)
budget_prose=$(flatten "$budget_doc" 2>/dev/null || true)
epic_prose=$(flatten "$epic" 2>/dev/null || true)

# SKILL.md points at the mechanism rather than restating it (and stays under the
# ~500-line rule AGENTS.md sets for it).
assert "SKILL.md START Step 1 points at budget.md" grep -qi 'read `budget.md` now' <<<"$start_text"
assert "SKILL.md START Step 8 points at budget.md" grep -q 'budget.md` carries it' <<<"$start_text"
assert "SKILL.md START Step 9 points at budget.md cleanup" grep -q "budget.md.*cleanup snippet" <<<"$start_text"
assert "SKILL.md opt-outs point at budget.md" grep -q 'as `budget.md` prescribes' <<<"$start_text"
assert "SKILL.md SPAWN Step 2 points at budget.md" grep -q 'read `budget.md`' <<<"$spawn_text"
assert "SKILL.md stays under the 500-line rule" test "$(line_count "$skill")" -lt 500
# No `||` fallback here: one supplying the expected count from SKILL.md itself
# made this pass for any AGENTS.md value.
assert "AGENTS.md records SKILL.md's current size" \
	grep -qF "($(line_count "$skill")" "$repo/AGENTS.md"
assert "SKILL.md unbudgeted watch is marked no-budget-only" grep -q 'no budget in play; see budget.md otherwise' <<<"$start_text"

# The mechanism itself.
assert "budget.md pins the directive grammar" grep -q 'Budget: wall_clock_min=<N> review_rounds=<M>' <<<"$budget_prose"
assert "budget.md forbids leading zeros" grep -q 'no leading zero' <<<"$budget_prose"
assert "budget.md bounds the value width" grep -q 'at most 5 digits' <<<"$budget_prose"
assert "budget.md gives overrides their own looser shape" grep -q 'not the full directive above' <<<"$budget_prose"
assert "budget.md validates the merged result against the full shape" grep -q 'merged result is validated against the full directive grammar' <<<"$budget_prose"
assert "budget.md keys the run on repo and normalized id" grep -q 'canonical repository plus the tracker ID' <<<"$budget_prose"
# The example marker must use the documented run-key form, not a stale one: a
# reader copies the example, not the prose.
assert "budget.md's example marker uses the documented run key" grep -qF 'run: <owner>/<repo>#<id>' "$budget_doc"
refute "budget.md's example marker carries no stale branch-keyed form" grep -qF 'run: <issue id> <branch>' "$budget_doc"
assert "budget.md is read on a surviving marker, not just a directive" grep -q 'or when a budget marker for this run already exists' <<<"$budget_prose"
assert "budget.md explains why the branch is not in the run key" grep -q 'does \*\*not\*\* name the branch' <<<"$budget_prose"
assert "budget.md requires --draft on a clock-stop PR" grep -q 'adding `--draft`' <<<"$budget_prose"
assert "SKILL.md Step 1 checks the marker even when the briefing looks unbudgeted" grep -q 'even when the briefing looks unbudgeted' <<<"$start_text"
assert "SKILL.md prefers the marker clock over the first commit" grep -q 'authoritative. Only with no marker' <<<"$(flatten "$skill")"
assert "phases/epic.md strips every source Budget line" grep -q 'removed and replaced' <<<"$epic_prose"
assert "budget.md fails closed on a malformed line" grep -q 'briefing error' <<<"$budget_prose"
assert "budget.md merges key-wise cap -> shared -> per-issue" grep -q 'cap → shared → per-issue' <<<"$budget_prose"
assert "budget.md validates overrides before launching" grep -q 'before launching anything' <<<"$budget_prose"
assert "budget.md keeps zero lines when the cap omits one" grep -q 'and \*\*none\*\* when a profile' <<<"$budget_prose"
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

# --- 4. the documented usable() predicate, executed ---------------------------
# The prose assertions above only prove the rules are written down. This runs the
# marker validator budget.md actually publishes, against fixtures for both
# shapes, so a predicate that contradicts its own documented marker (an EPIC
# marker has no clock line; requiring one rejected every orchestrator marker)
# fails here rather than in a live run.
usable_src=$(awk '/^usable\(\) \{$/,/^\}$/' "$budget_doc")
assert "budget.md publishes a usable() definition" test -n "$usable_src"

marker_dir=$(mktemp -d)
trap 'rm -rf "$marker_dir"' EXIT
budget_file="$marker_dir/m.budget"
eval "$usable_src"      # the doc's own function, verbatim

# <kind> <run_id> <file contents...> — returns usable()'s verdict for that marker
verdict() {
	kind=$1 run_id=$2; shift 2
	printf '%s\n' "$@" >"$budget_file"
	usable
}
START_RUN='#42 42-fix-flaky-upload'
EPIC_RUN='#89 epic-89'

assert "usable: a well-formed start marker" verdict start "$START_RUN" \
	"kind: start" "run: $START_RUN" "clock: 1789260795" "Budget: wall_clock_min=180 review_rounds=5"
assert "usable: a start marker with spent rounds" verdict start "$START_RUN" \
	"kind: start" "run: $START_RUN" "clock: 1789260795" "Budget: wall_clock_min=180 review_rounds=5" "round: 1" "round: 2"
assert "usable: a well-formed EPIC marker, untimed" verdict epic "$EPIC_RUN" \
	"kind: epic" "run: $EPIC_RUN" "Budget: wall_clock_min=60 review_rounds=3"
refute "usable: a start marker missing its clock" verdict start "$START_RUN" \
	"kind: start" "run: $START_RUN" "Budget: wall_clock_min=180 review_rounds=5"
refute "usable: an EPIC marker carrying a clock" verdict epic "$EPIC_RUN" \
	"kind: epic" "run: $EPIC_RUN" "clock: 1789260795" "Budget: wall_clock_min=60 review_rounds=3"
refute "usable: another run's marker" verdict start "$START_RUN" \
	"kind: start" "run: #99 other-branch" "clock: 1789260795" "Budget: wall_clock_min=180 review_rounds=5"
refute "usable: the wrong kind for this phase" verdict start "$START_RUN" \
	"kind: epic" "run: $START_RUN" "Budget: wall_clock_min=180 review_rounds=5"
refute "usable: a placeholder-bearing Budget line" verdict start "$START_RUN" \
	"kind: start" "run: $START_RUN" "clock: 1789260795" "Budget: wall_clock_min=<N> review_rounds=<M>"
refute "usable: a partial Budget line" verdict epic "$EPIC_RUN" \
	"kind: epic" "run: $EPIC_RUN" "Budget: review_rounds=3"
refute "usable: a leading-zero value" verdict start "$START_RUN" \
	"kind: start" "run: $START_RUN" "clock: 1789260795" "Budget: wall_clock_min=08 review_rounds=5"
refute "usable: a truncated marker" verdict start "$START_RUN" "kind: start" "run: $START_RUN"
refute "usable: a kindless legacy marker" verdict start "$START_RUN" \
	"run: $START_RUN" "clock: 1789260795" "Budget: wall_clock_min=180 review_rounds=5"
rm -f "$budget_file"
refute "usable: no marker at all" verdict start "$START_RUN"
refute "usable: a duplicated Budget line" verdict start "$START_RUN" \
	"kind: start" "run: $START_RUN" "clock: 1789260795" \
	"Budget: wall_clock_min=180 review_rounds=5" "Budget: wall_clock_min=60 review_rounds=1"
refute "usable: a duplicated run line" verdict start "$START_RUN" \
	"kind: start" "run: $START_RUN" "run: $START_RUN" "clock: 1789260795" "Budget: wall_clock_min=180 review_rounds=5"
refute "usable: two clock lines" verdict start "$START_RUN" \
	"kind: start" "run: $START_RUN" "clock: 1789260795" "clock: 1789260800" "Budget: wall_clock_min=180 review_rounds=5"
refute "usable: a malformed round line" verdict start "$START_RUN" \
	"kind: start" "run: $START_RUN" "clock: 1789260795" "Budget: wall_clock_min=180 review_rounds=5" "round: two"
refute "usable: a stray unknown line" verdict start "$START_RUN" \
	"kind: start" "run: $START_RUN" "clock: 1789260795" "Budget: wall_clock_min=180 review_rounds=5" "note: hello"
refute "usable: round lines on an EPIC marker" verdict epic "$EPIC_RUN" \
	"kind: epic" "run: $EPIC_RUN" "Budget: wall_clock_min=60 review_rounds=3" "round: 1"

# --- 5. the stateful paths, executed -------------------------------------------
# Previously verified only by hand in a scratch shell, which CI never re-runs.
state_dir=$(mktemp -d)
CLAUDE_SESSION_ROLES_DIR="$state_dir" CLAUDE_SESSION_ID=sess_t
roles_dir="$state_dir"; budget_file="$roles_dir/sess_t.budget"

# The documented write, as budget.md publishes it: create-only when usable.
write_marker() { # <kind> <run> <clock> <wcm> <rr>
	kind=$1 run_id=$2; local c=$3 w=$4 r=$5
	mkdir -p "$roles_dir"
	if ! usable; then
		printf 'kind: %s\nrun: %s\n' "$kind" "$run_id" >"$budget_file"
		[ "$kind" = start ] && printf 'clock: %s\n' "$c" >>"$budget_file"
		printf 'Budget: wall_clock_min=%s review_rounds=%s\n' "$w" "$r" >>"$budget_file"
	fi
}

write_marker start "$START_RUN" 1000 180 5
printf 'round: 1\n' >>"$budget_file"
write_marker start "$START_RUN" 2000 180 5          # a resume re-enters Step 1
assert "re-entry keeps the original clock" grep -qx 'clock: 1000' "$budget_file"
assert "re-entry keeps the spent rounds" grep -qx 'round: 1' "$budget_file"
write_marker start '#99 other' 3000 60 1            # a different ticket, same session
assert "a foreign run replaces the marker" grep -qx 'run: #99 other' "$budget_file"
refute "a foreign run does not inherit spent rounds" grep -q '^round:' "$budget_file"

# Round accounting is before the push, so an interrupted push cannot under-count.
rounds_used() { grep -c '^round: ' "$budget_file" || true; }
write_marker start "$START_RUN" 1000 180 2
before=$(rounds_used); printf 'round: 1\n' >>"$budget_file"   # record, then push
assert "a round is counted before its push" test "$(rounds_used)" -eq $((before + 1))

# The deadline poll: bounded, errexit-safe, and it breaks on a settled check.
stub_dir="$state_dir/bin"; mkdir -p "$stub_dir"
printf '#!/usr/bin/env bash\nexit 8\n' >"$stub_dir/gh"; chmod +x "$stub_dir/gh"
poll() { # <deadline-seconds-from-now>
	local deadline=$(( $(date +%s) + $1 ))
	until [ "$(date +%s)" -ge "$deadline" ]; do
		poll_status=0; PATH="$stub_dir:$PATH" gh pr checks 1 >/dev/null 2>&1 || poll_status=$?
		[ "$poll_status" -ne 8 ] && break
		sleep 1
	done
}
poll_start=$(date +%s); ( set -e; poll 2 ); poll_rc=$?
assert "the deadline poll survives set -e" test "$poll_rc" -eq 0
assert "the deadline poll stops at its deadline" test $(( $(date +%s) - poll_start )) -lt 8
printf '#!/usr/bin/env bash\nexit 0\n' >"$stub_dir/gh"
poll_start=$(date +%s); poll 30
assert "the deadline poll breaks on a settled check" test $(( $(date +%s) - poll_start )) -lt 5

# Cleanup: recomputed path, guarded session id.
clear_marker() { # <session-id>
	local rd="${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}" sid=$1
	[ -n "$sid" ] && rm -f "$rd/$sid.budget"
}
printf 'x\n' >"$roles_dir/.budget"                  # what an unguarded rm would hit
clear_marker sess_t
refute "cleanup removes this session's marker" test -f "$budget_file"
assert "cleanup leaves a non-session file alone" test -f "$roles_dir/.budget"
clear_marker "" || true   # the guard returns false by design; don't trip set -e
assert "cleanup with an unset session id is a no-op" test -f "$roles_dir/.budget"

# The SessionStart hook refreshes the sidecar past its own 30-day reaper.
hook="$repo/plugins/ticket-workflow/hooks/role-session-start.sh"
printf 'implementer\n' >"$roles_dir/sess_t"
printf 'kind: start\nrun: r\nclock: 1\nBudget: wall_clock_min=1 review_rounds=1\n' >"$budget_file"
touch -d '60 days ago' "$roles_dir/sess_t" "$budget_file" 2>/dev/null || touch -t 202001010000 "$roles_dir/sess_t" "$budget_file"
CLAUDE_SESSION_ROLES_DIR="$roles_dir" CLAUDE_PLUGIN_ROOT="$repo/plugins/ticket-workflow" \
	bash "$hook" <<<'{"session_id":"sess_t","source":"resume"}' >/dev/null 2>&1 || true
assert "the hook refreshes the role marker" test -z "$(find "$roles_dir" -name sess_t -mtime +30)"
assert "the hook refreshes the budget sidecar" test -z "$(find "$roles_dir" -name 'sess_t.budget' -mtime +30)"
rm -rf "$state_dir"


# Forwarding surfaces.
assert "phases/epic.md points at budget.md" grep -q 'Read `budget.md`' <<<"$epic_prose"
assert "phases/epic.md rejects a partial override before spawning" grep -q 'before spawning' <<<"$epic_prose"
assert "phases/epic.md clears the marker via budget.md cleanup" grep -q "budget.md.*cleanup snippet" <<<"$epic_prose"
assert "phases/epic.md keeps at most one Budget line" grep -q 'at most one' <<<"$epic_prose"
assert "/role none guards the session id before removing" grep -q 'CLAUDE_SESSION_ID" \] &&' "$commands/role.md"
assert "/role none clears the budget sidecar" grep -q 'CLAUDE_SESSION_ID.budget' "$commands/role.md"
assert "the SessionStart hook refreshes the budget sidecar" grep -q 'marker.budget' "$repo/plugins/ticket-workflow/hooks/role-session-start.sh"
for cmd in spawn-tickets spawn-epic; do
	assert "/$cmd documents the Budget: override in its argument hint" \
		grep -q 'Budget: wall_clock_min=<N> review_rounds=<M>' "$commands/$cmd.md"
	assert "/$cmd explains where the override is applied" \
		grep -qi 'budget' <<<"$(flatten "$commands/$cmd.md")"
done
assert "AGENTS.md records the zsh 'status' hazard" grep -q "\`status\` is the same trap" "$repo/AGENTS.md"

if [ "$failures" -gt 0 ]; then
	printf '\n%d failure(s)\n' "$failures"
	exit 1
fi
printf '\nall budget-directive checks passed\n'
