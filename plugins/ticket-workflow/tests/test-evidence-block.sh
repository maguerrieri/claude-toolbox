#!/usr/bin/env bash
# Evidence-block contract test (software-factory design, item 1a).
#
# The START Step 7 PR template in SKILL.md carries a `## Evidence` section with
# one fenced JSON block. This test pins the contract from the checker's side:
#
#   1. the spec's 1a example round-trips through jq and satisfies every
#      structural rule the checker (item 1b) will enforce;
#   2. the SKILL.md template is itself strict JSON with the required keys, the
#      fixed defaults (`schema`, `role`, `critic`), and `<…>` placeholders in
#      every field a session must fill — so an unfilled template is rejected by
#      the placeholder rule rather than passing as a record;
#   3. filling the template's placeholders yields a record that passes the
#      full rule set, and a body with two blocks fails the one-block rule.
#
# Stdlib only: bash, awk, jq. Run from anywhere: bash plugins/ticket-workflow/tests/test-evidence-block.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
skill="$repo/plugins/ticket-workflow/skills/ticket-workflow/SKILL.md"
spec="$repo/docs/superpowers/specs/2026-09-11-software-factory-design.md"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

failures=0
ok() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$((failures + 1)); }
# assert <description> <command...>: pass when the command exits 0
assert() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
# refute <description> <command...>: pass when the command exits non-zero
refute() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi; }

# Print the first ```json fenced block that follows a line matching <anchor>.
# <anchor> is a dynamic ERE handed over with `awk -v`, which processes backslash
# escapes before the regex is compiled — so anchors escape metacharacters with
# bracket expressions (`[*]`, `[.]`), never backslashes.
# Only a fence that closes counts: an unterminated ```json fence yields nothing.
extract_json_after() { # <file> <anchor regex>
	awk -v anchor="$2" '
		!found && $0 ~ anchor { found = 1; next }
		found && !infence && /^```json[[:space:]]*$/ { infence = 1; next }
		infence && /^```[[:space:]]*$/ { printf "%s", buf; exit }
		infence { buf = buf $0 "\n" }
	' "$1"
}

# --- the contract, as jq predicates -----------------------------------------
# Every filter reads the block on stdin and exits 0 (jq -e) when the rule holds.
REQUIRED='["schema","tests","docs","context_reads","session","role","wall_clock_min"]'
is_object='type == "object"'
has_required="($REQUIRED - keys) == []"
schema_exact='.schema == "ticket-workflow/evidence/1"'
scalars_quoted='to_entries | map(select(.key != "context_reads")) | all(.value | type == "string")'
reads_nonempty='(.context_reads | type == "array") and (.context_reads | length > 0) and (.context_reads | all(type == "string" and length > 0))'
# Repo-relative: no leading `/`, no `.`/`..` segment — the checker resolves each
# entry against the PR head tree, so anything else can only be invented or outside.
reads_relative='.context_reads | all(test("^/") | not) and all(test("(^|/)[.][.]?(/|$)") | not)'
strings_nonempty='[.tests, .docs] | all(length > 0)'
role_known='.role | IN("planner", "epic-coordinator", "implementer")'
critic_known='(has("critic") | not) or (.critic | IN("ran", "not run"))'
# Placeholder set from 1a: TODO, TBD, <…>, n/a without a reason.
placeholder_def='def placeholder: test("^\\s*(TODO|TBD|n/?a)\\s*$"; "i") or test("<[^>]*>");'
no_placeholders="$placeholder_def ([.tests, .docs] + .context_reads | all(placeholder | not))"
session_shape='.session | test("^(cse_[A-Za-z0-9]+|session_[A-Za-z0-9]+|local)$")'
wall_clock_digits='.wall_clock_min | test("^[0-9]+$")'

check() { # <json> <filter>
	# `jq -e` reports the *last* value of a stream, so a fence holding two
	# objects would otherwise pass on its second one; require exactly one first.
	printf '%s' "$1" | jq -es 'length == 1' >/dev/null && printf '%s' "$1" | jq -e "$2"
}

