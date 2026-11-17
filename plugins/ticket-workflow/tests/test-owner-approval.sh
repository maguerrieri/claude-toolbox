#!/usr/bin/env bash
# Tests for scripts/owner-approval.sh, which says whether the owner's
# approving review of a PR is a merge grant: exit 0 (it is, with the PR's head
# and each owner approval of it printed as JSON), 1 (anything else), 2 (a
# usage error). owner-check.sh runs for real, and gh is a stub that answers
# each read with JSON and applies the caller's --jq filter with jq:
#   STUB_ME, STUB_PERMS    the sessions' login, and "login=permission ..." pairs
#   STUB_PR_STATE          the PR's REST state (default open)
#   STUB_HEAD              the PR's head SHA (default $head)
#   STUB_REVIEWS           the PR's reviews, a JSON array (see review below)
#   STUB_PR_FAIL, STUB_REVIEWS_FAIL, STUB_GQL_FAIL
#                          set: that read fails (GraphQL as behind the cloud proxy)
#   STUB_NODES             a JSON object keyed by review node id, merged into
#                          the GraphQL node the stub derives from the review
#                          (its state, commit, body, and no edit); null for an
#                          id makes its node null
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
node=
shift 2
while [ $# -gt 0 ]; do
	case $1 in
	--jq) filter=$2; shift 2 ;;
	-f) case $2 in id=*) node=${2#id=} ;; esac; shift 2 ;;
	*) shift ;;
	esac
done
answer() { jq -r "$filter" <<<"$1"; }
case $endpoint in
user) answer "$(jq -n --arg l "${STUB_ME:-}" '{login: $l}')" ;;
repos/*/collaborators/*/permission)
	who=${endpoint%/permission}
	who=$(lower "${who##*/}")
	for pair in ${STUB_PERMS:-}; do
		[ "$(lower "${pair%%=*}")" = "$who" ] && { answer "$(jq -n --arg p "${pair#*=}" '{permission: $p}')"; exit 0; }
	done
	answer '{"permission": "none"}'
	;;
repos/*/pulls/*/reviews\?per_page=100)
	[ -z "${STUB_REVIEWS_FAIL:-}" ] || { echo '{"message": "Not Found"}'; exit 1; }
	answer "${STUB_REVIEWS:-[]}"
	;;
repos/*/pulls/*)
	[ -z "${STUB_PR_FAIL:-}" ] || { echo '{"message": "Not Found"}'; exit 1; }
	answer "$(jq -n --arg s "${STUB_PR_STATE-open}" --arg h "${STUB_HEAD-}" '{state: $s, head: {sha: $h}}')"
	;;
graphql)
	[ -z "${STUB_GQL_FAIL:-}" ] || {
		echo 'HTTP 403: GitHub GraphQL is not available from Claude Code sessions' >&2
		exit 1
	}
	patch=${STUB_NODES:-}
	[ -n "$patch" ] || patch='{}'
	answer "$(jq -n --arg id "$node" --argjson reviews "${STUB_REVIEWS:-[]}" --argjson patch "$patch" '
		($reviews | map(select(.node_id == $id)) | first) as $r
		| if $r == null or ($patch | has($id) and .[$id] == null) then {data: {node: null}} else
		  {data: {node: ({__typename: "PullRequestReview", state: $r.state, commit: {oid: $r.commit_id},
		    editor: null, lastEditedAt: null, userContentEdits: {nodes: []}, body: ($r.body // "")}
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
record 0 'another owner'"'"'s approval of an older commit is left out' \
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
record 1 'a failed PR read' "$(STUB_PR_FAIL=1 STUB_REVIEWS=$(reviews "$approve") run)"
record 1 'a failed reviews read' "$(STUB_REVIEWS_FAIL=1 STUB_REVIEWS=$(reviews "$approve") run)"
record 1 'a head that is not a SHA' "$(STUB_HEAD='1111;id' STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED '1111;id' "$t1")") run)"
STUB_REVIEWS=$(reviews "$(review 11 maguerrieri APPROVED "$old" "$t1")") run >/dev/null
record 1 'stderr says why there is no grant' "$(grep -c "^owner-approval.sh: no grant: .*$old" "$tmp/err")"
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
