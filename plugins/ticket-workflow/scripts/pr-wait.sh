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
#   --timeout <dur>   give up after this long (default 30m), retries included;
#                     under the Monitor tool, whose limit is 30 minutes, pass 25m
#   --interval <dur>  time between reads (default 30s; 10s for mergeable;
#                     at least 5s, since each read is several API calls)
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
#   1  done and failed: ci, a check failed (it stops at the first; the last
#      line names each with its conclusion, and action_required is a run
#      waiting for a maintainer's approval, not a fault in the code); review,
#      the review lists findings; mergeable, CONFLICTING
#   2  error: a usage error, or a read that still fails after its retries
#      (gh's error is on stderr); never "not yet"
#   3  head moved: the PR's head moved off <sha>, has moved past it (a later
#      commit), or never showed it within --settle
#   4  timed out, with the last state seen
#   5  nothing to wait for: ci, no check registered on <sha> within --settle
#      of its push; review, the bot couldn't review <sha> ("unable"), or
#      showed no sign of reviewing it for --idle ("idle")
#   6  the PR merged or closed while it waited (the last line says which)
#
# ci reads the head's check runs and commit statuses as github-rest.md's CI
# read classifies them, and counts a GitHub Actions check suite that hasn't
# completed as pending too, so a job that waits on another (needs:) isn't
# missed before GitHub creates it; an Actions suite with no runs counts only
# within --settle of the push. Other apps' suites are left out (a Vercel,
# Cloudflare or Claude app's sit queued with no runs for good), and so is the
# review bot's own run (copilot-pull-request-reviewer), which is `review`'s
# to wait for.
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
# wait with exit 2. A failure that reads as GitHub being briefly unavailable
# (HTTP 5xx or 429, a rate limit, a network error) gets PR_WAIT_TRANSIENT_ATTEMPTS
# tries instead (default 8, the delay capped at a minute: about four minutes).
#
# Every read is REST (gh api, and scripts/gh-rest-list.sh for lists), never
# GraphQL, and every comparison is standalone jq with --arg, never
# `gh --jq --arg`, so it runs unchanged behind the cloud proxy
# (github-rest.md). It needs gh and jq.
#
# BOTS: `review` reads the engaged bot through one function per bot,
# bot_<name> (bot_copilot below), and ci leaves out the run each one names in
# bot_runs. The function runs once per read with $pr, $sha, $repo and
# $pr_json (the PR as REST returns it) set, prints one line,
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

