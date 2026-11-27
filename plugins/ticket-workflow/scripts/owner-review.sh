#!/usr/bin/env bash
# owner-review.sh — request the owner's review on this session's PR when it
# hands back, or clear that request when the session goes back to work, so the
# owner's GitHub review queue lists exactly the PRs that are waiting on them.
# START Step 9 in skills/ticket-workflow/SKILL.md says when each runs.
#
#   owner-review.sh request <pr> [--owner <login>|none]
#   owner-review.sh clear <pr> [--owner <login>|none]
#
# <pr> is the PR's URL (https://<host>/<owner>/<repo>/pull/<n>, as gh pr
# create prints it) or <owner>/<repo>#<n> on github.com.
#
# The owner is one login, picked in this order:
#   - --owner <login>, which the caller passes from the repo's Owner review:
#     line (SKILL.md Step 0); --owner none turns both subcommands off
#   - the repo's owner, when a user owns the repo
#   - an organization's repo: its one admin collaborator, the sessions' own
#     login aside. With several, nobody: any one of them might not be the
#     owner, so the line says which, and the output names them.
# Whichever it is, owner-check.sh (beside it) must exit 0 for it: an admin on
# the repo, while the sessions' own login isn't one, the same test that makes
# a comment the owner's. clear picks the owner the same way, and removes the
# request only when it is pending from that login, so it never touches a
# reviewer a person asked for.
#
# Prints one line on stdout and exits:
#
#   0  done, or nothing to do: requested, or already pending; cleared, or
#      nothing pending; the sessions post as the owner's account
#      (owner-check.sh's exit 3), whom GitHub won't let review their own PR;
#      the owner opened the PR, or already reviewed its head (any reply
#      reaches them anyway); no single owner (several admins, or none); the
#      PR isn't open; --owner none
#   1  a read or the request failed, owner-check.sh is missing or didn't run,
#      or --owner names a login that isn't the owner by owner-check.sh; the
#      line says why
#   2  usage error
#
# A request is a convenience the hand-back reports, never something a step
# waits on, so a caller carries on whatever this exits. Every call is REST
# (gh api), so a cloud session, whose proxy refuses GraphQL, runs it as is.
# Needs gh and owner-check.sh. OWNER_CHECK_GH overrides the gh binary for both
# (tests). Runs under macOS's /bin/bash 3.2.
set -uo pipefail

me_name=owner-review
usage() {
	echo "usage: owner-review.sh request|clear <pr> [--owner <login>|none]" >&2
	exit 2
}
say() { printf '%s: %s\n' "$me_name" "$*"; }
stop() { # stop <exit code> <line>
	say "$2"
	exit "$1"
}

login_re='^[A-Za-z0-9][A-Za-z0-9-]*$'
valid_login() { # a GitHub login's characters: alphanumerics and hyphens, not leading, at most 39
	[ "${#1}" -le 39 ] && [[ $1 =~ $login_re ]]
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
has_login() { # has_login "<space-separated logins>" <login>: case-insensitively
	local l want
	want=$(lower "$2")
	for l in $1; do
		[ "$(lower "$l")" = "$want" ] && return 0
	done
	return 1
}
one_line() { printf '%s' "$1" | tr '\n' ' ' | sed -e 's/ *$//'; }

cmd=${1:-}
case $cmd in request | clear) ;; *) usage ;; esac
shift
pr=
owner=
have_owner=
while [ $# -gt 0 ]; do
	case $1 in
	--owner)
		[ $# -ge 2 ] && [ -z "$have_owner" ] || usage
		owner=$2
		have_owner=1
		shift 2
		;;
	-* | '') usage ;;
	*)
		[ -z "$pr" ] || usage
		pr=$1
		shift
		;;
	esac
done
[ -n "$pr" ] || usage
if [ -n "$have_owner" ] && [ "$owner" != none ] && ! valid_login "$owner"; then
	echo "$me_name: '$owner' isn't a GitHub login (--owner takes a login or none)" >&2
	usage
fi

