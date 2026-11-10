#!/usr/bin/env bash
# pr-subscription.sh — subscribe this session's PR to the pr-notifier, or
# unsubscribe it, through the notifier's stable path. The skill's notifier.md
# says when START and FINISH run it, and how a woken session handles the wake.
#
#   pr-subscription.sh subscribe <pr>
#   pr-subscription.sh unsubscribe <pr> [--session <session id>]
#
# <pr> is the PR's github.com URL (https://github.com/<owner>/<repo>/pull/<n>,
# as gh pr create prints it) or <owner>/<repo>#<n>. Both act for this session,
# whose id the notifier reads from CLAUDE_CODE_SESSION_ID. unsubscribe
# --session drops another session's subscription instead, by its full id: the
# one a FINISH is about to remove the worktree of, or the one a takeover
# replaces (notifier.md says when).
#
# Being woken is a convenience, never something a step depends on, so this
# prints one line saying what happened and exits:
#
#   0  done; or skipped where there is nothing to do: a cloud session (the
#      harness's own PR events reach it), no notifier installed here, or, for
#      subscribe, a session that isn't a background one
#   1  the notifier ran and failed, this session has no id, or subscribe
#      couldn't tell whether it runs in the background; the line says why
#   2  usage error
#
# Only a background session subscribes. The notifier resumes a stopped
# subscriber with claude --bg --resume, so a terminal session (an interactive
# claude) would come back as a background one after its owner closed it.
# subscribe reads this session's row from claude agents --json --all: its
# kind, the field the notifier itself checks, skipping any kind but
# background (#312 covers notifying a terminal session without resuming it),
# and its name, passed on so the notifier needn't list the sessions again.
#
# The notifier waits up to five minutes for its lock while a poll holds it, so
# a caller's timeout should allow that. It is called only at its stable path,
# $HOME/.local/bin/pr-notifier (the pr-notifier plugin's skill), never in a
# plugin cache, whose directory carries a version. PR_SUBSCRIPTION_CLI
# replaces that path for tests, and PR_SUBSCRIPTION_CLAUDE the claude binary,
# as owner-check.sh's OWNER_CHECK_GH replaces gh.
set -uo pipefail

me=pr-subscription
usage() {
	echo "usage: pr-subscription.sh subscribe <pr> | unsubscribe <pr> [--session <session id>]" >&2
	exit 2
}
say() { printf '%s: %s\n' "$me" "$*"; }

cmd=${1:-}
case $cmd in subscribe | unsubscribe) ;; *) usage ;; esac
shift
pr=
other=
while [ $# -gt 0 ]; do
	case $1 in
	--session)
		[ "$cmd" = unsubscribe ] && [ $# -ge 2 ] && [ -z "$other" ] || usage
		other=$2
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
session_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if [ -n "$other" ] && ! [[ $other =~ $session_re ]]; then
	echo "$me: '$other' isn't a full session id" >&2
	usage
fi

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
if [ -z "$cli" ] || [ ! -f "$cli" ] || [ ! -x "$cli" ]; then
	say "pr-notifier isn't installed here (${cli:-no HOME}), so $ref wasn't ${cmd}d; nothing wakes this session on it"
	exit 0
fi

args=("$cmd" "$ref")
if [ -n "$other" ]; then
	args+=(--session "$other")
elif [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
	say "no session id (CLAUDE_CODE_SESSION_ID), so $ref wasn't ${cmd}d"
	exit 1
fi

if [ "$cmd" = subscribe ]; then
	# This session's row, by its full id (the last one if the listing repeats
	# it), as "<kind> <name>": an empty kind reads as unknown.
	row=$("${PR_SUBSCRIPTION_CLAUDE:-claude}" agents --json --all 2>/dev/null </dev/null |
		jq -r --arg s "$CLAUDE_CODE_SESSION_ID" \
			'[.[]? | select(.sessionId == $s)] | last // empty
			 | "\((.kind // "") | if . == "" then "unknown" else . end) \(.name // "")"' 2>/dev/null)
	kind=${row%% *}
	name=${row#* }
	if [ -z "$row" ]; then
		say "couldn't find this session in claude agents --json --all, so $ref wasn't subscribed (only a background session subscribes)"
		exit 1
	fi
	if [ "$kind" != background ]; then
		say "this session's kind is $kind, not background, so $ref wasn't subscribed: the notifier would resume it in the background once it's closed (#312)"
		exit 0
	fi
	[ -z "$name" ] || args+=(--name "$name")
fi

# The notifier's output, on one line.
out=$("$cli" "${args[@]}" 2>&1 </dev/null)
rc=$?
out=$(printf '%s' "$out" | tr '\n' ' ')
out=${out% }
if [ "$rc" -eq 0 ]; then
	say "${out:-pr-notifier $cmd $ref: done}"
	exit 0
fi
say "pr-notifier $cmd $ref failed (exit $rc): ${out:-no output}"
exit 1
