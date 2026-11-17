#!/usr/bin/env bash
# owner-approval.sh — is the owner's approving review of a PR a merge grant?
# For the FINISH intro's third grant form, in skills/ticket-workflow/
# phases/finish.md.
#
#   owner-approval.sh -R <host>/<owner>/<repo> <pr number>
#
# -R names the PR's repo, host included, so every read, owner-check.sh's
# included, goes to that repo on that host. An approval covers the commit it
# approved, the PR's head, or an earlier head whose changes the head still
# makes and nothing more, as the owner decided on PR #343 ("If the diff is the
# same I think the approval should stand"): a restack, say, or a reworded
# commit. GitHub names every commit involved, never the caller or a local ref:
# the head, the base branch's tip (git/ref), and the approved commit's base.
#   - No base change since the approval: its merge-base with the base's tip,
#     so a base that moved on is followed.
#   - One base change since it, away from a branch a merged PR had as its head
#     and into the base it merged to: that PR's last head, which must be an
#     ancestor of the approved commit (a parent landed).
#   - Anything else, or a force-push of the base since the approval (which
#     GitHub records on the PR): nothing carries.
# What the approved commit changed since that base, merged onto the head's
# own base (git merge-tree --write-tree --merge-base), must give exactly the
# head's tree: the same changes, in the same places, with nothing added. A
# merge that conflicts, or a git too old for merge-tree's --merge-base
# (before 2.40), carries nothing. Those reads are in the caller's checkout,
# which must hold the commits (fetch them first); a commit missing there
# carries nothing. Reads the PR and every page of its
# reviews by REST. A review is decisive when its state is APPROVED,
# CHANGES_REQUESTED or DISMISSED (COMMENTED and PENDING never are), and
# reviews are ordered by submission time, then id. An owner is a login
# owner-check.sh (beside it) exits 0 for: an admin on the repo, while the
# sessions' own login isn't one. Exits:
#
#   0  a grant: the PR is open and not a draft, and the approval is the newest APPROVED review
#      by an owner that covers the PR's head (above), and:
#      - no CHANGES_REQUESTED or DISMISSED review, by anyone, is newer than it;
#      - no login's latest decisive review is CHANGES_REQUESTED, from before
#        it either: the owner's, a collaborator's, a bot's or a deleted
#        account's;
#      - its body, and each line comment it carries, is unedited, last edited
#        by its author, or last edited by another owner, with the newest entry
#        of its edit history agreeing (notifier.md's rule for an edited item,
#        which #301's owner-comment.sh puts in a script), read in one GraphQL
#        read that also re-reads the review's state and commit, which must
#        still be APPROVED and the commit the REST read named.
#      It prints one JSON object on stdout: {"pr", "head", "approved" (the
#      commit approved: the head, or an earlier one whose diff is the same),
#      "reviewer", "url", "submitted_at", "body", "comments": [{"path", "url",
#      "body"}]}, the
#      comments being the review's own line comments. The caller reads the body
#      and every comment before merging: one that asks to hold, or for a change
#      first, is no grant (the FINISH intro).
#   1  no grant, and nothing on stdout: no owner approval of the head (none,
#      one of an older commit, one by a login below admin or by the sessions'
#      own), a request for changes or a dismissal after it, a request for
#      changes still standing, an approval body another login edited, a
#      closed or merged PR, or any read that fails. Sessions posting as the
#      owner's account (owner-check.sh's exit 3) always land here, since
#      GitHub never lets a PR's author approve it. So does a cloud session,
#      whose proxy refuses GraphQL, which names the editor. One line on stderr
#      per reason, each starting "owner-approval.sh: no grant:".
#   2  a usage error (no -R or a malformed one, no PR number or two): a wrong
#      call, never a verdict on the PR
#
# Why the body's editor matters: anyone with write access can edit anyone's
# review body (GraphQL's updatePullRequestReview, which changes the body and
# nothing else; checked on 2026-11-16, when the sessions' own write login read
# viewerCanUpdate true on the owner's approval of maguerrieri/config#108), so
# an edit could strip a hold from it. A review's state changes after
# submission only by dismissal (dismissPullRequestReview, to DISMISSED, which
# anyone with write access can do), nothing changes its commit, and nobody can
# delete it: deletePullRequestReview on a submitted review answers "Can not
# delete a non-pending pull request review" (checked on PR #343, 2026-11-16).
# Its edit history lists newest first, the newest entry's editedAt equal to
# lastEditedAt, and the original last (checked on that PR's probe review too). A
# dismissal keeps the review's submission time, so a dismissed review newer
# than the approval stops the grant whatever it was: dismissing a request for
# changes made after the approval never clears the way for it. One made
# before the approval and dismissed since doesn't stop it, since the owner
# approved after it. What this can't see: a comment deleted since, a line
# comment of the approval's own included, which anyone with write access can
# delete and which leaves nothing to read. Those rules bind the sessions, as
# the profile's raise rules do: none deletes the owner's words.
#
# The grant covers the head printed, and only while it is still the head: a
# caller merges with gh pr merge --match-head-commit <head>, so a push after
# this read is refused rather than landed. Needs gh and owner-check.sh;
# OWNER_CHECK_GH overrides the gh binary for both (tests). Runs under macOS's
# /bin/bash 3.2 too, so no associative arrays.
set -uo pipefail