url_re='^https://([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$'
ref_re='^([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)#([0-9]+)$'
if [[ $pr =~ $url_re ]]; then
	host=${BASH_REMATCH[1]} repo_owner=${BASH_REMATCH[3]} repo_name=${BASH_REMATCH[4]} number=${BASH_REMATCH[5]}
elif [[ $pr =~ $ref_re ]]; then
	host=github.com repo_owner=${BASH_REMATCH[1]} repo_name=${BASH_REMATCH[2]} number=${BASH_REMATCH[3]}
else
	echo "$me_name: '$pr' isn't a PR URL or <owner>/<repo>#<n>" >&2
	usage
fi
if ! valid_login "$repo_owner" || [ "$repo_name" = . ] || [ "$repo_name" = .. ]; then
	echo "$me_name: '$pr' names no repo" >&2
	usage
fi
repo="$repo_owner/$repo_name"
ref="$repo#$number"

if [ "$cmd" = request ]; then
	not="the owner's review wasn't requested on $ref"
else
	not="no review request was cleared on $ref"
fi
[ "$owner" != none ] || stop 0 "$not: the repo's Owner review line says none"

gh_bin=${OWNER_CHECK_GH:-gh}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -f "$here/owner-check.sh" ] || stop 1 "$not: owner-check.sh isn't beside this script, in $here"

api() { # api <endpoint> [gh api flags...]: one REST call on the PR's host, its stdout in api_out and stderr in api_err
	# Called bare, never in $(...), so both variables reach the caller.
	local endpoint=$1 err_file rc
	shift
	api_out= api_err=
	err_file=$(mktemp "${TMPDIR:-/tmp}/owner-review.XXXXXX") || {
		api_err="can't make a temp file"
		return 1
	}
	# </dev/null: gh never needs stdin here.
	api_out=$("$gh_bin" api "$endpoint" --hostname "$host" "$@" </dev/null 2>"$err_file")
	rc=$?
	api_err=$(one_line "$(cat "$err_file")")
	rm -f "$err_file"
	# A failed read prints its error body on stdout too, so only the exit
	# status says it worked.
	[ "$rc" -eq 0 ] || {
		api_out=
		return 1
	}
}

owner_check() { # owner_check <login>: owner-check.sh's verdict on it (0, 1 or 3), its reason in owner_err
	local rc
	owner_err=$(bash "$here/owner-check.sh" -R "$host/$repo" "$1" </dev/null 2>&1 >/dev/null)
	rc=$?
	owner_err=$(one_line "${owner_err#owner-check.sh: }")
	# Any other exit is a script that didn't run (a missing bash, say), never a verdict.
	case $rc in 0 | 1 | 3) ;; *) stop 1 "$not: owner-check.sh failed (exit $rc) on $1${owner_err:+: $owner_err}" ;; esac
	return "$rc"
}

# The PR: its state, author, head and the users a review is pending from, one per line.
api "repos/$repo/pulls/$number" --jq '.state, (.merged_at // ""), (.user.login // ""), (.head.sha // ""),
	([.requested_reviewers[]? | select(.type == "User") | .login] | join(" "))' ||
	stop 1 "$not: can't read the PR${api_err:+ ($api_err)}"
{
	read -r state
	read -r merged_at
	read -r author
	read -r head
	read -r pending
} <<EOF
$api_out
EOF
if [ "$state" != open ]; then
	[ -n "$merged_at" ] && stop 0 "$not: it has merged"
	stop 0 "$not: it is ${state:-not open}"
fi

api user --jq .login || stop 1 "$not: can't read the sessions' own login (gh api user)${api_err:+: $api_err}"
me=$api_out
valid_login "$me" || stop 1 "$not: the sessions' own login '$me' isn't a GitHub user login"
owner_check "$me"
[ $? -ne 3 ] || stop 0 "$not: the sessions post as the owner's account ($me, an admin), and GitHub won't let a PR's author review it"

