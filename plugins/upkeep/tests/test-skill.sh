#!/usr/bin/env bash
# Tests that the upkeep skill and its scripts agree, and that the scripts only
# read:
#
# - every script SKILL.md runs exists, and every script but lib.sh is run by
#   SKILL.md and listed in the README;
# - every section SKILL.md's candidate table reads is one a script prints;
# - the frontmatter description fits the 1024-character limit;
# - no survey script (nor this repo's .claude/upkeep/checks.sh) holds a gh or
#   git subcommand that writes.
#
#   bash plugins/upkeep/tests/test-skill.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
skill="$plugin/skills/upkeep/SKILL.md"
scripts="$plugin/skills/upkeep/scripts"
readme="$plugin/README.md"
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

# --- scripts named and present ----------------------------------------------
grep -o 'CLAUDE_SKILL_DIR}/scripts/[a-z-]*\.sh' "$skill" | sed 's|.*/||' | sort -u >"$tmp/run"
(cd "$scripts" && ls ./*.sh) | sed 's|^\./||' | grep -v -x lib.sh | sort >"$tmp/have"
record "$(cat "$tmp/have")" "SKILL.md runs exactly the scripts there are" "$(cat "$tmp/run")"
while IFS= read -r s; do
	record yes "README lists $s" "$(grep -q -F "\`$s\`" "$readme" && echo yes || echo no)"
done <"$tmp/have"

# --- sections the table reads ------------------------------------------------
sed -n '/^## 3\. Find the candidates/,/^## 4\./p' "$skill" | awk -F '|' 'NF > 3 { print $3 }' |
	grep -o '`[a-z-]*`' | tr -d '`' | sort -u >"$tmp/read"
cat "$scripts"/*.sh | grep -o 'upkeep_section [a-z-]*\|upkeep_skip [a-z-]*' | awk '{ print $2 }' | sort -u >"$tmp/printed"
record "" "every section the table reads is printed by a script" "$(comm -23 "$tmp/read" "$tmp/printed" | tr '\n' ' ')"
record yes "the table reads some sections" "$([ -s "$tmp/read" ] && echo yes || echo no)"

# --- the description's size -------------------------------------------------
desc=$(awk '/^---$/ { n++; next } n == 1 && /^description: / { sub(/^description: "/, ""); sub(/"$/, ""); print }' "$skill")
record yes "description present" "$([ -n "$desc" ] && echo yes || echo no)"
record yes "description is at most 1024 characters (${#desc})" "$([ "${#desc}" -le 1024 ] && echo yes || echo no)"

# --- read-only ------------------------------------------------------------
writes='gh (issue|pr|label|release|repo|secret|variable|workflow|run) (create|close|edit|comment|merge|reopen|ready|delete|review|lock|transfer|pin|develop|rerun|cancel|enable|disable|set)|gh api [^|]*(-X|--method) |-f [a-z]+=[^ ]* -X|git (commit|push|reset|checkout|switch|stash|tag|rebase|merge|cherry-pick|revert|am|apply|rm|mv|add|clean|restore|gc|prune|fetch|pull|update-ref|branch -[dDmM]|worktree (add|remove|prune|move|lock|unlock)|config [^-])'
for f in "$scripts"/*.sh "$plugin/../../.claude/upkeep/checks.sh"; do
	[ -f "$f" ] || continue
	hits=$(grep -n -E "$writes" "$f" | grep -v -E '^[0-9]+:[[:space:]]*#')
	record "" "$(basename "$f") holds no writing command" "$hits"
done

finish
