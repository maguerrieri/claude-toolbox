#!/usr/bin/env bash
# pr-wait.sh — wait in-turn for one PR state, and end loudly, for every wait
# START Step 8, the default profile's REVIEW_BOT and FINISH in
# skills/ticket-workflow/ tell a session to make.
#
#   pr-wait.sh ci <pr> --head <sha> [options]          every check on <sha> done
#   pr-wait.sh review <pr> --head <sha> [--bot <bot>] [--idle <dur>] [options]
#                                                      the bot's review of <sha>
#   pr-wait.sh mergeable <pr> [--head <sha>] [options] GitHub's mergeability known
#
# Options, in any order:
#   -R [<host>/]<owner>/<repo>  the PR's repo (default: the current
#                               directory's origin, which gh fills in)
#   --timeout <dur>   give up after this long (default 30m)
#   --interval <dur>  time between reads (default 30s; 10s for mergeable)
#   --settle <dur>    how long GitHub may take, after a push, to show <sha>
#                     as the PR's head and to register its checks (default 5m)
#   --idle <dur>      review: how long the bot may show no sign of reviewing
#                     (neither requested nor running) before the wait ends
#                     (default 5m)
#   --bot <bot>       review: the engaged bot (default copilot; see BOTS)
# A <dur> is a whole number of seconds, or a number with s, m or h.
# <sha> is the full 40-character sha. mergeable without --head pins the head
# it reads first.
#
# Exit codes, so a caller never mistakes "still running" for "broken":
#   0  done and green: ci, every check passed; review, the bot's review of
#      <sha> lists no findings; mergeable, MERGEABLE
#   1  done and failed: ci, a check failed (it stops at the first); review,
#      the review lists findings; mergeable, CONFLICTING
#   2  error: a usage error, a PR that isn't open, or a read that still fails
#      after its retries (gh's error is on stderr); never "not yet"
#   3  head moved: the PR's head is not <sha>, or stopped being <sha>
#   4  timed out, with the last state seen
#   5  nothing to wait for: ci, no check registered on <sha> within --settle;
#      review, the bot couldn't review <sha> ("unable"), or showed no sign of
#      reviewing it for --idle ("idle")
#
# Output: one stdout line per state change, "<subcommand> #<pr> <sha12>:
# <state>[ <detail>]", ending with the final state, so the same call works as
# a run_in_background wait (one notification, at exit) or as a Monitor
# stream (one event per line). The final line is also the answer: for
# mergeable its detail is "<mergeable> <mergeStateStatus>" in gh's uppercase
# spelling (MERGEABLE BEHIND, say). A timeout or an error also goes to
# stderr.
#
# Why a script: a hand-rolled wait loop whose check errors spins silently.
# On sprue-works/cbeams#104 one used `gh --jq --arg`, which gh rejects
# ("accepts at most 1 arg(s), received 4"), so its test was false on every
# pass, and the session waited 5.5 hours on a green, reviewed PR (#351).
# Here a read that fails is retried (PR_WAIT_ATTEMPTS tries in all, default
# 3, PR_WAIT_RETRY_DELAY seconds apart, default 5, doubling), then ends the
# wait with exit 2.
#
# Every read is REST (gh api, and scripts/gh-rest-list.sh for lists), never
# GraphQL, and every comparison is standalone jq with --arg, never
# `gh --jq --arg`, so it runs unchanged behind the cloud proxy
# (github-rest.md). It needs gh and jq.
#
# BOTS: `review` reads the engaged bot through one function per bot,
# bot_<name> (bot_copilot below). It runs once per read with $pr, $sha,
# $repo and $pr_json (the PR as REST returns it) set, prints one line,
# "<state> <detail>", and returns non-zero when a read fails. <state> is:
#   pending   the bot is requested or running on <sha>
#   idle      no sign of it doing either (the wait ends after --idle)
#   clean     its review of <sha> lists no findings
#   findings  its review of <sha> lists findings, to read as REVIEW_BOT says
#   unable    it couldn't review <sha>, and no retry has been requested
# A new bot (Codex, #260) is one more function.
#
# The docs run it as `bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/pr-wait.sh" …`,
# the same way as role-marker.sh. PR_WAIT_GH overrides the gh binary (tests).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
gh_bin=${PR_WAIT_GH:-gh}
usage="usage: pr-wait.sh ci|review|mergeable <pr> [--head <sha>] [-R [<host>/]<owner>/<repo>] [--timeout <dur>] [--interval <dur>] [--settle <dur>] [--idle <dur>] [--bot <bot>]"

