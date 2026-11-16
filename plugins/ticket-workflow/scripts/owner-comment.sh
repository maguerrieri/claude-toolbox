#!/usr/bin/env bash
# owner-comment.sh — are a GitHub comment's current words the owner's? For the
# default profile's REVIEW_BOT, *The owner's comments*, in
# skills/ticket-workflow/.
#
#   owner-comment.sh <item url>
#
# <item url> is the item's own URL, as GitHub gives it (REST's .html_url,
# GraphQL's .url, a pr-notifier wake event's URL):
#
#   https://<host>/<owner>/<repo>/(pull|issues)/<n>#issuecomment-<id>   a comment
#   https://<host>/<owner>/<repo>/pull/<n>#pullrequestreview-<id>        a review body
#   https://<host>/<owner>/<repo>/pull/<n>#discussion_r<id>              a line comment
#
# Anyone with write access can edit anyone's comment, so its author alone
# doesn't say whose words it holds now. This runs owner-check.sh (beside it,
# with -R the URL's host and repo) on the author and, when someone else last
# edited the item, on that editor too, and exits like owner-check.sh:
#
#   0  owner-check exits 0 for the author, and the item is unedited, last
#      edited by its author, or last edited by a login owner-check also
#      exits 0 for: the owner's words
#   3  owner-check exits 3 for the author (the sessions' own login, an
#      admin), and the item is unedited or last edited by that same login: the
#      caller applies the same-account rule
#   1  anything else, not the owner's words: an author or last editor
#      owner-check rejects, a bot (GraphQL drops a Bot's [bot] suffix, so a
#      Bot editor is never checked by login), an edit whose editor GitHub
#      doesn't name, a failed read, a URL whose item GitHub files under
#      another URL, a usage error
#
# On 0 and 3 it prints the item's text on stdout, from the same read that
# named its last editor. Act on that text, not on a copy read earlier: an edit
# can land between two reads.
#
# REST names no editor, so the editor comes from GraphQL (editor,
# lastEditedAt). Where GraphQL is refused (a cloud session's proxy) or fails,
# an item REST shows was never edited (a comment whose updated_at equals its
# created_at) keeps its author's verdict and prints REST's text, and anything
# else exits 1: an edited comment, and every review body, since REST gives a
# review no updated_at. A comment edited within its first second looks
# unedited there.
#
# Lines on stderr say why (owner-check.sh's own among them). Needs gh and
# owner-check.sh; OWNER_CHECK_GH overrides the gh binary for both (tests).
set -uo pipefail

usage="usage: owner-comment.sh <item url>"
untrusted() {
	echo "owner-comment.sh: $*" >&2
	exit 1
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

[ $# -eq 1 ] || untrusted "$usage"
url=$1

# Groups: 1 host (2 its inner part), 3 owner, 4 repo, 5 pull|issues, 6 number,
# 7 the anchor's kind, 8 its id.
url_re='^https://([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)/(pull|issues)/([1-9][0-9]*)#(issuecomment-|pullrequestreview-|discussion_r)([1-9][0-9]*)$'
[[ $url =~ $url_re ]] || untrusted "'$url' is not a GitHub comment, review or line comment URL"
host=${BASH_REMATCH[1]} owner=${BASH_REMATCH[3]} repo=${BASH_REMATCH[4]}
where=${BASH_REMATCH[5]} number=${BASH_REMATCH[6]} kind=${BASH_REMATCH[7]} id=${BASH_REMATCH[8]}
[ "${#owner}" -le 39 ] || untrusted "'$owner' is not a GitHub owner"
case $repo in . | ..) untrusted "'$repo' is not a repo name" ;; esac
case $kind in
issuecomment-) endpoint=repos/$owner/$repo/issues/comments/$id node_kind=IssueComment ;;
discussion_r) endpoint=repos/$owner/$repo/pulls/comments/$id node_kind=PullRequestReviewComment ;;
pullrequestreview-) endpoint=repos/$owner/$repo/pulls/$number/reviews/$id node_kind=PullRequestReview ;;
esac
[ "$kind" = issuecomment- ] || [ "$where" = pull ] || untrusted "'$url' puts a pull request's item on an issue"