usage="usage: owner-approval.sh -R <host>/<owner>/<repo> <pr number>"
usage_error() {
	echo "owner-approval.sh: $*" >&2
	exit 2
}
no_grant() {
	echo "owner-approval.sh: no grant: $*" >&2
	exit 1
}
say_reasons() { # say_reasons <newline-ended reasons>: one no-grant line each, then exit 1
	printf '%s' "$1" | while IFS= read -r reason; do
		echo "owner-approval.sh: no grant: $reason" >&2
	done
	exit 1
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

expected= pr= have_pr=
while [ $# -gt 0 ]; do
	case $1 in
	-R)
		[ $# -ge 2 ] || usage_error "$usage"
		expected=$2
		shift 2
		;;
	*)
		[ -z "$have_pr" ] || usage_error "$usage"
		pr=$1 have_pr=1
		shift
		;;
	esac
done
[ -n "$have_pr" ] && [ -n "$expected" ] || usage_error "$usage"

host_part='[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?'
owner_part='[A-Za-z0-9][A-Za-z0-9-]*'
repo_part='[A-Za-z0-9._-]+'
repo_re="^($host_part)/($owner_part)/($repo_part)\$"
[[ $expected =~ $repo_re ]] || usage_error "-R '$expected' is not a <host>/<owner>/<repo>"
host=${BASH_REMATCH[1]} owner=${BASH_REMATCH[3]} repo=${BASH_REMATCH[4]}
[ "${#owner}" -le 39 ] || usage_error "'$owner' is not a GitHub owner"
case $repo in . | ..) usage_error "'$repo' is not a repo name" ;; esac
[[ $pr =~ ^[1-9][0-9]*$ ]] || usage_error "'$pr' is not a PR number"

gh_bin=${OWNER_CHECK_GH:-gh}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sep=$'\x1f' # the jq filters' \u001f: in no login, state, SHA, time or URL, and not whitespace, so read keeps empty fields
nl=$'\n'

owner_check() { # owner_check <login>: owner-check.sh's verdict on it, on this repo, its stderr in owner_err
	owner_err=$(bash "$here/owner-check.sh" -R "$host/$owner/$repo" "$1" </dev/null 2>&1 >/dev/null)
}
owner_err=