die() { # die <message>: exit 2, the message on stderr
	echo "pr-wait.sh: $*" >&2
	exit 2
}

dur() { # dur <value>: prints the duration in seconds, or fails
	[[ $1 =~ ^([0-9]+)([smh]?)$ ]] || return 1
	local n=$((10#${BASH_REMATCH[1]}))
	case ${BASH_REMATCH[2]} in
	m) n=$((n * 60)) ;;
	h) n=$((n * 3600)) ;;
	esac
	echo "$n"
}

fmt() { # fmt <seconds>: 30m, 90s
	if [ "$1" -ge 60 ] && [ $(($1 % 60)) -eq 0 ]; then echo "$(($1 / 60))m"; else echo "${1}s"; fi
}

# --- arguments -------------------------------------------------------------

[ $# -ge 2 ] || die "$usage"
sub=$1
pr=$2
shift 2
case $sub in ci | review | mergeable) ;; *) die "$usage" ;; esac
[[ $pr =~ ^[1-9][0-9]*$ ]] || die "'$pr' is not a PR number"

sha=
repo='{owner}/{repo}'
host=
timeout=1800
interval=30
[ "$sub" = mergeable ] && interval=10
settle=300
idle=300
bot=copilot
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || die "$usage"
	case $1 in
	--head) sha=$2 ;;
	-R) repo=$2 ;;
	--timeout) timeout=$(dur "$2") || die "--timeout '$2' is not a duration" ;;
	--interval) interval=$(dur "$2") || die "--interval '$2' is not a duration" ;;
	--settle) settle=$(dur "$2") || die "--settle '$2' is not a duration" ;;
	--idle)
		[ "$sub" = review ] || die "--idle is for review only"
		idle=$(dur "$2") || die "--idle '$2' is not a duration"
		;;
	--bot)
		[ "$sub" = review ] || die "--bot is for review only"
		bot=$2
		;;
	*) die "$usage" ;;
	esac
	shift 2
done

if [ "$sub" != mergeable ] && [ -z "$sha" ]; then
	die "$sub needs --head <sha>, the commit to wait on"