# Who the owner is: the one login both subcommands act on.
if [ -n "$have_owner" ]; then
	owner_check "$owner" || stop 1 "$not: the Owner review line names $owner, who isn't the owner by owner-check.sh ($owner_err)"
	target=$owner
else
	api "repos/$repo" --jq '.owner.type, .owner.login' ||
		stop 1 "$not: can't read the repo${api_err:+ ($api_err)}"
	{
		read -r owner_type
		read -r owner_login
	} <<EOF
$api_out
EOF
	if [ "$owner_type" = User ]; then
		valid_login "$owner_login" || stop 1 "$not: the repo's owner '$owner_login' isn't a GitHub user login"
		owner_check "$owner_login" || stop 1 "$not: can't confirm the repo's owner $owner_login is the owner by owner-check.sh ($owner_err)"
		target=$owner_login
	else
		# An organization's repo. Its admins, the sessions' own login aside:
		# every one would pass owner-check.sh, since that login isn't an
		# admin by now, so only a lone one is checked. One page holds 100,
		# and past one the answer is nobody anyway.
		api "repos/$repo/collaborators" -X GET -f permission=admin -f per_page=100 \
			--jq '.[] | select(.type == "User") | .login' ||
			stop 1 "$not: can't list the repo's admins${api_err:+ ($api_err)}"
		admins=
		for login in $api_out; do
			valid_login "$login" || continue
			[ "$(lower "$login")" != "$(lower "$me")" ] || continue
			admins="${admins:+$admins }$login"
		done
		# shellcheck disable=SC2086 # split the list into words on purpose
		set -- $admins
		[ $# -gt 0 ] || stop 0 "$not: $repo has no admin other than the sessions' own login to ask"
		[ $# -eq 1 ] || stop 0 "$not: $repo has several admins ($admins), so name the owner with an Owner review line"
		owner_check "$1" || stop 1 "$not: can't confirm $repo's one admin $1 is the owner by owner-check.sh ($owner_err)"
		target=$1
	fi
fi

if [ "$cmd" = request ]; then
	[ "$(lower "$target")" != "$(lower "$author")" ] ||
		stop 0 "$not: $target opened it, and GitHub won't let a PR's author review it"
	has_login "$pending" "$target" && stop 0 "already requested from $target on $ref"
	# A head the owner has reviewed has nothing new to ask about: they hear
	# of any answer as a reply. Every page, as owner-approval.sh reads them;
	# where only the first comes back (a cloud proxy), this errs toward asking.
	sha_re='^[0-9a-f]{40}$'
	[[ $head =~ $sha_re ]] || stop 1 "$not: can't read the PR's head"
	api "repos/$repo/pulls/$number/reviews?per_page=100" --paginate \
		--jq ".[] | select(.commit_id == \"$head\" and (.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\" or .state == \"COMMENTED\")) | .user.login" ||
		stop 1 "$not: can't read the PR's reviews${api_err:+ ($api_err)}"
	has_login "$api_out" "$target" && stop 0 "$not: $target already reviewed its head ${head:0:7}, so any reply since reaches them without a request"
	api "repos/$repo/pulls/$number/requested_reviewers" -X POST -f "reviewers[]=$target" \
		--jq '[.requested_reviewers[]? | .login] | join(" ")' ||
		stop 1 "$not: the request for $target failed${api_err:+ ($api_err)}"
	has_login "$api_out" "$target" || stop 1 "$not: GitHub accepted the request for $target but doesn't list it"
	stop 0 "requested $target's review on $ref"
fi

has_login "$pending" "$target" || stop 0 "$not: none is pending from $target"
api "repos/$repo/pulls/$number/requested_reviewers" -X DELETE -f "reviewers[]=$target" \
	--jq '[.requested_reviewers[]? | .login] | join(" ")' ||
	stop 1 "$not: removing $target's request failed${api_err:+ ($api_err)}"
has_login "$api_out" "$target" && stop 1 "$not: GitHub accepted the removal of $target's request but still lists it"
stop 0 "cleared $target's review request on $ref, until the next hand-back requests it again"