# The PR: open, and its head. A failed read prints its error body on stdout
# too, so only the exit status says it worked.
pr_out=$("$gh_bin" api "repos/$owner/$repo/pulls/$pr" --hostname "$host" --jq \
	'"\(.state // "")\n\(.head.sha // "")\n\(.draft)\n\(.base.ref // "")"' </dev/null 2>/dev/null) || no_grant "can't read PR #$pr"
{ IFS= read -r pr_state; IFS= read -r head; IFS= read -r pr_draft; IFS= read -r base_ref; } <<<"$pr_out"
[ "$pr_state" = open ] || no_grant "PR #$pr is ${pr_state:-unreadable}, not open"
[ "$pr_draft" = false ] || no_grant "PR #$pr is a draft (draft: ${pr_draft:-unreadable})"
[[ $head =~ ^[0-9a-f]{40}$ ]] || no_grant "PR #$pr's head '${head}' is not a commit SHA"

# Every page of its decisive reviews, one line each (gh applies --jq to each
# page), led by the lowercased login (a deleted account's review, which REST
# gives no user or GitHub's shared ghost user, by its own id, so no two
# deleted accounts share one), then sorted oldest first:
# ISO-8601 UTC times sort as strings, and the id breaks a tie.
decisive=$("$gh_bin" api "repos/$owner/$repo/pulls/$pr/reviews?per_page=100" --hostname "$host" --paginate --jq \
	'.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
		| ((.user.login // "") | ascii_downcase) as $key
		| "\(if $key == "" or $key == "ghost" then "-\(.id)" else $key end)\u001f\(.submitted_at // "")\u001f\(.id // 0)\u001f\(.user.login // "")\u001f\(.user.type // "")\u001f\(.state)\u001f\(.commit_id // "")\u001f\(.node_id // "")\u001f\(.html_url // "")"' \
	</dev/null 2>/dev/null) || no_grant "can't read PR #$pr's reviews"
sorted=$(printf '%s\n' "$decisive" | LC_ALL=C sort -t "$sep" -k2,2 -k3,3n)
newest_first=$(printf '%s\n' "$sorted" | awk 'NF { line[++n] = $0 } END { for (i = n; i > 0; i--) print line[i] }')
latest=$(printf '%s\n' "$sorted" | awk -F "$sep" 'NF > 1 { last[$1] = $0; order[$1] = NR } END { for (k in last) print order[k] FS last[k] }' |
	LC_ALL=C sort -t "$sep" -k1,1n | cut -d "$sep" -f 2-)

# Whether an approval of an earlier head covers this one: the head makes the
# same changes and nothing more (the header says how). Only commits GitHub
# names are used; this checkout supplies their objects.
sha_re='^[0-9a-f]{40}$'
reasons= base_tip= checked=" " same=" "
have() { # have <sha>: the commit is in this checkout
	git cat-file -e "$1^{commit}" 2>/dev/null
}
replays() { # replays <old base> <approved>: what <approved> changed since <old base>, merged onto the head's own base, is the head's tree
	local nb tree
	[ "$1" != "$2" ] && git merge-base --is-ancestor "$1" "$2" 2>/dev/null || return 1
	nb=$(git merge-base "$base_tip" "$head" 2>/dev/null) || return 1
	tree=$(git merge-tree --write-tree --no-messages --merge-base="$1" "$nb" "$2" 2>/dev/null) || return 1
	tree=$(printf '%s\n' "$tree" | head -n 1)
	[[ $tree =~ $sha_re ]] && [ "$tree" = "$(git rev-parse --verify --quiet "$head^{tree}" 2>/dev/null)" ]
}
old_base() { # old_base <approval time> <approved>: the approved commit's base, as GitHub records it, or fail
	local events changes count prev cur at merged
	# The PR's base changes and base force-pushes since the approval.
	events=$("$gh_bin" api graphql --hostname "$host" -f owner="$owner" -f repo="$repo" -F pr="$pr" -f query='
		query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){
		timelineItems(itemTypes:[BASE_REF_CHANGED_EVENT,BASE_REF_FORCE_PUSHED_EVENT],last:50){nodes{__typename
		... on BaseRefChangedEvent{previousRefName currentRefName createdAt} ... on BaseRefForcePushedEvent{createdAt}}}}}}' \
		--jq '.data.repository.pullRequest.timelineItems.nodes[] | "\(.__typename // "")\u001f\(.createdAt // "")\u001f\(.previousRefName // "")\u001f\(.currentRefName // "")"' \
		</dev/null 2>/dev/null) || return 1
	events=$(printf '%s\n' "$events" | awk -F "$sep" -v at="$1" 'NF == 4 && $2 > at')
	# A base rewritten since the approval moves what its merge-base finds.
	printf '%s\n' "$events" | grep -q "^BaseRefForcePushedEvent$sep" && return 1
	changes=$(printf '%s\n' "$events" | grep "^BaseRefChangedEvent$sep" | cut -d "$sep" -f 2-)
	count=$(printf '%s' "$changes" | grep -c . || true)
	if [ "$count" = 0 ]; then
		git merge-base "$base_tip" "$2" 2>/dev/null
		return
	fi
	[ "$count" = 1 ] || return 1
	IFS="$sep" read -r at prev cur <<<"$changes"
	[ "$cur" = "$base_ref" ] && [[ $prev =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
	# The PR that had the old base as its head and merged into the new one before the change.
	merged=$("$gh_bin" api graphql --hostname "$host" -f owner="$owner" -f repo="$repo" -f head="$prev" -f query='
		query($owner:String!,$repo:String!,$head:String!){repository(owner:$owner,name:$repo){
		pullRequests(headRefName:$head,states:[MERGED],last:20){nodes{headRefOid baseRefName mergedAt}}}}' \
		--jq '.data.repository.pullRequests.nodes[] | "\(.headRefOid // "")\u001f\(.baseRefName // "")\u001f\(.mergedAt // "")"' \
		</dev/null 2>/dev/null) || return 1
	merged=$(printf '%s\n' "$merged" | awk -F "$sep" -v base="$cur" -v at="$at" 'NF == 3 && $2 == base && $3 != "" && $3 <= at { print $1 }')
	[ "$(printf '%s' "$merged" | grep -c . || true)" = 1 ] && [[ $merged =~ $sha_re ]] || return 1
	printf '%s' "$merged"
}
covers() { # covers <commit> <approval time>: an approval of it covers the head
	[ "$1" = "$head" ] && return 0
	[[ $1 =~ $sha_re ]] || return 1
	case $same in *" $1@$2 "*) return 0 ;; esac
	case $checked in *" $1@$2 "*) return 1 ;; esac
	checked+="$1@$2 "
	if [ -z "$base_tip" ]; then
		# The base branch's tip, read once.
		if [[ $base_ref =~ ^[A-Za-z0-9._/-]+$ ]] &&
			base_tip=$("$gh_bin" api "repos/$owner/$repo/git/ref/heads/$base_ref" --hostname "$host" \
				--jq '.object.sha // ""' </dev/null 2>/dev/null) && [[ $base_tip =~ $sha_re ]] &&
			have "$base_tip" && have "$head"; then
			:
		else
			base_tip=none
			reasons+="this checkout lacks the head or ${base_ref:-its base}'s tip (fetch both), so no earlier approval carries$nl"
		fi
	fi
	[ "$base_tip" != none ] || return 1
	local base
	have "$1" && base=$(old_base "$2" "$1") && [[ $base =~ $sha_re ]] && replays "$base" "$1" || return 1
	same+="$1@$2 "
}

# The newest approval covering the head by an owner.
approval= rejected=" "
while IFS="$sep" read -r key at id login type state commit node url; do
	[ "$state" = APPROVED ] && covers "$commit" "$at" || continue
	case $rejected in *" $key "*) continue ;; esac
	if [ "$type" != User ] || [ -z "$login" ] || [ "$(lower "$login")" = ghost ]; then
		reasons+="the approval by ${login:-a deleted account} is not a user's ($url)$nl"
	elif owner_check "$login"; then
		approval="$key$sep$at$sep$id$sep$login$sep$type$sep$state$sep$commit$sep$node$sep$url"
		break
	else
		# owner-check.sh exits 1 for a failed read too. Only a read that worked
		# may pass over this approval for an older one: else the newest
		# approval, whose body may hold, goes unread.
		case $owner_err in *"can't read"*)
			no_grant "can't read whether $login, who approved the head, is the owner ($url): ${owner_err#owner-check.sh: }"
			;;
		esac
		reasons+="$login approved the head but isn't the owner by owner-check.sh ($url)$nl"
	fi
	rejected+="$key "