fi
[ -z "$sha" ] || [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "--head '$sha' is not a full 40-character commit sha"

if [ "$repo" != '{owner}/{repo}' ]; then
	case $repo in */*/*) host=${repo%%/*} repo=${repo#*/} ;; esac
	[[ $repo =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "-R '$repo' is not an <owner>/<repo>"
	[ -z "$host" ] || [[ $host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "'$host' is not a host name"
fi

attempts=${PR_WAIT_ATTEMPTS:-3}
retry_delay=${PR_WAIT_RETRY_DELAY:-5}
[[ $attempts =~ ^[1-9][0-9]*$ ]] || die "PR_WAIT_ATTEMPTS '$attempts' is not a positive number"
[[ $retry_delay =~ ^[0-9]+$ ]] || die "PR_WAIT_RETRY_DELAY '$retry_delay' is not a whole number of seconds"

command -v jq >/dev/null 2>&1 || die "needs jq on PATH"
command -v "$gh_bin" >/dev/null 2>&1 || die "needs gh on PATH"

tmp=$(mktemp -d) || die "can't make a temp directory"
trap 'rm -rf "$tmp"' EXIT

# --- reads -----------------------------------------------------------------

# Every read runs inside $(...), a subshell, so a failed one keeps its first
# error line in a file for the final report, and shows the whole error on
# stderr as it happens.
failed_read() { # failed_read <stderr file>
	cat "$1" >&2
	head -n 1 "$1" >"$tmp/last-err"
	return 1
}

api() { # api <endpoint> [gh api args...]: one REST read, raw JSON on stdout
	# </dev/null: gh never needs stdin here.
	"$gh_bin" api "$@" ${host:+--hostname "$host"} </dev/null 2>"$tmp/err-api" || failed_read "$tmp/err-api"
}

rest_list() { # rest_list <endpoint> [gh-rest-list.sh args...]: every item, one JSON array
	GH_REST_LIST_GH="$gh_bin" bash "$here/gh-rest-list.sh" "$@" ${host:+--hostname "$host"} </dev/null 2>"$tmp/err-list" ||
		failed_read "$tmp/err-list"
}

j() { # j <jq args...>: standalone jq; a failure (a reply of the wrong shape) is a failed read
	local why
	jq "$@" 2>"$tmp/err-jq" && return 0
	why=$(head -n 1 "$tmp/err-jq")
	printf 'pr-wait.sh: unexpected reply from GitHub: %s\n' "$why" >"$tmp/err-jq"
	failed_read "$tmp/err-jq"
}

fail() { # fail <message>: a reply that parsed but can't be used
	printf 'pr-wait.sh: %s\n' "$1" >"$tmp/err-own"
	failed_read "$tmp/err-own"
}

# --- the PR and its head ---------------------------------------------------

start=$SECONDS
head_seen=
pr_json=
state=
detail=

read_pr() { # sets pr_json, and state/detail when the PR or its head ends this read
	local head pr_state
	pr_json=$(api "repos/$repo/pulls/$pr") || return 1
	head=$(printf '%s' "$pr_json" | j -r '.head.sha | strings') || return 1
	pr_state=$(printf '%s' "$pr_json" | j -r 'if .merged_at then "merged" else (.state | strings) end') || return 1
	if [ -z "$head" ] || [ -z "$pr_state" ]; then
		fail "GitHub's reply for PR #$pr has no head sha or state"
		return 1
	fi
	if [ "$pr_state" != open ]; then
		state=closed detail="PR #$pr is $pr_state; nothing to wait for"
		return 0
	fi
	[ -n "$sha" ] || sha=$head
	if [ "$head" = "$sha" ]; then
		head_seen=1
	elif [ -n "$head_seen" ]; then
		state=moved detail="the head is now $head"
	elif [ $((SECONDS - start)) -ge "$settle" ]; then
		state=moved detail="the head is $head, not this one, after $(fmt "$settle")"
	else
		# Right after a push, GitHub can show the old head for a moment.
		state=syncing detail="the PR still shows $head"
	fi
	return 0
}

# --- ci --------------------------------------------------------------------

poll_ci() {
	local runs statuses summary
	# Only the fields used: a check run's output can be large, and Linux caps
	# one argument (the --argjson below) at 128 KB.
	runs=$(rest_list "repos/$repo/commits/$sha/check-runs" --key check_runs) || return 1
	runs=$(printf '%s' "$runs" | j -c 'map({name, status, conclusion})') || return 1
	statuses=$(api "repos/$repo/commits/$sha/status" -X GET -f per_page=100) || return 1
	statuses=$(printf '%s' "$statuses" | j -c '[(.statuses // [])[] | {context, state}]') || return 1
	# Classified as github-rest.md's CI read and gh pr checks do: a stale
	# conclusion is pending, these conclusions fail, the rest pass.
	summary=$(j -rn --argjson runs "$runs" --argjson st "$statuses" '
		def failed: test("^(failure|cancelled|timed_out|action_required|startup_failure)$");
		([$runs[] | {name, s: (if .status != "completed" or .conclusion == "stale" then "pending"
		                       elif ((.conclusion // "") | failed) then .conclusion else "pass" end)}]
		 + [$st[] | {name: .context, s: (if .state == "pending" then "pending"
		                       elif ((.state // "") | test("^(failure|error)$")) then .state else "pass" end)}]) as $c
		| ($c | map(select(.s == "pending")) | map(.name)) as $p
		| ($c | map(select(.s != "pending" and .s != "pass")) | map("\(.name) (\(.s))")) as $f
		| if ($c | length) == 0 then "none"
		  elif ($f | length) > 0 then "failed \($f | join(", "))"
		  elif ($p | length) > 0 then "pending \($p | length) of \($c | length) running: \($p | join(", "))"
		  else "green \($c | length) passed" end') || return 1
	state=${summary%% *}
	detail=${summary#"$state"}
	detail=${detail# }
	if [ "$state" = none ]; then
		if [ $((SECONDS - start)) -ge "$settle" ]; then
			detail="no check registered after $(fmt "$settle")"
		else
			state=registering detail="no checks reported yet"
		fi
	fi
	return 0
}

# --- review ----------------------------------------------------------------

# Copilot: its reviews are by copilot-pull-request-reviewer[bot]; a request
# shows as Copilot in requested_reviewers and the timeline, and a run as a
# copilot-pull-request-reviewer check run on the head (REVIEW_BOT's detect
# step). Its review body's shapes are REVIEW_BOT's.
bot_copilot() {
	local reviews newest id at comments verdict sections pending runs retried
	reviews=$(rest_list "repos/$repo/pulls/$pr/reviews") || return 1
	newest=$(printf '%s' "$reviews" | j -c --arg sha "$sha" '
		[.[] | select(.user.login == "copilot-pull-request-reviewer[bot]" and .commit_id == $sha)]
		| sort_by(.submitted_at) | last // empty
		| {id, submitted_at, body: (.body // "")}
		| . + {unable: (.body | test("^\\s*(<!--[^>]*-->\\s*)?(## Copilot review overview\\s*)?Copilot was unable to review"))}') ||
		return 1
	if [ -n "$newest" ]; then
		id=$(printf '%s' "$newest" | j -r .id) || return 1
		at=$(printf '%s' "$newest" | j -r .submitted_at) || return 1
	fi
	if [ -n "$newest" ] && [ "$(printf '%s' "$newest" | j -r .unable)" = false ]; then
		comments=$(rest_list "repos/$repo/pulls/$pr/reviews/$id/comments") || return 1
		comments=$(printf '%s' "$comments" | j length) || return 1
		verdict=$(printf '%s' "$newest" | j -r '(first(.body | capture("###[ \\t]+(?<v>(🟢|🟡|🔵)[^\\n]*)")) // {v: ""}).v') || return 1
		sections=$(printf '%s' "$newest" | j -r '[.body | scan("(Suppressed comments|Previously missed|Open) \\(([0-9]+)\\)") | .[1] | tonumber] | add // 0') ||
			return 1
		# Clean only when nothing could need an answer: a green verdict, no
		# comment of its own, and no counted body section. Anything else goes
		# back to the caller, to read as REVIEW_BOT says.
		case $verdict in
		"🟢"*)
			if [ "$comments" -eq 0 ] && [ "$sections" -eq 0 ]; then
				echo "clean review $id: ${verdict#* }"
				return 0
			fi
			;;
		esac
		echo "findings review $id: ${verdict:+${verdict#* }, }$comments comments, body sections counting $sections"
		return 0
	fi
	pending=$(printf '%s' "$pr_json" | j -r '[.requested_reviewers[]?.login] | any(test("^(Copilot|copilot-pull-request-reviewer(\\[bot\\])?)$"))') ||
		return 1
	if [ "$pending" = false ]; then
		runs=$(rest_list "repos/$repo/commits/$sha/check-runs" --key check_runs) || return 1
		pending=$(printf '%s' "$runs" | j -r 'any(.[]; .name == "copilot-pull-request-reviewer" and .status != "completed")') || return 1
	fi
	if [ "$pending" = true ]; then
		echo "pending requested or running"
		return 0
	fi
	if [ -n "$newest" ]; then
		# An unable body is not a review, and REVIEW_BOT retries it once: report
		# it, unless a request for Copilot came after it.
		retried=$(rest_list "repos/$repo/issues/$pr/timeline") || return 1
		retried=$(printf '%s' "$retried" | j -r --arg at "$at" '
			any(.[]; .event == "review_requested" and (.requested_reviewer.login // "") == "Copilot"
			         and (.created_at // "") > $at)') || return 1
		if [ "$retried" = false ]; then
			echo "unable review $id: Copilot was unable to review this head"
		else
			echo "idle a retry was requested after unable review $id, and nothing is pending"
		fi
		return 0
	fi
	echo "idle Copilot is neither requested nor running"
	return 0
}

bot_fn=bot_${bot//-/_}
if ! [[ $bot =~ ^[a-z0-9-]+$ ]] || ! declare -F "$bot_fn" >/dev/null; then
	die "no bot check for '$bot' (known: $(declare -F | sed -n 's/^declare -f bot_//p' | tr _ - | paste -sd , - | sed 's/,/, /g'))"
fi

idle_since=
poll_review() {
	local out
	out=$("$bot_fn") || return 1
	state=${out%% *}
	detail=${out#"$state"}
	detail=${detail# }
	case $state in
	pending) idle_since= ;;
	idle)
		[ -n "$idle_since" ] || idle_since=$SECONDS
		if [ $((SECONDS - idle_since)) -lt "$idle" ]; then
			state=quiet detail="$detail; waiting up to $(fmt "$idle") for $bot to start"
		else
			detail="$detail, for $(fmt "$idle")"
		fi
		;;
	clean | findings | unable) ;;
	*)
		fail "$bot_fn printed '$out', which isn't one of its states"
		return 1
		;;
	esac
	return 0
}

# --- mergeable -------------------------------------------------------------

poll_mergeable() {
	local m
	m=$(printf '%s' "$pr_json" | j -r '
		(if .mergeable == true then "MERGEABLE" elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end)
		+ " " + ((.mergeable_state // "unknown") | ascii_upcase)') || return 1
	case $m in
	UNKNOWN* | *" UNKNOWN") state=computing detail=$m ;;
	MERGEABLE*) state=mergeable detail=$m ;;
	*) state=conflicting detail=$m ;;
	esac
	return 0
}

# --- the wait --------------------------------------------------------------

poll() { # one read of everything the subcommand needs
	state= detail=
	read_pr || return 1
	[ -z "$state" ] || return 0 # closed, moved, or still syncing
	"poll_$sub"
}

emit() { printf '%s #%s %s: %s%s\n' "$sub" "$pr" "${sha:0:12}" "$state" "${detail:+ $detail}"; }

last=
while :; do
	attempt=1
	delay=$retry_delay
	until poll; do
		if [ "$attempt" -ge "$attempts" ]; then
			state=error detail="a read failed $attempts times in a row: $(cat "$tmp/last-err" 2>/dev/null)"
			emit
			emit >&2
			exit 2
		fi
		echo "pr-wait.sh: read failed (try $attempt of $attempts); retrying in ${delay}s" >&2
		sleep "$delay"
		attempt=$((attempt + 1))
		delay=$((delay * 2))
	done
	line=$(emit)
	[ "$line" = "$last" ] || printf '%s\n' "$line"
	last=$line
	case $state in
	green | clean | mergeable) exit 0 ;;
	failed | findings | conflicting) exit 1 ;;
	closed)
		printf '%s\n' "$line" >&2
		exit 2
		;;
	moved) exit 3 ;;
	none | idle | unable) exit 5 ;;
	esac
	if [ $((SECONDS - start)) -ge "$timeout" ]; then
		state=timeout detail="after $(fmt "$timeout"); last: ${last#*: }"
		emit
		emit >&2
		exit 4
	fi
	sleep "$interval"
done
