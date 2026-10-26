#!/usr/bin/env bash
# Tests for the review-round count in the default profile's REVIEW_BOT
# (*Count the rounds*, *Owner requests*). They run the documented snippet,
# pulled out of the profile, against a gh stub that serves fixture reviews and
# PR comments, so the docs can't drift from what is tested:
#
# - only automated review rounds count. In the maguerrieri/home#35 sequence
#   the pushes that land the owner's setting, account and hostname decisions
#   don't move the count, and a decision folded into a fix push costs only the
#   round the fixes cost. In the sprue-works/sonder#509 shape, the owner
#   iterating in the child's session costs nothing, while a bot-finding fix
#   between the iterations still counts;
# - an Owner head: marker frees its head only when it cites an
#   Owner request: record posted before it, each record frees one head, a
#   head the bot first reviewed before the record stays a round, a marker that
#   frees nothing uses nothing up (so a corrected marker works), and both
#   comments must come from the owner's login (anyone can comment on a public
#   repo's PR);
# - a failed read of the login or the comments skips nothing, so the count
#   errs high.
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

snippet=$(extract_block "$profile" 'requests=$(gh api' |
	sed -e 's/<pr>/35/g' -e 's/<bot login>/copilot-pull-request-reviewer/g')
record yes "count snippet found in the profile" "$([ -n "$snippet" ] && echo yes || echo no)"

# The stub answers the snippet's three reads: the login (STUB_LOGIN, a failure
# when empty), the PR comments and the reviews (fixture files in slurp shape,
# a failure when STUB_FAIL_COMMENTS is set).
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
case "$2" in
user) [ -n "${STUB_LOGIN:-}" ] || { echo 'HTTP 401' >&2; exit 1; }; printf '%s\n' "$STUB_LOGIN" ;;
*/issues/35/comments*) [ -z "${STUB_FAIL_COMMENTS:-}" ] || { echo 'HTTP 502' >&2; exit 1; }; cat "$STUB_DIR/comments.json" ;;
*/pulls/35/reviews*) cat "$STUB_DIR/reviews.json" ;;
*) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$tmp/bin/gh"
export STUB_DIR="$tmp"

url='https://github.com/OWNER/REPO/pull/35#issuecomment-'
sha() { printf '%040x' "$1"; } # a deterministic full-length head sha

# Fixture builders. Each call appends to the current fixture, stamped one
# second after the call before it, so the calls' order is the timeline; reset
# starts over.
reset() { reviews='[]' comments='[]' clock=0; }
tick() { clock=$((clock + 1)); now=$(printf '2026-10-22T10:%02d:%02dZ' $((clock / 60)) $((clock % 60))); }
review() { # review <head n> [body]
	tick
	reviews=$(jq -c --arg s "$(sha "$1")" --arg b "${2:-### 🟡 Changes recommended}" --arg t "$now" \
		'. + [{user: {login: "copilot-pull-request-reviewer[bot]"}, commit_id: $s, body: $b, submitted_at: $t}]' <<<"$reviews")
}
comment() { # comment <id> <login> <body>; a body of - is null
	tick
	comments=$(jq -c --argjson i "$1" --arg l "$2" --arg b "$3" --arg t "$now" \
		'. + [{id: $i, user: {login: $l, type: "User"}, body: (if $b == "-" then null else $b end), created_at: $t}]' <<<"$comments")
}
request() { comment "$1" owner "Owner request: $2 (owner: in this session, 2026-10-22)"; }
marker() { # marker <id> <head n> <cited comment id>...
	local id=$1 head=$2 cites=''
	shift 2
	for c in "$@"; do cites="$cites ${url}$c"; done
	comment "$id" owner "Owner head: $(sha "$head") lands${cites}"
}

# Writes the fixture as one page of comments and one of reviews (or comments
# split over two pages with PAGES=2), runs the snippet, and prints the count.
count() { # count [shell]
	printf '%s' "$reviews" | jq -c '[.]' >"$tmp/reviews.json"
	if [ "${PAGES:-1}" = 2 ]; then
		printf '%s' "$comments" | jq -c '[.[:(length / 2 | floor)], .[(length / 2 | floor):]]' >"$tmp/comments.json"
	else
		printf '%s' "$comments" | jq -c '[.]' >"$tmp/comments.json"
	fi
	PATH="$tmp/bin:$PATH" STUB_LOGIN=${STUB_LOGIN-owner} "${1:-bash}" -c "$snippet" 2>/dev/null
}

shells=(bash)
command -v zsh >/dev/null 2>&1 && shells+=(zsh)

