#!/usr/bin/env bash
# owner-check.sh — is a GitHub login the owner's, by its live permission on
# the repo? For the default profile's REVIEW_BOT, *Owner requests*, in
# skills/ticket-workflow/, and for anything else that must tell the owner's
# comments from a stranger's.
#
#   owner-check.sh [-R [<host>/]<owner>/<repo>] <login>
#
# Reads GitHub's permission (repos/<owner>/<repo>/collaborators/<login>/permission)
# for <login> and for the sessions' own login (`gh api user`), and exits:
#
#   0  <login> has admin, and the sessions' login doesn't: the owner's
#   3  <login> is the sessions' own login, and it has admin: the sessions post
#      as the owner's account, so the same-account rules apply
#   1  anything else, trust no one: a login below admin, the sessions' own
#      login below admin, any other admin while the sessions' login has admin,
#      a [bot] or malformed login, a failed read, a usage error
#
# Why admin: sessions need write to push, so write can't be the line, and an
# admin could already merge or edit directly, so honoring one adds no power.
# Why the sessions' login must not have admin: it could grant admin to
# another account, so then nobody else is trusted.
#
# <login> must be a GitHub login's characters (alphanumerics and hyphens, not
# leading, at most 39) before it reaches a URL or the shell, so a [bot] login
# never does, and logins compare case-insensitively. Both reads go to the
# repo's own host: -R's <host>/ prefix (gh's default host without one), or,
# with no -R, the host and owner/repo origin points at, so a repo on another
# GitHub host is never checked against a github.com namesake. One line on
# stderr says why. Standalone on purpose (gh only, plus git for the origin
# default), so another plugin can call or vendor it. OWNER_CHECK_GH overrides
# the gh binary (tests).
set -uo pipefail

usage="usage: owner-check.sh [-R [<host>/]<owner>/<repo>] <login>"
untrusted() {
	echo "owner-check.sh: $*" >&2
	exit 1
}

login_re='^[A-Za-z0-9][A-Za-z0-9-]*$'
valid_login() { # a GitHub login's characters: alphanumerics and hyphens, not leading, at most 39
	[ "${#1}" -le 39 ] && [[ $1 =~ $login_re ]]
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

repo=
login=
have_login=
while [ $# -gt 0 ]; do
	case $1 in
	-R)
		[ $# -ge 2 ] || untrusted "$usage"
		repo=$2
		shift 2
		;;
	*)
		[ -z "$have_login" ] || untrusted "$usage"
		login=$1
		have_login=1
		shift
		;;
	esac
done
[ -n "$have_login" ] || untrusted "$usage"
valid_login "$login" || untrusted "'$login' is not a GitHub user login, so it isn't trusted"

host=
if [ -n "$repo" ]; then
	case $repo in */*/*) host=${repo%%/*} repo=${repo#*/} ;; esac
else
	url=$(git remote get-url origin 2>/dev/null) || untrusted "no -R and no origin remote to read owner/repo from"
	case $url in
	*://*) # scheme://[user@]host[:port]/owner/repo
		rest=${url#*://}
		authority=${rest%%/*}
		url_path=${rest#"$authority"}
		url_path=${url_path#/}
		authority=${authority##*@}
		host=${authority%%:*}
		;;
	*:*) # scp-like [user@]host:owner/repo
		authority=${url%%:*}
		url_path=${url#*:}
		host=${authority##*@}
		;;
	*) untrusted "can't read owner/repo from origin's URL $url" ;;
	esac
	url_path=${url_path%/}
	repo=${url_path%.git}
	[ -n "$host" ] || untrusted "can't read the host from origin's URL $url"
fi
host_re='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
[ -z "$host" ] || [[ $host =~ $host_re ]] || untrusted "'$host' is not a host name"
repo_owner=${repo%%/*}
repo_name=${repo#*/}
name_re='^[A-Za-z0-9._-]+$'
if [ "$repo" = "$repo_owner" ] || ! valid_login "$repo_owner" || ! [[ $repo_name =~ $name_re ]] ||
	[ "$repo_name" = . ] || [ "$repo_name" = .. ]; then
	untrusted "'$repo' is not an <owner>/<repo>"
fi

gh_bin=${OWNER_CHECK_GH:-gh}

api() { # api <endpoint> <jq filter>: one GitHub REST read, on the repo's host
	# </dev/null: gh never needs stdin here.
	if [ -n "$host" ]; then
		"$gh_bin" api "$1" --hostname "$host" --jq "$2" </dev/null 2>/dev/null
	else
		"$gh_bin" api "$1" --jq "$2" </dev/null 2>/dev/null
	fi
}

permission() { # permission <login>: GitHub's legacy role (admin/write/read/none), or fails
	local out
	# A failed read prints its error body on stdout too, so only the exit
	# status says it worked.
	out=$(api "repos/$repo/collaborators/$1/permission" .permission) || return 1
	[ -n "$out" ] || return 1
	printf '%s' "$out"
}

me=$(api user .login) || untrusted "can't read the sessions' own login (gh api user)"
valid_login "$me" || untrusted "the sessions' own login '$me' isn't a GitHub user login"
me_perm=$(permission "$me") || untrusted "can't read $me's permission on $repo"

if [ "$(lower "$login")" = "$(lower "$me")" ]; then
	[ "$me_perm" = admin ] && {
		echo "owner-check.sh: $login is the sessions' own login and an admin on $repo: same-account mode" >&2
		exit 3
	}
	untrusted "$login is the sessions' own login, with $me_perm on $repo"
fi
[ "$me_perm" != admin ] ||
	untrusted "the sessions' login $me is an admin on $repo, so no other login is trusted"

perm=$(permission "$login") || untrusted "can't read $login's permission on $repo"
[ "$perm" = admin ] || untrusted "$login has $perm on $repo, not admin"
echo "owner-check.sh: $login is an admin on $repo, and the sessions' login $me isn't: the owner" >&2
exit 0
