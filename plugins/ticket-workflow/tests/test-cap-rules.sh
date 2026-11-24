#!/usr/bin/env bash
# Tests for the review-round cap's prose rules that several ticket-workflow
# docs carry at once (#359), so a restack or a later edit can't leave one file
# on an old rule. They check the docs' text, not a script: the spawner's
# convergence test is a judgment call made in prose.
#
# - the profile's SPAWN_CAP payload is safe to embed in a double-quoted launch
#   (no backtick, double quote, dollar sign or backslash), ends with its
#   Budget: line, and carries each sentence a child needs to accept what its
#   charter lets it do, the held-findings sentence included;
# - FINISH Step 1's held-findings check is the one definition of what a grant
#   covers at the cap (its floor, home and record), each doc that lands a
#   capped PR or relays a clearance points to it, and none keeps the old stop
#   on any held finding;
# - REVIEW_BOT's *A spawner's call* is the one definition of when a spawner
#   raises, with its convergence test, ceiling, three-way choice and
#   too-fiddly trigger, and the charters, EPIC Step 6 and messaging.md point
#   to it.
#
#   bash plugins/ticket-workflow/tests/test-cap-rules.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
skill="$here/../skills/ticket-workflow"
. "$here/lib.sh"

profile="$skill/profiles/default.md"
finish_md="$skill/phases/finish.md"
epic_md="$skill/phases/epic.md"

# Prints 1 when <file> has a line holding the fixed string <text>, else 0.
has() { # has <file> <text>
	if grep -qF -- "$2" "$1"; then echo 1; else echo 0; fi
}

# Print yes when <string> starts (or ends) with the fixed <text>, else no. A
# case statement inside $(...) is a syntax error in macOS's bash 3.2, so these
# keep it in a function body.
starts_with() { # starts_with <string> <text>
	case "$1" in "$2"*) echo yes ;; *) echo no ;; esac
}
ends_with() { # ends_with <string> <text>
	case "$1" in *"$2") echo yes ;; *) echo no ;; esac
}

# --- SPAWN_CAP's payload ---------------------------------------------------

# The payload is the quoted text of the op's first bullet, from `briefing: "`
# through its trailing Budget: line. Join its wrapped lines first.
payload=$(awk '/^## SPAWN_CAP/ { on = 1; next } on { print } on && /Budget: rounds=[0-9]+"/ { exit }' "$profile" |
	tr '\n' ' ' | sed -E -e 's/ +/ /g' -e 's/^.*briefing: "//' -e 's/(Budget: rounds=[0-9]+)".*$/\1/')
record yes "SPAWN_CAP payload found" "$(starts_with "$payload" 'Implement and test, then stop')"
record "" "SPAWN_CAP payload has no backtick, double quote, dollar sign or backslash" \
	"$(printf '%s' "$payload" | tr -cd '`"$\\')"
record yes "SPAWN_CAP payload ends with its Budget: line" "$(ends_with "$payload" 'Budget: rounds=5')"
for sentence in \
	'So does a finish clearance for your own PR from your Notify spawner' \
	"so does the owner's own approving review of your PR's current head" \
	'A grant you hold also covers findings you held at your review-round cap' \
	'Do not arm a periodic PR check-in' \
	'a cap there above your round count is a raise, whoever wrote it' \
	'Act too on a cap call your spawner sends about your own PR' \
	'Land what the owner asks for on your PR'; do
	record 1 "SPAWN_CAP payload carries: $sentence" \
		"$(printf '%s\n' "$payload" | grep -cF -- "$sentence")"
