#!/usr/bin/env bash
# Tests for scripts/owner-approval.sh, which says whether the owner's
# approving review of a PR is a merge grant: exit 0 (it is, with the PR's head
# and the newest owner approval of it, body and line comments, printed as one
# JSON object), 1 (anything else), 2 (a usage error). owner-check.sh runs for real, and gh is a stub that answers
# each read with JSON and applies the caller's --jq filter with jq:
#   STUB_ME, STUB_PERMS    the sessions' login, and "login=permission ..." pairs
#   STUB_PR_STATE          the PR's REST state (default open)
#   STUB_HEAD              the PR's head SHA (default $head)
#   STUB_REVIEWS           the PR's reviews, a JSON array (see review below)
#   STUB_PR_FAIL, STUB_REVIEWS_FAIL, STUB_GQL_FAIL
#                          set: that read fails (GraphQL as behind the cloud proxy)
#   STUB_PERM_FAIL         logins whose permission read fails
#   STUB_BASE, STUB_BASE_TIP
#                          the PR's base ref, and its tip by git/ref (unset: the read fails)
#   STUB_BASE_CHANGES      the PR's BaseRefChangedEvents, a JSON array
#   STUB_MERGED_PRS        merged PRs, a JSON array of {headRefName, headRefOid,
#                          baseRefName, mergedAt}, answered by headRefName
#   STUB_NODES             a JSON object keyed by review node id, merged into
#                          the GraphQL node the stub derives from the review
#                          (its state, commit, body, no edit and no line
#                          comments); null for an id makes its node null
#
#   bash plugins/ticket-workflow/tests/test-owner-approval.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
script="$plugin/scripts/owner-approval.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

command -v jq >/dev/null || {
	echo 'test-owner-approval.sh needs jq' >&2
	exit 1
}

cat >"$tmp/gh" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_ARGS"
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
endpoint=$2
filter=.
node= query= head_ref=
shift 2
while [ $# -gt 0 ]; do
	case $1 in
	--jq) filter=$2; shift 2 ;;
	-f | -F)
		case $2 in id=*) node=${2#id=} ;; query=*) query=${2#query=} ;; head=*) head_ref=${2#head=} ;; esac
		shift 2
		;;
	*) shift ;;
	esac