# Each review bot's own check run, named once: bot_<name> reads it as the
# bot's running signal, and ci leaves every one in bot_runs to `review`.
copilot_run=copilot-pull-request-reviewer
bot_runs="[\"$copilot_run\"]" # JSON
# Splits the fields one jq call prints: the unit separator, not a tab, since
# read collapses empty fields between whitespace separators.
sep=$'\x1f'

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
# Each read is several API calls, so a shorter interval only spends the rate
# limit. PR_WAIT_FAST lifts the floor for the tests, which script sequences
# by call rather than by time.
[ "$interval" -ge 5 ] || [ -n "${PR_WAIT_FAST:-}" ] || die "--interval must be at least 5s"
[ -z "$sha" ] || [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "--head '$sha' is not a full 40-character commit sha"

if [ "$repo" != '{owner}/{repo}' ]; then
	case $repo in */*/*) host=${repo%%/*} repo=${repo#*/} ;; esac
	[[ $repo =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "-R '$repo' is not an <owner>/<repo>"
	[ -z "$host" ] || [[ $host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "'$host' is not a host name"
fi

attempts=${PR_WAIT_ATTEMPTS:-3}
transient_attempts=${PR_WAIT_TRANSIENT_ATTEMPTS:-8}
retry_delay=${PR_WAIT_RETRY_DELAY:-5}
[[ $attempts =~ ^[1-9][0-9]*$ ]] || die "PR_WAIT_ATTEMPTS '$attempts' is not a positive number"
[[ $transient_attempts =~ ^[1-9][0-9]*$ ]] || die "PR_WAIT_TRANSIENT_ATTEMPTS '$transient_attempts' is not a positive number"
[[ $retry_delay =~ ^[0-9]+$ ]] || die "PR_WAIT_RETRY_DELAY '$retry_delay' is not a whole number of seconds"

command -v jq >/dev/null 2>&1 || die "needs jq on PATH"
command -v "$gh_bin" >/dev/null 2>&1 || die "needs gh on PATH"

tmp=$(mktemp -d) || die "can't make a temp directory"
trap 'rm -rf "$tmp"' EXIT

# --- reads -----------------------------------------------------------------

# Every read runs inside $(...), a subshell, so a failed one keeps its error
# in a file for the retry decision and the final report, and shows it on
# stderr as it happens.
failed_read() { # failed_read <stderr file>
	cat "$1" >&2
	cp "$1" "$tmp/last-err"
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

transient() { # did the last failed read look like GitHub being briefly unavailable?
	grep -qiE 'HTTP (5[0-9][0-9]|429)|rate limit|timed? ?out|connection (reset|refused)|unexpected EOF|no such host|TLS handshake|dial tcp|network is unreachable' \
		"$tmp/last-err" 2>/dev/null
}

# --- the PR and its head ---------------------------------------------------

start=$SECONDS
head_seen=
pr_json=
age=0
state=
detail=

# Has GitHub had --settle since the push to show the head and register its
# checks? The push came before this wait began, and at least $age seconds
# ago (the PR hasn't changed since). $age is GitHub's time against the local
# clock, so trust it only past 15 more minutes, for a clock that runs fast.
settled() { [ $((SECONDS - start)) -ge "$settle" ] || [ "$age" -ge $((settle + 900)) ]; }

read_pr() { # sets pr_json and age, and state/detail when the PR or its head ends this read
	local fields head pr_state rel
	pr_json=$(api "repos/$repo/pulls/$pr") || return 1
	# age: seconds since the PR last changed (a push changes it), 0 when
	# GitHub doesn't say, which only ever makes the wait longer.
	fields=$(printf '%s' "$pr_json" | j -r '[(.head.sha // ""),
		(if .merged_at then "merged" else (.state // "") end),
		(if .updated_at then ([now - (.updated_at | fromdateiso8601), 0] | max | floor) else 0 end)]
		| map(tostring) | join("\u001f")') || return 1
	IFS=$sep read -r head pr_state age <<<"$fields"
	if [ -z "$head" ] || [ -z "$pr_state" ]; then
		fail "GitHub's reply for PR #$pr has no head sha or state"
		return 1
	fi
	if [ "$pr_state" != open ]; then
		state=closed
		[ "$pr_state" != merged ] || state=merged
		return 0
	fi
	[ -n "$sha" ] || sha=$head
	if [ "$head" = "$sha" ]; then
		head_seen=1
		return 0
	fi
	if [ -n "$head_seen" ]; then
		state=moved detail="the head is now $head"
		return 0
	fi
	# Not seen yet: right after a push GitHub can show the old head for a
	# moment, but a head that is already past <sha> won't come back to it.
	# A compare GitHub can't answer (a sha it doesn't have yet, or at all)
	# settles nothing, so the wait goes on to --settle, as for any other.
	rel=$(api "repos/$repo/compare/$sha...$head" 2>/dev/null) &&
		rel=$(printf '%s' "$rel" | jq -r '.status // ""' 2>/dev/null) || rel=
	if [ "$rel" = ahead ]; then
		state=moved detail="the head is now $head, a later commit"
	elif [ $((SECONDS - start)) -ge "$settle" ]; then
		# Timed from this wait's start only: right after a push the PR's own
		# update time is the old head's.
		state=moved detail="the head is $head, not this one, after $(fmt "$settle")"
	else
		state=syncing detail="the PR still shows $head"
	fi
	return 0
}

# --- ci --------------------------------------------------------------------

poll_ci() {
	local runs suites statuses summary fresh
	# Only the fields used: a check run's output can be large, and Linux caps
	# one argument (the --argjson below) at 128 KB.
	runs=$(rest_list "repos/$repo/commits/$sha/check-runs" --key check_runs) || return 1
	runs=$(printf '%s' "$runs" | j -c 'map({name, status, conclusion, suite: .check_suite.id})') || return 1
	suites=$(rest_list "repos/$repo/commits/$sha/check-suites" --key check_suites) || return 1
	suites=$(printf '%s' "$suites" | j -c 'map(select(.app.slug == "github-actions") | {id, status})') || return 1
	# Every page: a failing context past the first 100 would otherwise read
	# as green.
	statuses=$(rest_list "repos/$repo/commits/$sha/status" --key statuses) || return 1
	statuses=$(printf '%s' "$statuses" | j -c 'map({context, state})') || return 1
	# Classified as github-rest.md's CI read and gh pr checks do: a stale
	# conclusion is pending, these conclusions fail, the rest pass.
	# An unfinished Actions suite with runs is a workflow with jobs still to
	# start (needs:). One with no runs yet counts only until the push has
	# settled, since GitHub can leave such a suite queued for good.
	fresh=true
	! settled || fresh=false
	summary=$(j -rn --argjson runs "$runs" --argjson suites "$suites" --argjson st "$statuses" --argjson bots "$bot_runs" --argjson fresh "$fresh" '
		def failed: test("^(failure|cancelled|timed_out|action_required|startup_failure)$");
		def isbot: . as $n | any($bots[]; . == $n);
		[$runs[] | select(.name | isbot | not)] as $mine
		| ([$runs[] | select(.name | isbot) | .suite] - [$mine[] | .suite]) as $botsuites
		| ([$mine[] | {name, suite, s: (if .status != "completed" or .conclusion == "stale" then "pending"
		                       elif ((.conclusion // "") | failed) then .conclusion else "pass" end)}]
		 + [$st[] | {name: .context, suite: null, s: (if .state == "pending" then "pending"
		                       elif ((.state // "") | test("^(failure|error)$")) then .state else "pass" end)}]) as $c
		| ($c | map(select(.s == "pending"))) as $p
		| ($c | map(select(.s != "pending" and .s != "pass")) | map("\(.name) (\(.s))")) as $f
		| [$suites[] | select(.status != "completed") | .id as $i
		   | select((any($botsuites[]; . == $i) or any($p[]; .suite == $i)) | not)
		   | select($fresh or any($mine[]; .suite == $i))] as $waiting
		| if ($f | length) > 0 then "failed \($f | join(", "))"
		  elif ($p | length) > 0 or ($waiting | length) > 0 then
		    "pending " + ([if ($p | length) > 0 then "\($p | length) of \($c | length) running: \($p | map(.name) | join(", "))" else empty end,
		                   if ($waiting | length) > 0 then "\($waiting | length) GitHub Actions workflow run(s) with jobs still to start" else empty end]
		                  | join("; "))
		  elif ($c | length) == 0 then "none"
		  else "green \($c | length) passed" end') || return 1
	state=${summary%% *}
	detail=${summary#"$state"}
	detail=${detail# }
	if [ "$state" = none ]; then
		# Checks register within --settle of the push.
		if [ "$fresh" = false ]; then
			detail="no check registered within $(fmt "$settle") of the push"
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
	local reviews newest id at unable verdict sections comments pending runs retried
	# Pending first: a re-request on a head Copilot already reviewed is a
	# newer review on its way, which an earlier verdict must not stand in for.
	pending=$(printf '%s' "$pr_json" | j -r '[.requested_reviewers[]?.login] | any(test("^(Copilot|copilot-pull-request-reviewer(\\[bot\\])?)$"))') ||
		return 1
	if [ "$pending" = false ]; then
		runs=$(rest_list "repos/$repo/commits/$sha/check-runs" --key check_runs) || return 1
		pending=$(printf '%s' "$runs" | j -r --arg run "$copilot_run" 'any(.[]; .name == $run and .status != "completed")') || return 1
	fi
	if [ "$pending" = true ]; then
		echo "pending requested or running"
		return 0
	fi
	reviews=$(rest_list "repos/$repo/pulls/$pr/reviews") || return 1
	# The newest review of this head, as id, time, unable, verdict, and the
	# sum of its body sections' counts (Suppressed comments, Previously
	# missed, Open), split by $sep.
	newest=$(printf '%s' "$reviews" | j -r --arg sha "$sha" '
		[.[] | select(.user.login == "copilot-pull-request-reviewer[bot]" and .commit_id == $sha)]
		| sort_by(.submitted_at) | last // empty
		| (.body // "") as $b
		| [.id, .submitted_at,
		   ($b | test("^\\s*(<!--[^>]*-->\\s*)?(## Copilot review overview\\s*)?Copilot was unable to review")),
		   ((first($b | capture("###[ \\t]+(?<v>(🟢|🟡|🔵)[^\\n]*)")) // {v: ""}).v),
		   ([$b | scan("(Suppressed comments|Previously missed|Open) \\(([0-9]+)\\)") | .[1] | tonumber] | add // 0)]
		| map(tostring) | join("\u001f")') || return 1
	[ -z "$newest" ] || IFS=$sep read -r id at unable verdict sections <<<"$newest"
	if [ -n "$newest" ] && [ "$unable" = false ]; then
		comments=$(rest_list "repos/$repo/pulls/$pr/reviews/$id/comments") || return 1
		comments=$(printf '%s' "$comments" | j length) || return 1
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
	if [ -n "$newest" ]; then
		# An unable body is not a review, and REVIEW_BOT retries it once: report
		# it, unless a request for Copilot came after it (under either of its
		# logins, as the pending check reads them). A retry found once stays
		# found, so the timeline isn't read again on every pass.
		if [ -f "$tmp/retried-$id" ]; then
			retried=true
		else
			retried=$(rest_list "repos/$repo/issues/$pr/timeline") || return 1
			retried=$(printf '%s' "$retried" | j -r --arg at "$at" '
				any(.[]; .event == "review_requested"
				         and ((.requested_reviewer.login // "") | test("^(Copilot|copilot-pull-request-reviewer(\\[bot\\])?)$"))
				         and (.created_at // "") > $at)') || return 1
			[ "$retried" = false ] || : >"$tmp/retried-$id"
		fi
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
	[ -z "$state" ] || return 0 # merged, closed, moved, or still syncing
	"poll_$sub"
}

emit() { printf '%s #%s %s: %s%s\n' "$sub" "$pr" "${sha:0:12}" "$state" "${detail:+ $detail}"; }

remaining() { echo $((timeout - (SECONDS - start))); }

timed_out() { # timed_out <what was last seen>: exit 4
	state=timeout detail="after $(fmt "$timeout"); last: $1"
	emit
	emit >&2
	exit 4
}

# The wait keeps to its own deadline, retries included, so a caller's outer
# limit set a little past --timeout (Monitor's, say) always sees its last line.
last=
while :; do
	attempt=1
	delay=$retry_delay
	rm -f "$tmp/last-err"
	until poll; do
		budget=$attempts
		transient && budget=$transient_attempts
		if [ "$attempt" -ge "$budget" ]; then
			state=error detail="a read failed $attempt times in a row: $(head -n 1 "$tmp/last-err" 2>/dev/null)"
			emit
			emit >&2
			exit 2
		fi
		[ "$(remaining)" -gt "$delay" ] || timed_out "a read failing: $(head -n 1 "$tmp/last-err" 2>/dev/null)"
		echo "pr-wait.sh: read failed (try $attempt of $budget); retrying in ${delay}s" >&2
		sleep "$delay"
		attempt=$((attempt + 1))
		delay=$((delay * 2))
		[ "$delay" -le 60 ] || delay=60
	done
	line=$(emit)
	[ "$line" = "$last" ] || printf '%s\n' "$line"
	last=$line
	case $state in
	green | clean | mergeable) exit 0 ;;
	failed | findings | conflicting) exit 1 ;;
	moved) exit 3 ;;
	none | idle | unable) exit 5 ;;
	merged | closed) exit 6 ;;
	esac
	left=$(remaining)
	[ "$left" -gt 0 ] || timed_out "${last#*: }"
	if [ "$left" -lt "$interval" ]; then sleep "$left"; else sleep "$interval"; fi
done
