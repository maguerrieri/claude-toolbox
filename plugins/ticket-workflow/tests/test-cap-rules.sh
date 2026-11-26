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
	'Findings you held at your review-round cap block your merge until each' \
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
for item in '  1. **Who is cleared to decide.** ' '  2. **What a decision is.** ' '  3. **The floor.** '; do
	record 1 "the held-findings check has its item:$item" "$(grep -c "^$(printf '%s' "$item" | sed 's/[.*]/\\&/g')" "$finish_md")"
done
record 1 "held findings block the merge until each is decided" \
	"$(has "$finish_md" '**Held findings block the merge until each one is decided** by someone cleared to decide it')"
for shape in '— not changing — declined by <who>: <why>' '— not changing — on #<follow-up>, by <who>: <why>'; do
	record 1 "a decision is recorded in the shape: $shape" "$(has "$finish_md" "$shape")"
done
record 1 "a clearance means its sender has decided, so an undecided one is blocked:" \
	"$(has "$finish_md" 'replies `blocked: <header> — held finding undecided: <anchor>` and')"
record 1 "the owner's approval doesn't clear its session to decide" \
	"$(grep '^4\. \*\*START is complete\.\*\*' "$finish_md" | grep -cF "The approval doesn't clear this session to decide one")"
record 1 "notifier.md leaves an approval open on item 4's held-findings comment" \
	"$(has "$skill/notifier.md" "except that section's item 4 comment for held findings still undecided")"
record 1 "EPIC Step 7 decides held findings rather than halting on item 4's comment" \
	"$(grep '^Only if the request carries a \*\*finish flag\*\*' "$epic_md" | grep -cF "unless it is *The owner's approval*'s item 4 comment")"
record 1 "a Cap call: comment counts only from the tree's login" \
	"$(has "$profile" 'Every `Cap call:` comment, a stop and a lift alike, counts only from the login the spawn tree')"
record 1 "a child launched before the check settles the same way" \
	"$(has "$finish_md" 'A child launched before this check behaves the same way, since a decided line no longer reads as held')"

# Each place that decides a merge of a capped PR points to the check. Two of
# them are single lines in finish.md, so check those lines themselves.
record 1 "FINISH intro's implementer bullet points to the check" \
	"$(grep '^- an \*\*implementer\*\* runs its own FINISH' "$finish_md" | grep -cF "Step 1's held-findings check")"
record 1 "The owner's approval item 4 points to the check" \
	"$(grep '^4\. \*\*START is complete\.\*\*' "$finish_md" | grep -cF "Step 1's held-findings check")"
record 1 "EPIC Step 7 lands a capped layer under the check" \
	"$(grep '^Only if the request carries a \*\*finish flag\*\*' "$epic_md" | grep -cF "lands only once each is decided")"
for f in roles/implementer.md roles/epic-coordinator.md roles/planner.md messaging.md profiles/default.md SKILL.md; do
	record 1 "$f points to the held-findings check" "$(has "$skill/$f" 'held-findings check')"
done

# No doc keeps the old rule, that a grant stops at any held finding, nor the
# first fix's, that the merging session judges them at merge and files every
# one on a follow-up (#360, replaced at the owner's request).
old=$(grep -rnoF -e 'not held findings' -e 'covers reviewed work, not' -e 'fails the gate here' \
	-e 'worth another round' -e 'Held findings →' -e 'Merging with findings held' \
	-e 'also covers findings you held' -e 'on a follow-up issue first' "$skill" "$here/../commands")
record "" "no doc keeps an old rule on held findings" "$old"

# --- REVIEW_BOT's *A spawner's call* -----------------------------------------

record 1 "REVIEW_BOT defines A spawner's call" "$(grep -c "^- \*\*A spawner's call: " "$profile")"
for part in '**When.**' '**Decide the held findings.**' '**The convergence test, before each raise.**' \
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
record 1 "At the cap carries every unfixed held finding forward" \
	"$(has "$profile" '  - the same comment **carries forward** every finding an earlier disposition comment held')"
record 1 "the held-findings check reads the newest disposition comment's lines" \
	"$(has "$finish_md" 'lines of the newest disposition comment (the ones its `<m>` counts)')"
record 1 "EPIC reports a stopped row as terminal" "$(has "$epic_md" 'reported **stuck** with what was tried, **stopped** by your')"

finish