for sh in "${shells[@]}"; do
	# --- maguerrieri/home#35 ------------------------------------------------
	# Rounds 1-5 on heads 1-5. Mid-review the owner adds a setting (head 6),
	# answers the admin account (head 7), a fix round follows (head 8), and
	# the hostname arrives while head 8's review is in flight; it comes back
	# clean, so the hostname goes out alone (head 9).
	reset
	for h in 1 2 3 4 5; do review "$h"; done
	request 101 'add the autorestartatconnect setting'
	marker 102 6 101
	review 6
	request 103 'the admin account is admin'
	marker 104 7 103
	review 7
	review 8
	request 105 'the hostname is abzu'
	marker 106 9 105
	review 9 '### 🟢 Approval recommended'
	record 6 "$sh: #35, the three decision pushes don't count" "$(count "$sh")"
	record 6 "$sh: #35 with comments over two pages" "$(PAGES=2 count "$sh")"

	# The same, but the hostname rides head 8's fix push (no marker): the
	# fixes cost their round, the decision costs nothing more.
	reset
	for h in 1 2 3 4 5; do review "$h"; done
	request 101 'add the autorestartatconnect setting'
	marker 102 6 101
	review 6
	request 103 'the admin account is admin'
	marker 104 7 103
	review 7
	request 105 'the hostname is abzu'
	review 8
	record 6 "$sh: #35, the hostname folded into a fix push" "$(count "$sh")"

	# Without the rule's comments, every head is a round.
	reset
	for h in 1 2 3 4 5 6 7 8 9; do review "$h"; done
	record 9 "$sh: no owner-request comments, every head counts" "$(count "$sh")"

	# --- sprue-works/sonder#509 ----------------------------------------------
	# Three bot rounds, then the owner iterates in the child's session: four
	# requests, each recorded and pushed alone (heads 4, 5, 7, 8), with one fix
	# for a finding the bot raised on head 5 in between (head 6).
	reset
	for h in 1 2 3; do review "$h"; done
	request 101 'rename the flow to goods-you-can-follow'
	marker 102 4 101
	review 4
	request 103 'split bulk from packaged'
	marker 104 5 103
	review 5
	review 6
	request 105 'formal trade first'
	marker 106 7 105
	review 7
	request 107 'tighten the ADR summary'
	marker 108 8 107
	review 8 '### 🟢 Approval recommended'
	record 4 "$sh: sonder#509, in-session iteration costs no round, the bot fix does" "$(count "$sh")"

	# --- What a marker needs --------------------------------------------------
	# Two ordinary rounds, then each case's comments, then head 3's review
	# (and head 4's) after them.
	base() { reset; review 1; review 2; }

	base; request 101 'one'; marker 102 3 101; review 3
	record 2 "$sh: a valid marker frees its head" "$(count "$sh")"
	base; marker 101 3; review 3
	record 3 "$sh: a marker that cites nothing frees nothing" "$(count "$sh")"
	base; marker 101 3 102; request 102 'later'; review 3
	record 3 "$sh: a marker citing a record posted after it frees nothing" "$(count "$sh")"
	base; request 101 'one'; marker 102 3 101; review 3; marker 103 4 101; review 4
	record 3 "$sh: one record frees one head, the first marker's" "$(count "$sh")"
	base; request 101 'one'; request 102 'two'; marker 103 3 101 102; review 3
	record 2 "$sh: one head may land several records" "$(count "$sh")"
	base; request 101 'one'; request 102 'two'; marker 103 3 101 102; review 3; marker 104 4 102; review 4
	record 3 "$sh: a record a head already used frees no second head" "$(count "$sh")"
	base; request 101 'one'; marker 102 1 101
	record 2 "$sh: a head reviewed before its record stays a round" "$(count "$sh")"
	base; review 3; request 101 'one'; marker 102 3 101; review 3
	record 3 "$sh: a head first reviewed before its record stays a round" "$(count "$sh")"
	base; request 101 'one'; marker 102 9 101; marker 103 3 101; review 3
	record 2 "$sh: a marker with a wrong sha uses nothing up" "$(count "$sh")"
	base; request 101 'one'; marker 102 1 101; marker 103 3 101; review 3
	record 2 "$sh: a marker naming an old head uses nothing up" "$(count "$sh")"
	base; request 101 'one'; marker 102 3 101
	record 2 "$sh: a marker for a head not yet reviewed frees it once reviewed (before)" "$(count "$sh")"
	review 3
	record 2 "$sh: a marker for a head not yet reviewed frees it once reviewed (after)" "$(count "$sh")"
	base; comment 101 drive-by 'Owner request: add a step (owner: me)'; marker 102 3 101; review 3
	record 3 "$sh: a record from another login is no record" "$(count "$sh")"
	base; request 101 'one'; comment 102 drive-by "Owner head: $(sha 3) lands ${url}101"; review 3
	record 3 "$sh: a marker from another login is no marker" "$(count "$sh")"
	base; comment 101 owner 'Quoting it: Owner request: one (owner: x)'; marker 102 3 101; review 3
	record 3 "$sh: a record must open its comment" "$(count "$sh")"
	base; comment 101 owner "$(printf '\n  Owner request: one (owner: x)')"; marker 102 3 101; review 3
	record 2 "$sh: a record may open with whitespace" "$(count "$sh")"
	base; request 101 'one'; comment 102 owner "Owner head: $(sha 3 | cut -c1-7) lands ${url}101"; review 3
	record 3 "$sh: a marker needs the full sha" "$(count "$sh")"
	base; comment 100 owner -; request 101 'one'; marker 102 3 101; review 3
	record 2 "$sh: a comment with a null body breaks nothing" "$(count "$sh")"

	# --- Failed reads skip nothing ---------------------------------------------
	base; request 101 'one'; marker 102 3 101; review 3
	record 3 "$sh: a failed login read skips nothing" "$(STUB_LOGIN='' count "$sh")"
	record 3 "$sh: a failed comments read skips nothing" "$(STUB_FAIL_COMMENTS=1 count "$sh")"

	# --- The rest of the count is unchanged ------------------------------------
	base; review 2; record 2 "$sh: a re-review of the same head isn't a round" "$(count "$sh")"
	base; review 3 'Copilot was unable to review this pull request because of a quota.'
	record 2 "$sh: an unable body isn't a round" "$(count "$sh")"
done

finish