gh_bin=${OWNER_CHECK_GH:-gh}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

owner_check() { # owner_check <login>: owner-check.sh's exit code for it on this repo
	bash "$here/owner-check.sh" -R "$host/$owner/$repo" "$1" </dev/null >/dev/null
}

split() { # split <text>: its first <n> lines into fields[0..n-1], and the rest into rest
	local n=$1 i line
	fields=()
	rest=$2
	for ((i = 0; i < n; i++)); do
		line=${rest%%$'\n'*}
		fields+=("$line")
		if [ "$line" = "$rest" ]; then rest=; else rest=${rest#*$'\n'}; fi
	done
}

# The item by REST: who wrote it, its node id, and when REST says it changed.
# A failed read prints its error body on stdout too, so only the exit status
# says it worked.
rest_out=$("$gh_bin" api "$endpoint" --hostname "$host" --jq \
	'"\(.user.login // "")\n\(.user.type // "")\n\(.node_id // "")\n\(.created_at // "")\n\(.updated_at // "")\n\(.html_url // "")\n\(.body // "")"' \
	</dev/null 2>/dev/null) || untrusted "can't read $url"
split 6 "$rest_out"
author=${fields[0]} author_type=${fields[1]} node_id=${fields[2]}
created=${fields[3]} updated=${fields[4]} html_url=${fields[5]} rest_body=$rest
[ "$(lower "$html_url")" = "$(lower "$url")" ] ||
	untrusted "GitHub files that item under ${html_url:-no URL}, not $url"
[ "$author_type" = User ] && [ -n "$author" ] ||
	untrusted "$url's author ${author:-(none)} is a ${author_type:-deleted account}, not a user"

owner_check "$author"
verdict=$?
case $verdict in
0 | 3) ;;
*) untrusted "$url's author $author isn't the owner" ;;
esac

# Its last editor, with the text that edit left, in one GraphQL read.
gql_out=
node_re='^[A-Za-z0-9_=-]+$'
if [[ $node_id =~ $node_re ]]; then
	gql_out=$("$gh_bin" api graphql --hostname "$host" -f id="$node_id" -f query='query($id:ID!){node(id:$id){__typename
		... on IssueComment{editor{__typename login} lastEditedAt body}
		... on PullRequestReviewComment{editor{__typename login} lastEditedAt body}
		... on PullRequestReview{editor{__typename login} lastEditedAt body}}}' \
		--jq '.data.node | "\(.__typename // "")\n\(.editor.__typename // "")\n\(.editor.login // "")\n\(.lastEditedAt // "")\n\(.body // "")"' \
		</dev/null 2>/dev/null) || gql_out=
fi
split 4 "$gql_out"

if [ "${fields[0]}" != "$node_kind" ]; then
	# No editor to read: only an item REST shows unedited keeps its verdict.
	if [ -n "$created" ] && [ "$created" = "$updated" ]; then
		echo "owner-comment.sh: no editor read for $url, but REST shows it unedited: $author's" >&2
		printf '%s\n' "$rest_body"
		exit "$verdict"
	fi
	untrusted "can't read who last edited $url, and REST can't show it unedited"
fi
editor_type=${fields[1]} editor=${fields[2]} edited_at=${fields[3]} body=$rest

if [ -z "$edited_at" ]; then
	echo "owner-comment.sh: $url is unedited: $author's" >&2
elif [ "$editor_type" != User ] || [ -z "$editor" ]; then
	# No apostrophe inside ${...:-}: bash reads one there as a quote, even
	# within double quotes.
	untrusted "$url was last edited by ${editor:-an unnamed account}, a ${editor_type:-deleted account}, not a user"
elif [ "$(lower "$editor")" = "$(lower "$author")" ]; then
	echo "owner-comment.sh: $url was last edited by its author $author" >&2
else
	owner_check "$editor"
	editor_verdict=$?
	[ "$verdict" = 0 ] && [ "$editor_verdict" = 0 ] ||
		untrusted "$url was last edited by $editor, who isn't the owner"
	echo "owner-comment.sh: $url was last edited by $editor, also the owner" >&2
fi
printf '%s\n' "$body"
exit "$verdict"