done
answer() { jq -r "$filter" <<<"$1"; }
case $endpoint in
user) answer "$(jq -n --arg l "${STUB_ME:-}" '{login: $l}')" ;;
repos/*/collaborators/*/permission)
	who=${endpoint%/permission}
	who=$(lower "${who##*/}")
	case " $(lower "${STUB_PERM_FAIL:-}") " in *" $who "*) echo '{"message": "Server Error"}'; exit 1 ;; esac
	for pair in ${STUB_PERMS:-}; do
		[ "$(lower "${pair%%=*}")" = "$who" ] && { answer "$(jq -n --arg p "${pair#*=}" '{permission: $p}')"; exit 0; }
	done
	answer '{"permission": "none"}'
	;;
repos/*/git/ref/heads/*)
	[ -n "${STUB_BASE_TIP:-}" ] || { echo '{"message": "Not Found"}'; exit 1; }
	answer "$(jq -n --arg s "$STUB_BASE_TIP" '{object: {sha: $s}}')"
	;;
repos/*/pulls/*/reviews\?per_page=100)
	[ -z "${STUB_REVIEWS_FAIL:-}" ] || { echo '{"message": "Not Found"}'; exit 1; }
	answer "${STUB_REVIEWS:-[]}"
	;;
repos/*/pulls/*)
	[ -z "${STUB_PR_FAIL:-}" ] || { echo '{"message": "Not Found"}'; exit 1; }
	answer "$(jq -n --arg s "${STUB_PR_STATE-open}" --arg h "${STUB_HEAD-}" --arg d "${STUB_DRAFT-false}" --arg b "${STUB_BASE-main}" \
		'{state: $s, head: {sha: $h}, base: {ref: $b}, draft: (if $d == "" then null else ($d == "true") end)}')"
	;;
graphql)
	[ -z "${STUB_GQL_FAIL:-}" ] || {
		echo 'HTTP 403: GitHub GraphQL is not available from Claude Code sessions' >&2
		exit 1
	}
	case $query in
	*BASE_REF_CHANGED_EVENT*)
		answer "$(jq -n --argjson c "${STUB_BASE_CHANGES:-[]}" '{data: {repository: {pullRequest: {timelineItems: {nodes: $c}}}}}')"
		exit 0
		;;
	*"pullRequests(headRefName"*)
		answer "$(jq -n --arg h "$head_ref" --argjson m "${STUB_MERGED_PRS:-[]}" \
			'{data: {repository: {pullRequests: {nodes: [$m[] | select(.headRefName == $h)]}}}}')"
		exit 0
		;;
	esac
	patch=${STUB_NODES:-}
	[ -n "$patch" ] || patch='{}'
	answer "$(jq -n --arg id "$node" --argjson reviews "${STUB_REVIEWS:-[]}" --argjson patch "$patch" '
		($reviews | map(select(.node_id == $id)) | first) as $r
		| if $r == null or ($patch | has($id) and .[$id] == null) then {data: {node: null}} else
		  {data: {node: ({__typename: "PullRequestReview", state: $r.state, commit: {oid: $r.commit_id},
		    editor: null, lastEditedAt: null, userContentEdits: {nodes: []}, body: ($r.body // ""),
		    comments: {totalCount: 0, nodes: []}}
		    + ($patch[$id] // {}))}} end')"
	;;
*) echo "unexpected endpoint $endpoint" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$tmp/gh"
export OWNER_CHECK_GH="$tmp/gh" STUB_ARGS="$tmp/args"

head=1111111111111111111111111111111111111111
old=2222222222222222222222222222222222222222
export STUB_HEAD=$head

review() { # review <id> <login> <state> <commit> <submitted_at> [<type> [<body>]]: one REST review, as JSON
	jq -n --argjson id "$1" --arg login "$2" --arg state "$3" --arg commit "$4" --arg at "$5" \
		--arg type "${6:-User}" --arg body "${7:-}" \
		'{id: $id, node_id: "PRR_\($id)", html_url: "https://github.com/o/r/pull/7#pullrequestreview-\($id)",
		  user: (if $login == "" then null else {login: $login, type: $type} end),
		  state: $state, commit_id: (if $commit == "" then null else $commit end),
		  submitted_at: (if $at == "" then null else $at end), body: $body}'
}
reviews() { # reviews <review json>...: the array STUB_REVIEWS takes
	jq -s . <<<"$*"
}

run_raw() { # run_raw [args...]: the exit code
	: >"$tmp/args"
	bash "$script" "$@" >"$tmp/out" 2>"$tmp/err"
	printf '%s' "$?"
}
run() { # run: run_raw on PR 7 of the repo $REPO names (github.com/o/r when unset)
	run_raw -R "${REPO-github.com/o/r}" 7
}
out() { # out <jq filter>: the filter applied to the last run's stdout
	jq -r "$1" <"$tmp/out"
}
calls() { # calls <pattern>: how many stub calls of the last run matched it
	grep -c -- "$1" "$tmp/args"
}
gh_calls() { # gh_calls: how many stub calls the last run made
	wc -l <"$tmp/args" | tr -d ' '
}

# The usual distinct-mode setup: the owner is admin, the sessions' own login
# has write, and so do two collaborators.
export STUB_ME=sprue-works-bot STUB_PERMS='maguerrieri=admin coadmin=admin sprue-works-bot=write mate=write reader=read'

t1=2026-11-17T05:00:00Z t2=2026-11-17T06:00:00Z t3=2026-11-17T07:00:00Z
copilot=$(review 10 'copilot-pull-request-reviewer[bot]' COMMENTED "$head" 2026-11-17T04:00:00Z Bot 'Copilot reviewed 3 files')
approve=$(review 11 maguerrieri APPROVED "$head" "$t1")

# The acceptance case: the owner approves the head with an empty body.
record 0 'the owner'"'"'s approval of the head, empty body' "$(STUB_REVIEWS=$(reviews "$copilot" "$approve") run)"
record "$head" 'prints the head it covers' "$(out .head)"
record 'maguerrieri https://github.com/o/r/pull/7#pullrequestreview-11 2026-11-17T05:00:00Z' \
	'and the approval' "$(out '"\(.reviewer) \(.url) \(.submitted_at)"')"
record '"" 7' 'its body, empty, and the PR' "$(out '"\(.body | tojson) \(.pr)"')"
record 1 'the approver is checked once' "$(calls 'collaborators/maguerrieri/')"
record 0 'the bot'"'"'s review gets no owner check' "$(calls 'copilot')"
body_review=$(review 11 maguerrieri APPROVED "$head" "$t1" User $'looks good\nhold until Friday')
record 0 'an approval with a body is still read' "$(STUB_REVIEWS=$(reviews "$body_review") run)"
record "looks good
hold until Friday" 'and prints its body whole, for the session to read' "$(out '.body')"
record 1 'it reads the body with its editor, from GraphQL' "$(calls '^api graphql ')"

# It counts only for the commit approved.
record 1 'an approval of an older commit' "$(STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$old" "$t1")") run)"
record 1 'an approval with no commit' "$(STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED '' "$t1")") run)"
record 1 'an approval when the PR reads no head' "$(STUB_HEAD= STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED '' "$t1")") run)"
record 0 'the owner'"'"'s newer approval of the head after one of an older commit' \
	"$(STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$old" "$t1")" "$(review 12 maguerrieri APPROVED "$head" "$t2")") run)"

# Nothing decisive may follow the approval: a request for changes or a
# dismissal, by anyone. A later COMMENTED review changes nothing.
record 1 'a dismissed approval' "$(STUB_REVIEWS=$(reviews "$(review 11 maguerrieri DISMISSED "$head" "$t1")") run)"
record 1 'an approval, then changes requested' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 maguerrieri CHANGES_REQUESTED "$head" "$t2")") run)"
record 1 'an approval, then a dismissed one' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 maguerrieri DISMISSED "$head" "$t2")") run)"
record 1 'changes requested, then dismissed: the earlier approval does not come back' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 maguerrieri DISMISSED "$head" "$t2")" "$(review 13 maguerrieri COMMENTED "$head" "$t3")") run)"
record 0 'changes requested, then an approval' \
	"$(STUB_REVIEWS=$(reviews "$(review 11 maguerrieri CHANGES_REQUESTED "$old" "$t1")" "$(review 12 maguerrieri APPROVED "$head" "$t2")") run)"
record 0 'an approval, then a COMMENTED review' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 maguerrieri COMMENTED "$head" "$t2" User 'one more thing')") run)"
record 11 'which leaves the approval as the one printed' "$(out '.url | sub(".*-"; "")')"
record 1 'the newest by submission time, whatever the order GitHub lists them in' \
	"$(STUB_REVIEWS=$(reviews "$(review 12 maguerrieri CHANGES_REQUESTED "$head" "$t2")" "$approve") run)"
record 1 'two decisive reviews at one time: the higher id is the later' \
	"$(STUB_REVIEWS=$(reviews "$(review 12 maguerrieri CHANGES_REQUESTED "$head" "$t1")" "$approve") run)"
record 0 'and the other way round' \
	"$(STUB_REVIEWS=$(reviews "$(review 10 maguerrieri CHANGES_REQUESTED "$head" "$t1")" "$approve") run)"
record 1 'the same login in another case requested changes' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 MaGuerrieri CHANGES_REQUESTED "$head" "$t2")") run)"
record 0 'a pending review is not a review' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 maguerrieri PENDING '' '')") run)"
record 1 'no reviews at all' "$(STUB_REVIEWS='[]' run)"
record 1 'only the bot'"'"'s' "$(STUB_REVIEWS=$(reviews "$copilot") run)"

# Anyone's standing request for changes holds the PR.
record 1 'a collaborator'"'"'s changes still requested' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 mate CHANGES_REQUESTED "$head" "$t2")") run)"
record 1 'even one made before the owner approved' \
	"$(STUB_REVIEWS=$(reviews "$(review 9 mate CHANGES_REQUESTED "$old" 2026-11-17T04:30:00Z)" "$approve") run)"
record 0 'but not once that collaborator approved' \
	"$(STUB_REVIEWS=$(reviews "$(review 9 mate CHANGES_REQUESTED "$old" 2026-11-17T04:30:00Z)" "$approve" "$(review 12 mate APPROVED "$head" "$t2")") run)"
record maguerrieri 'and the owner'"'"'s approval is the one printed' "$(out .reviewer)"
record 0 'or once it was dismissed before the owner approved' \
	"$(STUB_REVIEWS=$(reviews "$(review 9 mate DISMISSED "$old" 2026-11-17T04:30:00Z)" "$approve") run)"
# A dismissal keeps the review's submission time, so dismissing a request for
# changes made after the approval leaves a dismissed review after it.
record 1 'a collaborator'"'"'s request for changes after the approval, dismissed since' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 mate DISMISSED "$head" "$t2")") run)"
record 1 'and a bot'"'"'s' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 'review-action[bot]' DISMISSED "$head" "$t2" Bot)") run)"
record 1 'a dismissed review after the approval with no submission time' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 mate DISMISSED "$head" '')") run)"
record 1 'one at the approval'"'"'s own time with a higher id' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 mate DISMISSED "$head" "$t1")") run)"
record 0 'one at its time with a lower id is before it' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 10 mate DISMISSED "$head" "$t1")") run)"
record 1 'a bot'"'"'s changes requested' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 'review-action[bot]' CHANGES_REQUESTED "$head" "$t2" Bot)") run)"
record 1 'a deleted account'"'"'s changes requested' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 '' CHANGES_REQUESTED "$head" "$t2")") run)"
record 1 'one deleted account'"'"'s request for changes, not hidden by another'"'"'s later approval' \
	"$(STUB_REVIEWS=$(reviews "$(review 8 '' CHANGES_REQUESTED "$old" 2026-11-17T04:10:00Z)" "$(review 9 '' APPROVED "$old" 2026-11-17T04:20:00Z)" "$approve") run)"
record 0 'a deleted account'"'"'s newer approval of the head, as the ghost user, is passed over unchecked' \
	"$(STUB_PERM_FAIL=ghost STUB_REVIEWS=$(reviews "$approve" "$(review 12 ghost APPROVED "$head" "$t2")") run)"
record 0 'with no owner check of ghost' "$(calls 'collaborators/ghost/')"
record 1 'nor by another'"'"'s, both shown as GitHub'"'"'s ghost user' \
	"$(STUB_REVIEWS=$(reviews "$(review 8 ghost CHANGES_REQUESTED "$old" 2026-11-17T04:10:00Z)" "$(review 9 Ghost APPROVED "$old" 2026-11-17T04:20:00Z)" "$approve") run)"
STUB_REVIEWS=$(reviews "$approve" "$(review 12 mate CHANGES_REQUESTED "$head" "$t2")") run >/dev/null
record 1 'a request for changes after the approval is said once' "$(grep -c 'mate' "$tmp/err")"

# Only the owner's approval: owner-check exits 0 for its author.
record 1 'a write collaborator'"'"'s approval' "$(STUB_REVIEWS=$(reviews "$(review 11 mate APPROVED "$head" "$t1")") run)"
record 1 'the sessions'"'"' own login'"'"'s' "$(STUB_REVIEWS=$(reviews "$(review 11 sprue-works-bot APPROVED "$head" "$t1")") run)"
record 1 'a Bot of the owner'"'"'s login' "$(STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$head" "$t1" Bot)") run)"
record 0 'which gets no owner check' "$(calls 'permission')"
record 1 'a deleted account'"'"'s' "$(STUB_REVIEWS=$(reviews "$(review 11 '' APPROVED "$head" "$t1")") run)"
record 0 'another admin'"'"'s approval is the owner'"'"'s too' \
	"$(STUB_REVIEWS=$(reviews "$(review 11 coadmin APPROVED "$head" "$t1")") run)"
record 0 'two owners'"'"' approvals of the head' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 coadmin APPROVED "$head" "$t2" User 'not yet')") run)"
record 'coadmin not yet' 'print the newest, whose body is the latest word' "$(out '"\(.reviewer) \(.body)"')"
record 0 'the newer owner approval checked first, the older never' "$(calls 'collaborators/maguerrieri/')"
record 1 'a failed owner check of the newer approver fails closed, never falling back to the older approval' \
	"$(STUB_PERM_FAIL=coadmin STUB_REVIEWS=$(reviews "$approve" "$(review 12 coadmin APPROVED "$head" "$t2" User 'do not merge yet')") run)"
record 1 'and says it couldn'"'"'t read the check' "$(grep -c "can't read whether coadmin" "$tmp/err")"
record 0 'a collaborator'"'"'s rejection by a read that worked still falls back to the owner' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 mate APPROVED "$head" "$t2")") run)"
record 1 'but a failed read of that collaborator doesn'"'"'t' \
	"$(STUB_PERM_FAIL=mate STUB_REVIEWS=$(reviews "$approve" "$(review 12 mate APPROVED "$head" "$t2")") run)"
record 1 'another owner'"'"'s newer approval of an older commit is the owners'"'"' latest word: no grant' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 coadmin APPROVED "$old" "$t2")") run)"
record 0 'and a collaborator'"'"'s approval of the head' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 mate APPROVED "$head" "$t2")") run)"
record maguerrieri 'leaves the owner'"'"'s as the one printed' "$(out .reviewer)"
record 1 'and the collaborator is checked once, however many approvals it gave' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 mate APPROVED "$head" "$t2")" "$(review 13 mate APPROVED "$head" "$t3")") run >/dev/null; calls 'collaborators/mate/')"

# Sessions posting as the owner's own account: nothing changes.
same='maguerrieri=admin coadmin=admin'
record 1 'the shared admin login'"'"'s approval (owner-check 3)' \
	"$(STUB_ME=maguerrieri STUB_PERMS=$same STUB_REVIEWS=$(reviews "$approve") run)"
record 1 'another admin'"'"'s, while the sessions'"'"' login is one' \
	"$(STUB_ME=maguerrieri STUB_PERMS=$same STUB_REVIEWS=$(reviews "$(review 11 coadmin APPROVED "$head" "$t1")") run)"
record 1 'the shared login below admin' \
	"$(STUB_ME=maguerrieri STUB_PERMS='maguerrieri=write' STUB_REVIEWS=$(reviews "$approve") run)"

# Its body is the owner's only while no one but an owner has edited it.
edited=2026-11-17T08:00:00Z
node() { # node <review id> <editor type> <editor login> [<body>]: STUB_NODES for an edit of it
	jq -n --arg id "PRR_$1" --arg t "$2" --arg l "$3" --arg at "$edited" --arg body "${4:-edited}" \
		'{($id): {editor: {__typename: $t, login: $l}, lastEditedAt: $at,
		  userContentEdits: {nodes: [{editedAt: $at, editor: {__typename: $t, login: $l}}]}, body: $body}}'
}
held=$(reviews "$(review 11 maguerrieri APPROVED "$head" "$t1" User 'hold until #12 lands')")
record 0 'an approval its author edited' "$(STUB_REVIEWS=$held STUB_NODES=$(node 11 User maguerrieri 'now merge it') run)"
record 'now merge it' 'prints the edited body' "$(out .body)"
record 0 'one another admin edited' "$(STUB_REVIEWS=$held STUB_NODES=$(node 11 User coadmin) run)"
record 1 'one the sessions'"'"' own login edited' "$(STUB_REVIEWS=$held STUB_NODES=$(node 11 User sprue-works-bot '') run)"
record 1 'one a write collaborator edited' "$(STUB_REVIEWS=$held STUB_NODES=$(node 11 User mate '') run)"
record 1 'one a Bot edited' "$(STUB_REVIEWS=$held STUB_NODES=$(node 11 Bot maguerrieri '') run)"
record 1 'an edit GitHub names no editor for' \
	"$(STUB_REVIEWS=$held STUB_NODES='{"PRR_11": {"editor": null, "lastEditedAt": "2026-11-17T08:00:00Z", "body": ""}}' run)"
record 1 'an edit history that disagrees with the editor' \
	"$(STUB_REVIEWS=$held STUB_NODES=$(node 11 User maguerrieri | jq '.PRR_11.userContentEdits.nodes[0].editor.login = "mate"') run)"
record 1 'an edit history at another time' \
	"$(STUB_REVIEWS=$held STUB_NODES=$(node 11 User maguerrieri | jq '.PRR_11.userContentEdits.nodes[0].editedAt = "2026-11-17T09:00:00Z"') run)"
record 1 'an edited review with no edit history' \
	"$(STUB_REVIEWS=$held STUB_NODES=$(node 11 User maguerrieri | jq '.PRR_11.userContentEdits.nodes = []') run)"
record 1 'the newer of two owners'"'"' approvals edited by a collaborator' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 coadmin APPROVED "$head" "$t2")") STUB_NODES=$(node 12 User mate '') run)"
record 0 'the older of the two, edited by a collaborator, no longer matters' \
	"$(STUB_REVIEWS=$(reviews "$approve" "$(review 12 coadmin APPROVED "$head" "$t2")") STUB_NODES=$(node 11 User mate '') run)"

# The approval's own line comments are its words too: printed for the session
# to read, each held to the same editor rule.
lc() { # lc <id> <body> [<editor type> <editor login>]: one of the review's line comments, as GraphQL gives it
	jq -n --arg url "https://github.com/o/r/pull/7#discussion_r$1" --arg body "$2" --arg t "${3:-}" --arg l "${4:-}" --arg at "$edited" \
		'{url: $url, path: "a.sh", body: $body}
		 + if $t == "" then {editor: null, lastEditedAt: null, userContentEdits: {nodes: []}}
		   else {editor: {__typename: $t, login: $l}, lastEditedAt: $at,
		         userContentEdits: {nodes: [{editedAt: $at, editor: {__typename: $t, login: $l}}]}} end'
}
with_comments() { # with_comments <line comment json>...: STUB_NODES giving review 11 those line comments
	jq -n --argjson c "$(jq -s . <<<"$*")" '{PRR_11: {comments: {totalCount: ($c | length), nodes: $c}}}'
}
two=$(with_comments "$(lc 301 'rename this before merging')" "$(lc 302 'and this')")
record 0 'an approval with line comments' "$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES=$two run)"
record 'a.sh https://github.com/o/r/pull/7#discussion_r301 rename this before merging|a.sh https://github.com/o/r/pull/7#discussion_r302 and this' \
	'prints each, for the session to read for a hold or a change' "$(out '[.comments[] | "\(.path) \(.url) \(.body)"] | join("|")')"
record '[]' 'an approval with none prints an empty list' "$(STUB_REVIEWS=$(reviews "$approve") run >/dev/null; out '.comments | tojson')"
record 0 'a line comment its author edited' \
	"$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES=$(with_comments "$(lc 301 x User maguerrieri)") run)"
record 0 'one another owner edited' \
	"$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES=$(with_comments "$(lc 301 x User coadmin)") run)"
record 1 'one a collaborator edited' \
	"$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES=$(with_comments "$(lc 301 x)" "$(lc 302 '' User mate)") run)"
record 1 'one the sessions'"'"' own login edited' \
	"$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES=$(with_comments "$(lc 301 '' User sprue-works-bot)") run)"
record 1 'one a Bot edited' \
	"$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES=$(with_comments "$(lc 301 '' Bot maguerrieri)") run)"
record 1 'one whose edit history disagrees' \
	"$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES=$(with_comments "$(lc 301 '' User maguerrieri | jq '.userContentEdits.nodes[0].editor.login = "mate"')") run)"
record 1 'more line comments than the read returns' \
	"$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES=$(with_comments "$(lc 301 x)" | jq '.PRR_11.comments.totalCount = 101') run)"
record 1 'no line-comment count' \
	"$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES=$(with_comments "$(lc 301 x)" | jq '.PRR_11.comments = null') run)"

# The GraphQL read that names the editor also re-reads the review's state and
# commit, so a dismissal or a stale read between the two reads fails closed.
record 1 'GraphQL refused (the cloud proxy)' "$(STUB_GQL_FAIL=1 STUB_REVIEWS=$(reviews "$approve") run)"
record 1 'dismissed by the time GraphQL reads it' \
	"$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES='{"PRR_11": {"state": "DISMISSED"}}' run)"
record 1 'GraphQL names another commit' \
	"$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES="{\"PRR_11\": {\"commit\": {\"oid\": \"$old\"}}}" run)"
record 1 'GraphQL returns another type of node' \
	"$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES='{"PRR_11": {"__typename": "IssueComment"}}' run)"
record 1 'GraphQL returns no node' "$(STUB_REVIEWS=$(reviews "$approve") STUB_NODES='{"PRR_11": null}' run)"
record 1 'a review GitHub files under another PR' \
	"$(STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$head" "$t1" | jq '.html_url = "https://github.com/o/r/pull/8#pullrequestreview-11"')") run)"
record 1 'or under a URL that would break the JSON' \
	"$(STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$head" "$t1" | jq '.html_url += "\","')") run)"
record 0 'a review URL in another case is the same review' \
	"$(STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$head" "$t1" | jq '.html_url = "https://github.com/O/R/pull/7#pullrequestreview-11"')") run)"
record 1 'a submission time not in GitHub'"'"'s form' \
	"$(STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$head" '2026-11-17T05:00:00Z"')") run)"
record 1 'a review with no node id' \
	"$(STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$head" "$t1" | jq '.node_id = null')") run)"

# The PR itself.
record 1 'a closed PR' "$(STUB_PR_STATE=closed STUB_REVIEWS=$(reviews "$approve") run)"
record 1 'a draft PR' "$(STUB_DRAFT=true STUB_REVIEWS=$(reviews "$approve") run)"
record 1 'a PR whose draft flag reads nothing' "$(STUB_DRAFT= STUB_REVIEWS=$(reviews "$approve") run)"
record 1 'a failed PR read' "$(STUB_PR_FAIL=1 STUB_REVIEWS=$(reviews "$approve") run)"
record 1 'a failed reviews read' "$(STUB_REVIEWS_FAIL=1 STUB_REVIEWS=$(reviews "$approve") run)"
record 1 'a head that is not a SHA' "$(STUB_HEAD='1111;id' STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED '1111;id' "$t1")") run)"
STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$old" "$t1")") run >/dev/null
record 1 'stderr says why there is no grant' "$(grep -q "^owner-approval.sh: no grant: .*$old" "$tmp/err" && echo 1)"
record 0 'and stdout carries nothing' "$(wc -c <"$tmp/out" | tr -d ' ')"

# Every read goes to the repo's own host.
STUB_REVIEWS=$(reviews "$approve") run >/dev/null
record 1 'the PR is read on its host' "$(calls '^api repos/o/r/pulls/7 --hostname github.com ')"
record 1 'its reviews, every page' "$(calls '^api repos/o/r/pulls/7/reviews?per_page=100 --hostname github.com --paginate ')"
record 1 'owner-check gets -R with the host' "$(calls '^api repos/o/r/collaborators/maguerrieri/permission --hostname github.com ')"
record 1 'GraphQL goes to that host too' "$(calls '^api graphql --hostname github.com ')"
STUB_REVIEWS=$(reviews "$approve") REPO=ghe.example.com/acme/app run >/dev/null
record 1 'an enterprise PR is read on its own host' "$(calls '^api repos/acme/app/pulls/7 --hostname ghe.example.com ')"
record 1 'and its approver checked there' "$(calls '^api repos/acme/app/collaborators/maguerrieri/permission --hostname ghe.example.com ')"
record 0 '-R compared as given' "$(REPO=GitHub.com/o/r STUB_REVIEWS=$(reviews "$approve") run)"

# An approval of an earlier head still covers the head when the PR's diff is
# the same: after a restack, say. GitHub names every commit compared (the
# head, the base's tip, and the approved commit's base: the merged parent's
# last head after one base change, else the base's tip), and the whole diff
# must match but for blob ids and hunk positions. A real git repository holds
# the commits: main B0; a parent branch P1 off it; the approved child A = P1 +
# C1; main after the parent's rebase merge (P1 again as a new commit, then an
# unrelated M); the restacked child H = main + C1 again; H2 the same with C1
# changed; HW with only C1's whitespace changed; HX with c.txt executable; and,
# for an unstacked PR, A0 = B0 + C1, which H also restacks onto the moved main.
repo=$tmp/repo
mkdir -p "$repo"
g() { git -C "$repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
commit_file() { # commit_file <file> <content> <message>: a commit on the checked-out branch, its sha
	printf '%s\n' "$2" >"$repo/$1" && g add "$1" && g commit -q -m "$3" && g rev-parse HEAD
}
g init -q -b main
B0=$(commit_file a.txt base 'base')
g checkout -q -b parent
P1=$(commit_file p.txt 'parent change' '[#1] parent')
g checkout -q -b child
A=$(commit_file c.txt $'child\n  indented' '[#2] child')
g checkout -q main
GIT_COMMITTER_DATE='2026-01-02T00:00:00Z' g cherry-pick "$P1" >/dev/null # the parent, rebase-merged: a new commit
M=$(commit_file m.txt 'unrelated' 'main moves')
g checkout -q -b restacked
H=$(commit_file c.txt $'child\n  indented' '[#2] child')
g checkout -q main && g checkout -q -b changed
H2=$(commit_file c.txt $'child, changed\n  indented' '[#2] child')
g checkout -q main && g checkout -q -b whitespace
HW=$(commit_file c.txt $'child\n\tindented' '[#2] child')
g checkout -q restacked && g checkout -q -b extra
HE=$(commit_file e.txt 'unreviewed' '[#2] more')
# HS: main + a commit adding c.txt and a secret, then one removing the secret:
# the same final tree as H, through a state nobody approved.
g checkout -q main && g checkout -q -b secret
printf '%s\n' $'child\n  indented' >"$repo/c.txt" && printf 'token\n' >"$repo/s.txt" && g add c.txt s.txt && g commit -q -m '[#2] child'
g rm -q s.txt && g commit -q -m '[#2] tidy'
HS=$(g rev-parse HEAD)
g checkout -q main && g checkout -q -b mode
printf '%s\n' $'child\n  indented' >"$repo/c.txt" && chmod +x "$repo/c.txt" && g add c.txt && g commit -q -m '[#2] child'
HX=$(g rev-parse HEAD)
g checkout -q "$B0" && g checkout -q -b unstacked
A0=$(commit_file c.txt $'child\n  indented' '[#2] child')
g checkout -q main
in_repo() { # in_repo <args...>: run_raw on PR 7 from inside the repository
	(cd "$repo" && run_raw -R github.com/o/r 7 "$@")
}
# The parent landed at 05:30 and GitHub retargeted the PR at 05:31, after the
# owner approved A at 05:00.
retarget='[{"__typename": "BaseRefChangedEvent", "previousRefName": "parent", "currentRefName": "main", "createdAt": "2026-11-17T05:31:00Z"}]'
force_push='{"__typename": "BaseRefForcePushedEvent", "createdAt": "2026-11-17T05:40:00Z"}'
landed() { # landed [<base> [<merged at>]]: STUB_MERGED_PRS with the parent merged
	jq -n --arg o "$P1" --arg b "${1:-main}" --arg at "${2:-2026-11-17T05:30:00Z}" \
		'[{headRefName: "parent", headRefOid: $o, baseRefName: $b, mergedAt: $at, isCrossRepository: false}]'
}
export STUB_BASE_TIP=$M STUB_BASE_CHANGES=$retarget STUB_MERGED_PRS=$(landed)
carried=$(reviews "$(review 11 maguerrieri APPROVED "$A" "$t1")")
record 0 'an approval of the head before a restack, after the parent landed: the same diff' \
	"$(STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record "$H $A" 'prints the head it covers and the commit approved' "$(out '"\(.head) \(.approved)"')"
record 1 'it reads the base'"'"'s tip from GitHub' "$(calls '^api repos/o/r/git/ref/heads/main --hostname github.com ')"
record 1 'a restack that changed the diff' "$(STUB_HEAD=$H2 STUB_REVIEWS=$carried in_repo)"
record 1 'one that changed only whitespace' "$(STUB_HEAD=$HW STUB_REVIEWS=$carried in_repo)"
record 1 'one that changed only a file mode' "$(STUB_HEAD=$HX STUB_REVIEWS=$carried in_repo)"
record 1 'no base change since the approval (already based on main): its range holds the parent'"'"'s commit too, one more than the head'"'"'s' \
	"$(STUB_BASE_CHANGES='[]' STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'a force-push of the base since the approval' \
	"$(STUB_BASE_CHANGES=$(jq --argjson f "$force_push" '. + [$f]' <<<"$retarget") STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 0 'one before it changes nothing' \
	"$(STUB_BASE_CHANGES=$(jq --argjson f "$force_push" '. + [$f | .createdAt = "2026-11-17T04:00:00Z"]' <<<"$retarget") STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'a parent whose last head isn'"'"'t under the approved commit (it moved on after)' \
	"$(STUB_MERGED_PRS=$(landed | jq --arg m "$M" '.[0].headRefOid = $m') STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'a head that adds something the approved commit didn'"'"'t' \
	"$(STUB_HEAD=$HE STUB_REVIEWS=$carried in_repo)"
record 1 'a head that drops something it did' \
	"$(STUB_BASE_CHANGES='[]' STUB_HEAD=$M STUB_REVIEWS=$carried in_repo)"
record 1 'a base change before the approval, likewise' \
	"$(STUB_BASE_CHANGES=$(jq '.[0].createdAt = "2026-11-17T04:00:00Z"' <<<"$retarget") STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'two base changes since it' \
	"$(STUB_BASE_CHANGES=$(jq '. + [.[0] | .createdAt = "2026-11-17T05:40:00Z"]' <<<"$retarget") STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'a change into another base than the PR'"'"'s' \
	"$(STUB_BASE_CHANGES=$(jq '.[0].currentRefName = "dev"' <<<"$retarget") STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'no merged PR had the old base as its head' "$(STUB_MERGED_PRS='[]' STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'one merged into another base' "$(STUB_MERGED_PRS=$(landed dev) STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'one merged after the change' \
	"$(STUB_MERGED_PRS=$(landed main 2026-11-17T05:45:00Z) STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'one merged before the approval' \
	"$(STUB_MERGED_PRS=$(landed main 2026-11-17T04:30:00Z) STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'one from a fork with the same branch name' \
	"$(STUB_MERGED_PRS=$(landed | jq '.[0].isCrossRepository = true') STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'one whose fork flag reads nothing' \
	"$(STUB_MERGED_PRS=$(landed | jq '.[0].isCrossRepository = null') STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'a force-push of the base in the approval'"'"'s own second counts as after it' \
	"$(STUB_BASE_CHANGES=$(jq --argjson f "$force_push" '. + [$f | .createdAt = "2026-11-17T05:00:00Z"]' <<<"$retarget") STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'two that could be the parent' \
	"$(STUB_MERGED_PRS=$(landed | jq '. + .') STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'an approved commit this checkout lacks' \
	"$(STUB_HEAD=$H STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED 3333333333333333333333333333333333333333 "$t1")") in_repo)"
record 1 'and stderr names it to fetch' "$(grep -c 'lacks 3333333333333333333333333333333333333333' "$tmp/err")"
record 1 'the same final tree through a commit nobody approved' "$(STUB_HEAD=$HS STUB_REVIEWS=$carried in_repo)"
record 1 'the owner'"'"'s newer approval of another commit, though an older one covers the head' \
	"$(STUB_HEAD=$H STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$A" "$t1")" "$(review 12 maguerrieri APPROVED "$H2" "$t2" User 'hold until Friday')") in_repo)"
record 1 'which stderr names as the owner'"'"'s newest' "$(grep -c "the owner's newest approval, by maguerrieri, is of $H2" "$tmp/err")"
record 1 'a base tip GitHub won'"'"'t give' "$(STUB_BASE_TIP= STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'a base tip this checkout lacks' \
	"$(STUB_BASE_TIP=3333333333333333333333333333333333333333 STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 1 'the base change unreadable (GraphQL refused)' "$(STUB_GQL_FAIL=1 STUB_HEAD=$H STUB_REVIEWS=$carried in_repo)"
record 0 'an unstacked PR rebased onto its moved base: no base change, so the base'"'"'s tip' \
	"$(STUB_BASE_CHANGES='[]' STUB_HEAD=$H STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$A0" "$t1")") in_repo)"
record 1 'a carried approval followed by a request for changes' \
	"$(STUB_HEAD=$H STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$A" "$t1")" "$(review 12 maguerrieri CHANGES_REQUESTED "$H" "$t2")") in_repo)"
record 1 'a carried approval GraphQL names another commit for' \
	"$(STUB_HEAD=$H STUB_REVIEWS=$carried STUB_NODES="{\"PRR_11\": {\"commit\": {\"oid\": \"$H\"}}}" in_repo)"
record 1 'outside a git repository' "$(cd / && STUB_HEAD=$H STUB_REVIEWS=$carried run_raw -R github.com/o/r 7)"
record 0 'an approval of the head itself needs no repository' \
	"$(cd / && STUB_HEAD=$H STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$H" "$t1")") run_raw -R github.com/o/r 7)"
record "$H" 'and prints the head as the commit approved' "$(out .approved)"
record 0 'nor any base-change read' "$(calls 'BASE_REF_CHANGED_EVENT')"
unset STUB_BASE_TIP STUB_BASE_CHANGES STUB_MERGED_PRS
record '2 0' '--restacked-from is no option' "$(run_raw -R github.com/o/r --restacked-from "$P1" 7) $(gh_calls)"

# Usage errors never reach gh.
record '2 0' 'no -R' "$(run_raw 7) $(gh_calls)"
record '2 0' '-R with no value' "$(run_raw 7 -R) $(gh_calls)"
record '2 0' 'no PR' "$(run_raw -R github.com/o/r) $(gh_calls)"
record '2 0' 'two PRs' "$(run_raw -R github.com/o/r 7 8) $(gh_calls)"
for bad in 0 07 x 7x '7;id' -7 ''; do
	record '2 0' "the PR number '$bad'" "$(run_raw -R github.com/o/r "$bad") $(gh_calls)"
done
for bad in o/r github.com/o github.com/o/r/x 'github.com/o/r;id' -github.com/o/r github.com/-o/r github.com/o/.. ''; do
	record '2 0' "the malformed -R '$bad'" "$(REPO=$bad run) $(gh_calls)"
done

finish
