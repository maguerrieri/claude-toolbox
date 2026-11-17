#!/usr/bin/env bash
# owner-approval.sh — is the owner's approving review of a PR a merge grant?
# For the FINISH intro's third grant form, in skills/ticket-workflow/
# phases/finish.md.
#
#   owner-approval.sh -R <host>/<owner>/<repo> <pr number>
#
# -R names the PR's repo, host included, so every read, owner-check.sh's
# included, goes to that repo on that host. Reads the PR and every page of its
# reviews by REST. A review is decisive when its state is APPROVED,
# CHANGES_REQUESTED or DISMISSED (COMMENTED and PENDING never are), and
# reviews are ordered by submission time, then id. An owner is a login
# owner-check.sh (beside it) exits 0 for: an admin on the repo, while the
# sessions' own login isn't one. Exits:
#
#   0  a grant: the PR is open, and the approval is the newest APPROVED review
#      of the PR's head commit by an owner, and:
#      - no CHANGES_REQUESTED or DISMISSED review, by anyone, is newer than it;
#      - no login's latest decisive review is CHANGES_REQUESTED, from before
#        it either: the owner's, a collaborator's, a bot's or a deleted
#        account's;
#      - its body, and each line comment it carries, is unedited, last edited
#        by its author, or last edited by another owner, with the newest entry
#        of its edit history agreeing (notifier.md's rule for an edited item,
#        which #301's owner-comment.sh puts in a script), read in one GraphQL
#        read that also re-reads the review's state and commit, which must
#        still be APPROVED and the head.
#      It prints one JSON object on stdout: {"pr", "head", "reviewer", "url",
#      "submitted_at", "body", "comments": [{"path", "url", "body"}]}, the
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
# anyone with write access can do), and nothing changes its commit. A
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

owner_check() { # owner_check <login>: owner-check.sh's verdict on it, on this repo
	bash "$here/owner-check.sh" -R "$host/$owner/$repo" "$1" </dev/null >/dev/null 2>&1
}

# The PR: open, and its head. A failed read prints its error body on stdout
# too, so only the exit status says it worked.
pr_out=$("$gh_bin" api "repos/$owner/$repo/pulls/$pr" --hostname "$host" --jq \
	'"\(.state // "")\n\(.head.sha // "")"' </dev/null 2>/dev/null) || no_grant "can't read PR #$pr"
{ IFS= read -r pr_state; IFS= read -r head; } <<<"$pr_out"
[ "$pr_state" = open ] || no_grant "PR #$pr is ${pr_state:-unreadable}, not open"
[[ $head =~ ^[0-9a-f]{40}$ ]] || no_grant "PR #$pr's head '${head}' is not a commit SHA"

# Every page of its decisive reviews, one line each (gh applies --jq to each
# page), led by the lowercased login (a deleted account's review by its own
# id, so no two deleted accounts share one), then sorted oldest first:
# ISO-8601 UTC times sort as strings, and the id breaks a tie.
decisive=$("$gh_bin" api "repos/$owner/$repo/pulls/$pr/reviews?per_page=100" --hostname "$host" --paginate --jq \
	'.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
		| ((.user.login // "") | ascii_downcase) as $key
		| "\(if $key == "" then "-\(.id)" else $key end)\u001f\(.submitted_at // "")\u001f\(.id // 0)\u001f\(.user.login // "")\u001f\(.user.type // "")\u001f\(.state)\u001f\(.commit_id // "")\u001f\(.node_id // "")\u001f\(.html_url // "")"' \
	</dev/null 2>/dev/null) || no_grant "can't read PR #$pr's reviews"
sorted=$(printf '%s\n' "$decisive" | LC_ALL=C sort -t "$sep" -k2,2 -k3,3n)
newest_first=$(printf '%s\n' "$sorted" | awk 'NF { line[++n] = $0 } END { for (i = n; i > 0; i--) print line[i] }')
latest=$(printf '%s\n' "$sorted" | awk -F "$sep" 'NF > 1 { last[$1] = $0; order[$1] = NR } END { for (k in last) print order[k] FS last[k] }' |
	LC_ALL=C sort -t "$sep" -k1,1n | cut -d "$sep" -f 2-)

# The newest approval of the head by an owner.
approval= reasons= rejected=" "
while IFS="$sep" read -r key at id login type state commit node url; do
	[ "$state" = APPROVED ] && [ "$commit" = "$head" ] || continue
	case $rejected in *" $key "*) continue ;; esac
	if [ "$type" != User ] || [ -z "$login" ]; then
		reasons+="the approval by ${login:-a deleted account} is not a user's ($url)$nl"
	elif owner_check "$login"; then
		approval="$key$sep$at$sep$id$sep$login$sep$type$sep$state$sep$commit$sep$node$sep$url"
		break
	else
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
[ "$node_commit" = "$head" ] || no_grant "$url now reads commit ${node_commit:-none}, not the head $head"
edit_check "$url" "$editor_type" "$editor" "$edited_at" "$newest_at" "$newest_type" "$newest_editor"
[ -n "$body_json" ] && [ -n "$comments_json" ] || no_grant "can't read $url's body and line comments"
[[ $comments_total =~ ^[0-9]+$ ]] && [ "$comments_total" = "$comments_read" ] ||
	no_grant "$url carries ${comments_total:-an unknown number of} line comments, more than one read shows"
while IFS="$sep" read -r c_url c_editor_type c_editor c_edited_at c_newest_at c_newest_type c_newest_editor; do
	[ -n "$c_url" ] || continue
	edit_check "$c_url" "$c_editor_type" "$c_editor" "$c_edited_at" "$c_newest_at" "$c_newest_type" "$c_newest_editor"
done <<<"$edited_comments"

printf '{"pr":%s,"head":"%s","reviewer":"%s","url":"%s","submitted_at":"%s","body":%s,"comments":%s}\n' \
	"$pr" "$head" "$login" "$url" "$at" "$body_json" "$comments_json"
exit 0
