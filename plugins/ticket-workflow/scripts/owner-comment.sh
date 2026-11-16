#!/usr/bin/env bash
# owner-comment.sh — are a GitHub comment's current words the owner's? For the
# default profile's REVIEW_BOT, *The owner's comments*, in
# skills/ticket-workflow/.
#
#   owner-comment.sh -R <host>/<owner>/<repo> [--same-account] <item url>
#
# <item url> is the item's own URL, as GitHub gives it (REST's .html_url,
# GraphQL's .url, a pr-notifier wake event's URL):
#
#   https://<host>/<owner>/<repo>/(pull|issues)/<n>#issuecomment-<id>   a comment
#   https://<host>/<owner>/<repo>/pull/<n>#pullrequestreview-<id>        a review body
#   https://<host>/<owner>/<repo>/pull/<n>#discussion_r<id>              a line comment
#
# -R names the repo the caller's PR lives in, host included, and the URL must
# be on it (compared case-insensitively): permissions are checked there, so an
# item from another repo, where someone else may be an admin, is never read.
#
# Anyone with write access can edit anyone's comment, so its author alone
# doesn't say whose words it holds now. This runs owner-check.sh (beside it)
# on the author and, when another login last edited the item, on that editor
# too, and exits like owner-check.sh:
#
#   0  owner-check exits 0 for the author, and the item is unedited, last
#      edited by its author, or last edited by a login owner-check also exits
#      0 for: the owner's words
#   3  owner-check exits 3 for the author (the sessions' own login, an admin),
#      and the item is unedited or last edited by that same login: the caller
#      applies the same-account rule. --same-account, which the caller passes
#      only when its own setup says the sessions post as the owner's account,
#      takes the sessions' own login as exit 3 below admin too (the profile's
#      one exit-1 exception), with the same editor rule
#   1  anything else, not the owner's words: an author or last editor
#      owner-check rejects, a bot (GraphQL drops a Bot's [bot] suffix, so a Bot
#      editor is never checked by login), an edit GitHub names no editor for,
#      an editor that can't be read, a failed read, an item on another repo or
#      that GitHub files under another URL, a usage error
#
# On 0 and 3 it prints the item's text on stdout, from the same read that
# named its last editor. Act on that text, not on a copy read earlier: an edit
# can land between two reads.
#
# REST names no editor, so the editor comes from GraphQL (editor,
# lastEditedAt). Where GraphQL is refused (a cloud session's proxy) or fails,
# every item exits 1: REST's updated_at has one-second resolution, so it can't
# show that an edit made within a comment's first second never happened.
#
# Lines on stderr say why (owner-check.sh's own among them). Needs gh and
# owner-check.sh; OWNER_CHECK_GH overrides the gh binary for both (tests).
set -uo pipefail

usage="usage: owner-comment.sh -R <host>/<owner>/<repo> [--same-account] <item url>"
untrusted() {
	echo "owner-comment.sh: $*" >&2
	exit 1
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

expected= same_account= url= have_url=
while [ $# -gt 0 ]; do
	case $1 in
	-R)
		[ $# -ge 2 ] || untrusted "$usage"
		expected=$2
		shift 2
		;;
	--same-account)
		same_account=1
		shift
		;;
	*)
		[ -z "$have_url" ] || untrusted "$usage"
		url=$1 have_url=1
		shift
		;;
	esac
done
[ -n "$have_url" ] && [ -n "$expected" ] || untrusted "$usage"

host_part='[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?'
owner_part='[A-Za-z0-9][A-Za-z0-9-]*'
repo_part='[A-Za-z0-9._-]+'
repo_re="^($host_part)/($owner_part)/($repo_part)\$"
[[ $expected =~ $repo_re ]] || untrusted "-R '$expected' is not a <host>/<owner>/<repo>"

# Groups: 1 host (2 its inner part), 3 owner, 4 repo, 5 pull|issues, 6 number,
# 7 the anchor's kind, 8 its id.
url_re="^https://($host_part)/($owner_part)/($repo_part)/(pull|issues)/([1-9][0-9]*)#(issuecomment-|pullrequestreview-|discussion_r)([1-9][0-9]*)\$"
[[ $url =~ $url_re ]] || untrusted "'$url' is not a GitHub comment, review or line comment URL"
host=${BASH_REMATCH[1]} owner=${BASH_REMATCH[3]} repo=${BASH_REMATCH[4]}
where=${BASH_REMATCH[5]} number=${BASH_REMATCH[6]} kind=${BASH_REMATCH[7]} id=${BASH_REMATCH[8]}
[ "$(lower "$host/$owner/$repo")" = "$(lower "$expected")" ] ||
	untrusted "'$url' is not on $expected"
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

split() { # split <n> <text>: its first <n> lines into fields[0..n-1], and the rest into rest
	local n=$1 i line
	fields=()
	rest=$2
	for ((i = 0; i < n; i++)); do
		line=${rest%%$'\n'*}
		fields+=("$line")
		if [ "$line" = "$rest" ]; then rest=; else rest=${rest#*$'\n'}; fi
	done
}

# The item by REST: who wrote it (with an app's [bot] suffix and its type,
# which GraphQL drops), and its node id. A failed read prints its error body
# on stdout too, so only the exit status says it worked.
rest_out=$("$gh_bin" api "$endpoint" --hostname "$host" --jq \
	'"\(.user.login // "")\n\(.user.type // "")\n\(.node_id // "")\n\(.html_url // "")"' \
	</dev/null 2>/dev/null) || untrusted "can't read $url"
split 4 "$rest_out"
author=${fields[0]} author_type=${fields[1]} node_id=${fields[2]} html_url=${fields[3]}
[ "$(lower "$html_url")" = "$(lower "$url")" ] ||
	untrusted "GitHub files that item under ${html_url:-no URL}, not $url"
[ "$author_type" = User ] && [ -n "$author" ] ||
	untrusted "$url's author ${author:-(none)} is a ${author_type:-deleted account}, not a user"

owner_check "$author"
verdict=$?
if [ "$verdict" = 1 ] && [ -n "$same_account" ]; then
	me=$("$gh_bin" api user --hostname "$host" --jq .login </dev/null 2>/dev/null) || me=
	[ -n "$me" ] && [ "$(lower "$me")" = "$(lower "$author")" ] && {
		verdict=3
		echo "owner-comment.sh: $author is the sessions' own login, which --same-account says is the owner's account" >&2
	}
fi
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
[ "${fields[0]}" = "$node_kind" ] ||
	untrusted "can't read who last edited $url (GraphQL refused or failed), so it isn't read as the owner's"
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