done
record 1 "SPAWN_CAP's notes explain the held-findings sentence" "$(has "$profile" '- The **held-findings sentence** puts')"
record 1 "SPAWN_CAP's notes explain the cap-call sentence" "$(has "$profile" '- The **cap-call sentence** does')"
record 1 "an override of SPAWN_CAP is told to carry the payload's sentences" \
	"$(has "$profile" "An override of \`SPAWN_CAP\` also carries the payload's sentences")"

# --- FINISH Step 1's held-findings check -------------------------------------

record 1 "FINISH Step 1's heading names the held-findings check" \
	"$(grep -c '^## Step 1 — Pre-merge gate (.* + held findings)$' "$finish_md")"
record 1 "FINISH Step 1 has the held-findings bullet" "$(grep -c '^- \*\*Held findings\.\*\* ' "$finish_md")"
for item in '  1. **The floor.** ' '  2. **A home.** ' '  3. **A record.** '; do
	record 1 "the held-findings check has its item:$item" "$(grep -c "^$(printf '%s' "$item" | sed 's/[.*]/\\&/g')" "$finish_md")"
done
record 1 "a session launched before the check keeps the old rule" \
	"$(has "$finish_md" 'without its held-findings sentence was launched before this check existed')"

# Each place that decides a merge of a capped PR points to the check. Two of
# them are single lines in finish.md, so check those lines themselves.
record 1 "FINISH intro's implementer bullet points to the check" \
	"$(grep '^- an \*\*implementer\*\* runs its own FINISH' "$finish_md" | grep -cF "Step 1's held-findings check")"
record 1 "The owner's approval item 4 points to the check" \
	"$(grep '^4\. \*\*START is complete\.\*\*' "$finish_md" | grep -cF "Step 1's held-findings check")"
record 1 "EPIC Step 7 lands a capped layer under the check" \
	"$(grep '^Only if the request carries a \*\*finish flag\*\*' "$epic_md" | grep -cF "lands under FINISH Step 1's held-findings check")"
for f in roles/implementer.md roles/epic-coordinator.md roles/planner.md messaging.md profiles/default.md SKILL.md; do
	record 1 "$f points to the held-findings check" "$(has "$skill/$f" 'held-findings check')"
done

# No doc keeps the old rule, that a grant stops at any held finding.
old=$(grep -rnoF -e 'not held findings' -e 'covers reviewed work, not' -e 'fails the gate here' \
	-e 'worth another round' "$skill" "$here/../commands")
record "" "no doc keeps the old stop on held findings" "$old"

# --- REVIEW_BOT's *A spawner's call* -----------------------------------------

record 1 "REVIEW_BOT defines A spawner's call" "$(grep -c "^- \*\*A spawner's call: " "$profile")"
for part in '**When.**' '**Sort the held findings.**' '**The convergence test, before each raise.**' \
	'**The ceiling.**' '**Not converging: no raise, and one of three, said on the PR.**' \
	'**Rewrite.**' '**Split.**' '**Stop and re-evaluate.**' '**Telling the child.**' \
	'**Too fiddly, before the cap.**'; do
	record 1 "A spawner's call has its part $part" "$(has "$profile" "$part")"
done
record 1 "Who raises says a spawner needs no word from the owner" \
	"$(has "$profile" 'A spawner needs no word from the owner: it raises')"
record 1 "the profile's authoring note lists A spawner's call with the cap's mechanics" \
	"$(has "$profile" "*Raising the cap* and *A spawner's call* — live in this profile")"
for f in roles/planner.md roles/epic-coordinator.md roles/implementer.md phases/epic.md messaging.md; do
	record 1 "$f points to A spawner's call" "$(has "$skill/$f" "*A spawner's call*")"
done
record 1 "messaging.md defines the cap call: redirect" "$(grep -c '^- \*\*`cap call:`\*\* ' "$skill/messaging.md")"
record 1 "EPIC Step 6's cloud redirects carry the cap call: hint" \
	"$(has "$epic_md" '`cap call: #<issue> → PR #<pr> <comment URL>` hint')"
record 1 "a stop call holds the merge in FINISH Step 1's merge-blocker scan" \
	"$(has "$finish_md" "a spawner's \`Cap call: stop\` comment that no later \`Cap call:\` comment has lifted")"
record 1 "A spawner's call says how a stop is lifted" "$(has "$profile" '**A stop holds the PR until it is lifted.**')"
record 1 "the held-findings check reads the newest disposition comment's lines" \
	"$(has "$finish_md" 'lines of the newest disposition comment (the ones its `<m>` counts)')"
record 1 "EPIC reports a stopped row as terminal" "$(has "$epic_md" 'reported **stuck** with what was tried, **stopped** by your')"

finish