done <<<"$newest_first"
if [ -z "$approval" ]; then
	while IFS="$sep" read -r key at id login type state commit node url; do
		[ -n "$key" ] || continue
		case $state in
		CHANGES_REQUESTED) reasons+="changes requested by ${login:-a deleted account} still stand ($url)$nl" ;;
		DISMISSED) reasons+="the latest decisive review by ${login:-a deleted account} was dismissed ($url)$nl" ;;
		APPROVED) [ "$commit" = "$head" ] || reasons+="${login:-a deleted account} approved ${commit:-no commit}, not the head $head ($url)$nl" ;;
		esac
	done <<<"$latest"
	[ -n "$reasons" ] || reasons="PR #$pr has no approving review$nl"
	say_reasons "$reasons"
fi
IFS="$sep" read -r key at id login type state commit node url <<<"$approval"

# Nothing decisive since it: a request for changes, or a dismissal, by anyone.
# And no request for changes still standing from before it.
blocks= after=" "
while IFS="$sep" read -r r_key r_at r_id r_login r_type r_state r_commit r_node r_url; do
	case $r_state in CHANGES_REQUESTED | DISMISSED) ;; *) continue ;; esac
	# After it, or not provably before it (no time, or its time and an id that isn't lower).
	if [ -z "$r_at" ] || [[ $r_at > $at ]] ||
		{ [ "$r_at" = "$at" ] && ! { [[ $r_id =~ ^[0-9]+$ ]] && [[ $id =~ ^[0-9]+$ ]] && [ "$r_id" -lt "$id" ]; }; }; then
		blocks+="${r_login:-a deleted account}'s review after the approval was $(lower "$r_state" | tr _ ' ') ($r_url)$nl"
		after+="$r_id "
	fi
