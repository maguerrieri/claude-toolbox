#!/usr/bin/env bash
# Tests for the fallback review-round count in the default profile's
# REVIEW_BOT (*Count the rounds*). The PR body's Review rounds: line is the
# count; this recount runs only when that line is missing, and counts every
# head the engaged bot reviewed. The tests run the documented snippet, pulled
# out of the profile, against a gh stub that serves fixture reviews, so the
# docs can't drift from what is tested:
#
# - every head the engaged bot reviewed is one round, a push that landed only
#   owner requests included (the recount errs high);
# - a re-review of the same head, an unable-to-review body from Copilot
#   (legacy or v2), and a review by any other login (the implementer's own
#   thread replies post as reviews) are not rounds;
# - the bot login matches with or without REST's [bot] suffix, and the unable
#   filter applies only when the engaged bot is Copilot.
#
# Runs the snippet under bash, and under zsh too when it's installed (the
# Bash tool runs zsh). Needs jq.
#
#   bash plugins/ticket-workflow/tests/test-round-count.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
profile="$plugin/skills/ticket-workflow/profiles/default.md"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

snippet=$(extract_block "$profile" '| unique | length')
record yes "count snippet found in the profile" "$([ -n "$snippet" ] && echo yes || echo no)"

# The stub answers the snippet's one read, the reviews, from a fixture file in
# slurp shape.
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
case "$2" in
*/pulls/35/reviews*) cat "$STUB_DIR/reviews.json" ;;
*) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$tmp/bin/gh"
export STUB_DIR="$tmp"

sha() { printf '%040x' "$1"; } # a deterministic full-length head sha

# Fixture builders: each call appends one review, stamped one second after the
# one before it; reset starts over.
reset() { reviews='[]' clock=0; }
review() { # review <head n> [body] [login]; a body of - is null
	clock=$((clock + 1))
	reviews=$(jq -c --arg s "$(sha "$1")" --arg b "${2:-### 🟡 Changes recommended}" \
		--arg l "${3:-copilot-pull-request-reviewer[bot]}" \
		--arg t "$(printf '2026-10-29T10:%02d:%02dZ' $((clock / 60)) $((clock % 60)))" \
		'. + [{user: {login: $l}, commit_id: $s, body: (if $b == "-" then null else $b end), submitted_at: $t}]' <<<"$reviews")
}

# Writes the fixture as one page of reviews (or two with PAGES=2), runs the
# snippet for <bot login>, and prints the count.
count() { # count <shell> [bot login]
	if [ "${PAGES:-1}" = 2 ]; then
		printf '%s' "$reviews" | jq -c '[.[:(length / 2 | floor)], .[(length / 2 | floor):]]' >"$tmp/reviews.json"
	else
		printf '%s' "$reviews" | jq -c '[.]' >"$tmp/reviews.json"
	fi
	local s
	s=$(printf '%s' "$snippet" | sed -e 's/<pr>/35/g' -e "s/<bot login>/${2:-copilot-pull-request-reviewer}/g")
	PATH="$tmp/bin:$PATH" "$1" -c "$s" 2>/dev/null
}

unable='Copilot was unable to review this pull request because of a quota.'
unable_v2=$(printf '<!-- ccr-overview-v2 -->\n## Copilot review overview\n\n%s' "$unable")

shells=(bash)
command -v zsh >/dev/null 2>&1 && shells+=(zsh)

for sh in "${shells[@]}"; do
	# maguerrieri/home#35's shape: five rounds, then three owner pushes and a
	# fix round. The recount can't tell them apart, so all nine count.
	reset
	for h in 1 2 3 4 5 6 7 8 9; do review "$h"; done
	record 9 "$sh: every reviewed head counts, owner pushes included" "$(count "$sh")"
	record 9 "$sh: reviews over two pages" "$(PAGES=2 count "$sh")"

	reset; review 1; review 2; review 2
	record 2 "$sh: a re-review of the same head isn't a round" "$(count "$sh")"
	reset; review 1; review 2; review 3 "$unable"
	record 2 "$sh: an unable body isn't a round" "$(count "$sh")"
	reset; review 1; review 2; review 3 "$unable_v2"
	record 2 "$sh: a v2 unable body isn't a round" "$(count "$sh")"
	reset; review 1; review 2 "$unable"; review 2
	record 2 "$sh: a retry after an unable body counts its head once" "$(count "$sh")"
	reset; review 1; review 2; review 3 'Fixed in abc1234' maguerrieri
	record 2 "$sh: another login's review isn't a round" "$(count "$sh")"
	reset; review 1; review 2 -
	record 2 "$sh: a null body breaks nothing" "$(count "$sh")"
	reset; review 1; review 2
	record 2 "$sh: the bot login matches with the [bot] suffix" "$(count "$sh" 'copilot-pull-request-reviewer[bot]')"
	reset; review 1 '' 'coderabbitai[bot]'; review 2 "$unable" 'coderabbitai[bot]'; review 3
	record 2 "$sh: another engaged bot counts only its own reviews, unable filter off" "$(count "$sh" coderabbitai)"
	reset
	record 0 "$sh: no reviews, no rounds" "$(count "$sh")"
done

finish
