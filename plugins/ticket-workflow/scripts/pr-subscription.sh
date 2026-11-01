#!/usr/bin/env bash
# pr-subscription.sh — subscribe this session's PR to the pr-notifier, or
# unsubscribe it, through the notifier's stable path. The skill's notifier.md
# says when START and FINISH run it, and how a woken session handles the wake.
#
#   pr-subscription.sh subscribe <pr>
#   pr-subscription.sh unsubscribe <pr> [--all]
#
# <pr> is the PR's github.com URL (https://github.com/<owner>/<repo>/pull/<n>,
# as gh pr create prints it) or <owner>/<repo>#<n>. subscribe and unsubscribe
# act for this session (the notifier reads its id from the environment);
# unsubscribe --all drops every session's subscription to <pr>, for a FINISH
# about to remove the worktree those sessions run in.
#
# Being woken is a convenience, never something a step depends on, so this
# prints one line saying what happened and exits:
#
#   0  done; or skipped where there is nothing to do: a cloud session (the
#      harness's own PR events reach it) or no notifier installed here
#   1  the notifier ran and failed, or this session has no id; the line says why
#   2  usage error
#
# The notifier is called only at its stable path, $HOME/.local/bin/pr-notifier
# (the pr-notifier plugin's skill), never in a plugin cache, whose directory
# carries a version. PR_SUBSCRIPTION_CLI overrides that path (tests).
set -uo pipefail

me=pr-subscription
usage() {
	echo "usage: pr-subscription.sh subscribe <pr> | unsubscribe <pr> [--all]" >&2
	exit 2
}
say() { printf '%s: %s\n' "$me" "$*"; }

cmd=${1:-}
case $cmd in subscribe | unsubscribe) ;; *) usage ;; esac
shift
pr=
all=
while [ $# -gt 0 ]; do
	case $1 in
	--all) [ "$cmd" = unsubscribe ] || usage; all=1 ;;
	-*) usage ;;
	*) [ -z "$pr" ] || usage; pr=$1 ;;
	esac
	shift
done
[ -n "$pr" ] || usage

# The notifier's own ref shape: <owner>/<repo>#<n>.
url_re='^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$'
ref_re='^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+#[0-9]+$'
if [[ $pr =~ $url_re ]]; then
	ref="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}#${BASH_REMATCH[3]}"
elif [[ $pr =~ $ref_re ]]; then
	ref=$pr
else
	echo "$me: '$pr' isn't a github.com PR URL or <owner>/<repo>#<n>" >&2
	usage
fi
case ${ref%#*} in */. | */..) echo "$me: '$pr' names no repo" >&2 && usage ;; esac

if [ "${CLAUDE_CODE_REMOTE:-}" = true ]; then
	say "cloud session, where the harness's own PR events wake it; not ${cmd}d"
	exit 0
fi

cli=${PR_SUBSCRIPTION_CLI:-${HOME:+$HOME/.local/bin/pr-notifier}}
if [ -z "$cli" ] || [ ! -x "$cli" ]; then
	say "pr-notifier isn't installed here (${cli:-no HOME}), so $ref wasn't ${cmd}d; nothing wakes this session on it"
	exit 0
fi

relay() { # relay <cli args...>: runs the notifier, its output on one line
	local out
	out=$("$cli" "$@" 2>&1 </dev/null)
	local rc=$?
	out=$(printf '%s' "$out" | tr '\n' ' ')
	out=${out% }
	if [ "$rc" -eq 0 ]; then
		say "${out:-pr-notifier $1 $2: done}"
	else
		say "pr-notifier $1 $2 failed (exit $rc): ${out:-no output}"
	fi
	return "$rc"
}

if [ -n "$all" ]; then
	# Every session subscribed to the PR, by its full id, from the registry.
	listing=$("$cli" status --json 2>/dev/null </dev/null) ||
		{ say "can't read the pr-notifier's subscriptions (status --json failed)"; exit 1; }
	sessions=$(printf '%s' "$listing" | jq -r --arg r "$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]')" \
		'[.subscriptions[]? | select(.pr == $r) | .session_id] | unique | .[]' 2>/dev/null) ||
		{ say "can't read the pr-notifier's subscriptions (status --json isn't a listing)"; exit 1; }
	if [ -z "$sessions" ]; then
		say "no subscriptions on $ref"
		exit 0
	fi
	rc=0
	while IFS= read -r sid; do
		relay unsubscribe "$ref" --session "$sid" || rc=1
	done <<<"$sessions"
	exit "$rc"
fi

if [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
	say "no session id (CLAUDE_CODE_SESSION_ID), so $ref wasn't ${cmd}d"
	exit 1
fi
relay "$cmd" "$ref" || exit 1
exit 0