done <<<"$sorted"
while IFS="$sep" read -r r_key r_at r_id r_login r_type r_state r_commit r_node r_url; do
	[ "$r_state" = CHANGES_REQUESTED ] || continue
	case $after in *" $r_id "*) continue ;; esac # said once already, above
	blocks+="changes requested by ${r_login:-a deleted account} still stand ($r_url)$nl"
done <<<"$latest"
[ -z "$blocks" ] || say_reasons "$blocks"

# What goes into the JSON below unquoted or unescaped must be in GitHub's own
# forms (the login already is: owner-check.sh accepted it).
[[ $id =~ ^[1-9][0-9]*$ ]] && [[ $at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
	no_grant "review '$id' has no id or submission time in GitHub's form"
[ "$(lower "$url")" = "$(lower "https://$host/$owner/$repo/pull/$pr#pullrequestreview-$id")" ] ||
	no_grant "GitHub files review $id under ${url:-no URL}, not on PR #$pr"
[[ $node =~ ^[A-Za-z0-9_=-]+$ ]] || no_grant "$url has no readable node id"

# edit_check <what> <editor type> <editor> <edited at> <newest at> <newest type> <newest editor>:
# the text is its author's while unedited, last edited by its author, or last
# edited by another owner, with the newest entry of its edit history agreeing.
edit_check() {
	[ -n "$4" ] || return 0
	if [ "$2" != User ] || [ -z "$3" ]; then
		no_grant "$1 was last edited by ${3:-an unnamed account}, a ${2:-deleted account}, not a user"
	elif [ "$5" != "$4" ] || [ "$6" != "$2" ] || [ "$(lower "$7")" != "$(lower "$3")" ]; then
		no_grant "$1's edit history (newest: ${7:-none} at ${5:-no time}) disagrees with its last editor $3 at $4"
	elif [ "$(lower "$3")" != "$(lower "$login")" ] && ! owner_check "$3"; then
		no_grant "$1 was last edited by $3, who isn't the owner"
	fi
}

# Its state, commit, body and the line comments it carries, each text with
# its last editor, in one GraphQL read. The fixed lines come first (the body
# and the comments as JSON on one line each), then one line per edited
# comment.
edits='editor{__typename login} lastEditedAt userContentEdits(first:1){nodes{editedAt editor{__typename login}}}'
fields="state commit{oid} $edits body comments(first:100){totalCount nodes{url path body $edits}}"
gql_out=$("$gh_bin" api graphql --hostname "$host" -f id="$node" -f query="query(\$id:ID!){node(id:\$id){__typename ... on PullRequestReview{$fields}}}" \
	--jq 'def edit: (.userContentEdits.nodes[0] // {}) as $newest
			| [.editor.__typename, .editor.login, .lastEditedAt, $newest.editedAt, $newest.editor.__typename, $newest.editor.login] | map(. // "");
		.data.node | (.comments.nodes // []) as $comments
		| "\(.__typename // "")\n\(.state // "")\n\(.commit.oid // "")\n\(edit | join("\n"))\n\(.body // "" | tojson)\n\(.comments.totalCount // -1)\n\($comments | length)\n\($comments | map({path, url, body}) | tojson)",
		  ($comments[] | select(.lastEditedAt != null) | ([.url // ""] + edit) | join("\u001f"))' \
	</dev/null 2>/dev/null) || gql_out=
{
	IFS= read -r node_type
	IFS= read -r node_state
	IFS= read -r node_commit
	IFS= read -r editor_type
	IFS= read -r editor
	IFS= read -r edited_at
	IFS= read -r newest_at
	IFS= read -r newest_type
	IFS= read -r newest_editor
	IFS= read -r body_json
	IFS= read -r comments_total
	IFS= read -r comments_read
	IFS= read -r comments_json
	edited_comments=$(cat)
} <<<"$gql_out"
[ "$node_type" = PullRequestReview ] ||
	no_grant "can't read who last edited $url (GraphQL refused or failed), so its body isn't read as the owner's"
[ "$node_state" = APPROVED ] || no_grant "$url now reads ${node_state:-no state}, not APPROVED"
[ "$node_commit" = "$commit" ] || no_grant "$url now reads commit ${node_commit:-none}, not the $commit it approved"
edit_check "$url" "$editor_type" "$editor" "$edited_at" "$newest_at" "$newest_type" "$newest_editor"
[ -n "$body_json" ] && [ -n "$comments_json" ] || no_grant "can't read $url's body and line comments"
[[ $comments_total =~ ^[0-9]+$ ]] && [ "$comments_total" = "$comments_read" ] ||
	no_grant "$url carries ${comments_total:-an unknown number of} line comments, more than one read shows"
while IFS="$sep" read -r c_url c_editor_type c_editor c_edited_at c_newest_at c_newest_type c_newest_editor; do
	[ -n "$c_url" ] || continue
	edit_check "$c_url" "$c_editor_type" "$c_editor" "$c_edited_at" "$c_newest_at" "$c_newest_type" "$c_newest_editor"
done <<<"$edited_comments"

printf '{"pr":%s,"head":"%s","approved":"%s","reviewer":"%s","url":"%s","submitted_at":"%s","body":%s,"comments":%s}\n' \
	"$pr" "$head" "$commit" "$login" "$url" "$at" "$body_json" "$comments_json"
exit 0