# The one-block rule, read from a PR body the way a Markdown renderer would: a
# `## Evidence` heading and, under it, exactly one closed ```json fence. Fenced
# regions are tracked throughout, so a `## Evidence` line or a ```json snippet
# quoted inside some other fence (a test-plan example, say) never counts.
# MODE=headings prints the heading count, MODE=fences the count of closed json
# fences under the heading, MODE=extract the body of the first such fence.
evidence_parser='
	function ticks(s) { match(s, /^`+/); return RLENGTH }
	!infence && /^```/ {
		infence = 1; width = ticks($0)
		info = substr($0, width + 1); sub(/[[:space:]]+$/, "", info)
		json = (inside && info == "json"); buf = ""
		next
	}
	infence && /^`+[[:space:]]*$/ && ticks($0) >= width {
		infence = 0
		if (json) { fences++; if (MODE == "extract" && !done) { printf "%s", buf; done = 1 } }
		json = 0; next
	}
	infence { if (json) buf = buf $0 "\n"; next }
	/^## Evidence[[:space:]]*$/ { headings++; inside = 1; next }
	/^## / { inside = 0 }
	END { if (MODE == "headings") print headings + 0; else if (MODE == "fences") print fences + 0 }
'
count_evidence_headings() { awk -v MODE=headings "$evidence_parser" "$1"; }
count_evidence_fences() { awk -v MODE=fences "$evidence_parser" "$1"; }
extract_evidence_block() { awk -v MODE=extract "$evidence_parser" "$1"; }

# The PR body START Step 7's template renders: the heredoc between `cat <<'EOF'`
# and `EOF` in the `gh pr create` example — judged exactly as a real body is.
extract_template_body() { # <SKILL.md>
	awk '
		/^### Step 7 / { step7 = 1 }
		step7 && !inbody && /cat <<'"'"'EOF'"'"'/ { inbody = 1; next }
		inbody && /^EOF$/ { exit }
		inbody { print }
	' "$1"
}

# Membership in the git tree at HEAD — the contract's "exists in the PR's head
# tree" — not the working tree, which also holds untracked and ignored files.
# HEAD must be the PR head, not a merge preview: the ticket-workflow CI workflow
# checks out `pull_request.head.sha` explicitly for that reason.
in_head_tree() { git -C "$repo" cat-file -e "HEAD:$1" 2>/dev/null; }

# Rules every *filled* block must satisfy (session shape is checked separately:
# the spec's example elides its session id with `…`).
structural=("$is_object" "$has_required" "$schema_exact" "$scalars_quoted" "$reads_nonempty" "$role_known" "$critic_known")
filled=("${structural[@]}" "$reads_relative" "$strings_nonempty" "$no_placeholders" "$wall_clock_digits")

run_rules() { # <label> <json> <rule>...
	local label=$1 json=$2; shift 2
	for rule in "$@"; do
		assert "$label: $rule" check "$json" "$rule"
	done
}

# --- 1. the spec's 1a example -----------------------------------------------
spec_block=$(extract_json_after "$spec" '^[*][*]1a[.] Evidence block')
assert "spec 1a example: extracted a block" test -n "$spec_block"
assert "spec 1a example: round-trips through jq" check "$spec_block" '.'
run_rules "spec 1a example" "$spec_block" "${filled[@]}"
# The example's context_reads name real files in this repo (the head-tree rule).
while IFS= read -r read_path; do
	assert "spec 1a example: context_reads path is in the head tree: $read_path" in_head_tree "$read_path"
done < <(printf '%s' "$spec_block" | jq -r '.context_reads[]')

# --- 2. the SKILL.md template ----------------------------------------------
assert "SKILL.md: the literal '## Evidence' line appears exactly once" test "$(grep -c '^## Evidence[[:space:]]*$' "$skill")" -eq 1
template_body=$(mktemp)
trap 'rm -f "$template_body"' EXIT
extract_template_body "$skill" >"$template_body"
assert "template body: extracted from the Step 7 heredoc" test -s "$template_body"
assert "template body: exactly one '## Evidence' heading" test "$(count_evidence_headings "$template_body")" -eq 1
assert "template body: exactly one closed json fence under it" test "$(count_evidence_fences "$template_body")" -eq 1
template=$(extract_evidence_block "$template_body")
assert "template: extracted a block" test -n "$template"
assert "template: is strict JSON" check "$template" '.'
run_rules "template" "$template" "${structural[@]}"
assert "template: role defaults to implementer" check "$template" '.role == "implementer"'
assert "template: critic defaults to \"not run\"" check "$template" '.critic == "not run"'
for key in tests docs session wall_clock_min; do
	assert "template: $key is a <…> placeholder" check "$template" ".$key | test(\"<[^>]*>\")"
done
assert "template: context_reads entries are placeholders" check "$template" '.context_reads | all(test("<[^>]*>"))'
refute "template: an unfilled template fails the placeholder rule" check "$template" "$no_placeholders"
refute "template: an unfilled wall_clock_min fails the digits rule" check "$template" "$wall_clock_digits"

# --- 3. filling the template ------------------------------------------------
filled_block=$(printf '%s' "$template" | jq '
	.tests = "bash plugins/ticket-workflow/tests/test-evidence-block.sh (passed)"
	| .docs = "no doc impact"
	| .context_reads = ["AGENTS.md", "plugins/ticket-workflow/skills/ticket-workflow/profiles/default.md"]
	| .session = "session_01ABCDEF"
	| .wall_clock_min = "23"')
run_rules "filled template" "$filled_block" "${filled[@]}" "$session_shape"
while IFS= read -r read_path; do
	assert "filled template: context_reads path is in the head tree: $read_path" in_head_tree "$read_path"
done < <(printf '%s' "$filled_block" | jq -r '.context_reads[]')
for bad in '/etc/passwd' '../AGENTS.md' 'plugins/../AGENTS.md' './AGENTS.md' 'docs/..'; do
	refute "context_reads rejects non-relative path '$bad'" check "$(printf '%s' "$filled_block" | jq --arg r "$bad" '.context_reads = [$r]')" "$reads_relative"
done
refute "a path outside the head tree is rejected" in_head_tree ".git/HEAD"
refute "an invented path is rejected" in_head_tree "plugins/ticket-workflow/tests/no-such-file.md"
assert "context_reads accepts a dotfile path" check "$(printf '%s' "$filled_block" | jq '.context_reads = [".github/workflows/plugin-versions.yml"]')" "$reads_relative"
for key in tests docs; do
	refute "empty $key is rejected" check "$(printf '%s' "$filled_block" | jq ".$key = \"\"")" "$strings_nonempty"
done
for session in cse_01ABC session_01ABC local; do
	assert "session shape accepts $session" check "$(printf '%s' "$filled_block" | jq --arg s "$session" '.session = $s')" "$session_shape"
done
for session in 'cse_01…' '' 'a1b2c3d4-e5f6-7890-abcd-ef1234567890' 'session_'; do
	refute "session shape rejects '$session'" check "$(printf '%s' "$filled_block" | jq --arg s "$session" '.session = $s')" "$session_shape"
done
for wc in 23 0; do
	assert "wall_clock_min accepts \"$wc\"" check "$(printf '%s' "$filled_block" | jq --arg w "$wc" '.wall_clock_min = $w')" "$wall_clock_digits"
done
for wc in -1 1.5 +3 ''; do
	refute "wall_clock_min rejects \"$wc\"" check "$(printf '%s' "$filled_block" | jq --arg w "$wc" '.wall_clock_min = $w')" "$wall_clock_digits"
done
refute "unquoted wall_clock_min fails the quoted-scalars rule" check "$(printf '%s' "$filled_block" | jq '.wall_clock_min = 23')" "$scalars_quoted"
refute "schema other than ticket-workflow/evidence/1 is rejected" check "$(printf '%s' "$filled_block" | jq '.schema = "ticket-workflow/evidence/2"')" "$schema_exact"
refute "empty context_reads is rejected" check "$(printf '%s' "$filled_block" | jq '.context_reads = []')" "$reads_nonempty"
for bad in TODO tbd 'n/a' 'N/A' '<fill me>'; do
	refute "placeholder tests value '$bad' is rejected" check "$(printf '%s' "$filled_block" | jq --arg t "$bad" '.tests = $t')" "$no_placeholders"
done
assert "'n/a' with a reason is accepted" check "$(printf '%s' "$filled_block" | jq '.tests = "n/a: docs-only change, no test surface"')" "$no_placeholders"
refute "a fence holding two JSON objects is rejected" check "$(printf '%s\n%s' "$filled_block" "$filled_block")" '.'
refute "an invalid first object followed by a valid one is rejected" check "$(printf '{"schema": 1,\n%s' "$filled_block")" '.'
refute "a valid first object followed by an invalid one is rejected" check "$(printf '%s\n{"schema":' "$filled_block")" '.'
refute "critic outside {ran, not run} is rejected" check "$(printf '%s' "$filled_block" | jq '.critic = "clean"')" "$critic_known"

# A PR body assembled from the template carries exactly one block; zero or two fail.
tmp=$(mktemp)
trap 'rm -f "$tmp" "$template_body"' EXIT
printf '## Summary\n- x\n\nCloses #1\n' >"$tmp"
refute "a body with no '## Evidence' heading fails the one-block rule" test "$(count_evidence_headings "$tmp")" -eq 1
refute "a body with no '## Evidence' heading has no fence to count" test "$(count_evidence_fences "$tmp")" -eq 1
refute "a body with no '## Evidence' heading yields no block" test -n "$(extract_evidence_block "$tmp")"
printf '## Summary\n- x\n\n## Evidence\nno fence here\n\nCloses #1\n' >"$tmp"
refute "a heading with no json fence fails the one-block rule" test "$(count_evidence_fences "$tmp")" -eq 1
printf '## Summary\n- x\n\n## Evidence\n```json\n%s\n' "$filled_block" >"$tmp"
refute "an unterminated json fence fails the one-block rule" test "$(count_evidence_fences "$tmp")" -eq 1
refute "an unterminated json fence yields no block" test -n "$(extract_evidence_block "$tmp")"
{
	printf '## Summary\n- x\n\n## Evidence\n```json\n%s\n```\n\nCloses #1\n' "$filled_block"
} >"$tmp"
assert "assembled PR body: one '## Evidence' heading" test "$(count_evidence_headings "$tmp")" -eq 1
assert "assembled PR body: one json fence under it" test "$(count_evidence_fences "$tmp")" -eq 1
assert "assembled PR body: block extracts and parses" check "$(extract_evidence_block "$tmp")" "$has_required"
decoy=$(printf '%s' "$filled_block" | jq '.session = "session_DECOY"')
{
	# A 4-backtick outer fence: in CommonMark a bare ``` would close a 3-backtick one.
	printf '## Summary\n- x\n\n## Test plan\nExample body:\n````text\n## Evidence\n```json\n%s\n```\n````\n\nCloses #1\n' "$decoy"
} >"$tmp.decoy"
refute "a '## Evidence' heading quoted inside another fence does not count" test "$(count_evidence_headings "$tmp.decoy")" -eq 1
refute "a json fence quoted inside another fence does not count" test "$(count_evidence_fences "$tmp.decoy")" -eq 1
refute "a quoted decoy yields no block" test -n "$(extract_evidence_block "$tmp.decoy")"
printf '\n## Evidence\n```json\n%s\n```\n' "$filled_block" >>"$tmp.decoy"
assert "decoy followed by the real section: one heading" test "$(count_evidence_headings "$tmp.decoy")" -eq 1
assert "decoy followed by the real section: one fence" test "$(count_evidence_fences "$tmp.decoy")" -eq 1
assert "decoy followed by the real section: the real block is extracted" check "$(extract_evidence_block "$tmp.decoy")" '.session == "session_01ABCDEF"'
{
	printf '## Summary\n- x\n\n## Evidence\n````md\n```json\n%s\n```\n````\n\nCloses #1\n' "$decoy"
} >"$tmp.decoy"
refute "a json fence nested inside a longer fence under the heading does not count" test "$(count_evidence_fences "$tmp.decoy")" -eq 1
rm -f "$tmp.decoy"
cp "$tmp" "$tmp.two-fences"
printf '\n```json\n%s\n```\n' "$filled_block" >>"$tmp.two-fences"
assert "two fences under one heading: still one heading" test "$(count_evidence_headings "$tmp.two-fences")" -eq 1
refute "two fences under one heading fail the one-block rule" test "$(count_evidence_fences "$tmp.two-fences")" -eq 1
rm -f "$tmp.two-fences"
printf '\n## Evidence\n```json\n%s\n```\n' "$filled_block" >>"$tmp"
refute "two '## Evidence' headings fail the one-block rule" test "$(count_evidence_headings "$tmp")" -eq 1

if [ "$failures" -gt 0 ]; then
	printf '\n%d failure(s)\n' "$failures"
	exit 1
fi
printf '\nall evidence-block checks passed\n'
