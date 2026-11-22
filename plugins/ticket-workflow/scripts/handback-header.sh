#!/usr/bin/env bash
# handback-header.sh — the line a hand-back, a child's ping and a relay lead
# with: the issue, the PR as a link, and the session's page on claude.ai/code,
# each read from data rather than from the session's memory. START Step 9 and
# messaging.md (*Naming a PR*) say where it goes.
#
#   handback-header.sh [--issue <id>] [--pr <number | url>]
#                      [--session <job short id | session_ id> | --no-session]
#
# It prints one line, such as
#
#   #356 → PR #360 · https://github.com/OWNER/REPO/pull/360 · session https://claude.ai/code/session_01…
#
# Its start, `#<issue> → PR #<pr>`, is the core every ticket-workflow line that
# names a PR uses. A Jira issue is its key (`ABC-12 → PR #360`). A part that
# can't be had is left out, never guessed: with no PR the line is
# `#356 · session …`, with no issue `PR #360 · …`, and with nothing at all it
# is empty.
#
# The issue: --issue, else the role marker's `issue:` line when it has exactly
# one (read through role-marker.sh show). The issues the PR's body closes
# (`Closes #<n>`, as the github tracker's PR_REF writes it) check that: when
# the body closes any and the recorded issue isn't one of them, the issue is
# the one the body closes, or none when it closes several. With no recorded
# issue, it is the one the body closes, when it closes exactly one.
#
# The PR: gh pr view on --pr, or on the current branch without it, so gh's own
# resolution picks the repo (in a fork's checkout, pass the PR's URL). When gh
# pr view fails on a URL (a cloud session, whose proxy refuses the GraphQL it
# uses), the PR is read over REST from the repo the URL names. Its URL is
# printed only in the shape https://<host>/<owner>/<repo>/pull/<n>.
#
# The session: this session's own page by default, or another's with --session
# (a relay naming a child's), or none with --no-session. The address comes only
# from where the spawn skill's backend files say (their *Session links*):
# - a cloud session (CLAUDE_CODE_REMOTE_SESSION_ID set, the spawn skill's
#   backend test): https://claude.ai/code/<id>, only for a plain session_ id;
# - a local background job: its state.json's bridgeSessionId, a plain cse_ id,
#   as https://claude.ai/code/session_<the same suffix>. Its own job directory
#   is CLAUDE_JOB_DIR; --session <short id> reads
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs/<short id>/. That file is not a
#   stable interface (backends/local.md), so any other shape leaves no link.
# A terminal session, Remote Control off, or a failed read leaves no session
# part.
#
# The link is the owner's own: it goes in replies to the owner and in pings,
# never in a PR, an issue, a comment or a COORD marker.
#
# Exits 0 whatever it could read, and 2 on a usage error. HANDBACK_HEADER_GH
# overrides the gh binary (the tests' stub).
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
# Bytes, not characters, so the patterns below match only ASCII letters and
# digits whatever the caller's locale.
export LC_ALL=C

here=$(dirname "${BASH_SOURCE[0]}")
gh_bin=${HANDBACK_HEADER_GH:-gh}

usage() {
	echo 'usage: handback-header.sh [--issue <id>] [--pr <number | url>] [--session <job short id | session_ id> | --no-session]' >&2
	exit 2
}

issue='' pr_arg='' session_arg='' no_session=''
while [ $# -gt 0 ]; do
	case "$1" in
	--issue)
		[ $# -ge 2 ] || usage
		issue=${2#\#}
		shift 2
		;;
	--pr)
		[ $# -ge 2 ] || usage
		pr_arg=$2
		shift 2
		;;
	--session)
		[ $# -ge 2 ] || usage
		session_arg=$2
		shift 2
		;;
	--no-session)
		no_session=1
		shift
		;;
	*) usage ;;
	esac
done

# The same id rule role-marker.sh applies to the issue it records.
issue_ok() {
	case "$1" in
	'' | [!A-Za-z0-9]* | *[!A-Za-z0-9_-]*) return 1 ;;
	esac
	[ "${#1}" -le 64 ]
}
# A PR URL as gh prints it, and nothing else on the line.
pr_url_ok() {
	printf '%s' "$1" | grep -Eq '^https://[A-Za-z0-9.-]+/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+$' &&
		[ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" = 1 ]
}

if [ -n "$issue" ]; then issue_ok "$issue" || usage; fi
if [ -n "$pr_arg" ]; then
	case "$pr_arg" in
	*[!0-9]*) pr_url_ok "$pr_arg" || usage ;;
	esac
fi
if [ -n "$session_arg" ]; then
	[ -z "$no_session" ] || usage
	case "$session_arg" in
	*[!A-Za-z0-9_]* | _*) usage ;;
	esac
fi

# --- The PR -----------------------------------------------------------------

# Every closing keyword GitHub reads, followed by a same-repo #<n>.
closes='[(.body // "") | scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\\s+#([0-9]+)\\b") | .[0]] | unique | join(",")'
pr_number='' pr_url='' pr_closes=''
read_pr() { # read_pr <tab-separated number, url, closes>: keep it if well formed
	local n u c
	case "$1" in *$'\n'*) return 1 ;; esac
	IFS=$'\t' read -r n u c <<EOF
$1
EOF
	case "$n" in '' | *[!0-9]*) return 1 ;; esac
	pr_url_ok "$u" || return 1
	case "$u" in */pull/"$n") ;; *) return 1 ;; esac
	pr_number=$n pr_url=$u pr_closes=$c
}
got=$("$gh_bin" pr view ${pr_arg:+"$pr_arg"} --json number,url,body \
	--jq "\"\\(.number)\\t\\(.url)\\t\" + ($closes)" 2>/dev/null) && read_pr "$got"
if [ -z "$pr_number" ] && pr_url_ok "$pr_arg"; then
	rest=${pr_arg#https://}
	host=${rest%%/*}
	rest=${rest#*/}
	owner=${rest%%/*}
	rest=${rest#*/}
	repo=${rest%%/*}
	number=${rest##*/}
	host_args=()
	[ "$host" = github.com ] || host_args=(--hostname "$host")
	got=$("$gh_bin" api ${host_args[@]+"${host_args[@]}"} "repos/$owner/$repo/pulls/$number" \
		--jq "\"\\(.number)\\t\\(.html_url)\\t\" + ($closes)" 2>/dev/null) && read_pr "$got"
fi

# --- The issue --------------------------------------------------------------

if [ -z "$issue" ]; then
	recorded=''
	marker=$(bash "$here/role-marker.sh" show 2>/dev/null)
	issues=$(printf '%s\n' "$marker" | sed -n 's/^issue: //p')
	if [ -n "$issues" ] && [ "$(printf '%s\n' "$issues" | wc -l | tr -d ' ')" = 1 ] && issue_ok "$issues"; then
		recorded=$issues
	fi
	# A PR whose body closes issues settles it: the recorded issue when the PR
	# closes it, else the one issue the PR closes, so a PR that isn't this
	# session's own never takes this session's issue.
	case ",$pr_closes," in
	,,) issue=$recorded ;;
	*",$recorded,"*) issue=$recorded ;;
	*,*,*,*) ;;
	*) issue=$pr_closes ;;
	esac
fi
case "$issue" in
'') ;;
*[!0-9]*) ;; # a Jira key, written as it is
*) issue="#$issue" ;;
esac

# --- The session ------------------------------------------------------------

# The filter backends/local.md's *Session links* runs; the tests run both on
# the same job files.
job_link='.bridgeSessionId | strings | select(test("\\Acse_[A-Za-z0-9]+\\z")) | "https://claude.ai/code/session_" + ltrimstr("cse_")'
plain_suffix() { # plain_suffix <text> <prefix>: <text> is <prefix>, then letters and digits only
	case "$1" in "$2"*) ;; *) return 1 ;; esac
	case "${1#"$2"}" in '' | *[!A-Za-z0-9]*) return 1 ;; esac
}
cloud_link() { # cloud_link <id>: the page of a plain session_ id (backends/cloud.md)
	plain_suffix "$1" session_ && printf 'https://claude.ai/code/%s' "$1"
}
session=''
if [ -z "$no_session" ]; then
	if [ -n "$session_arg" ]; then
		case "$session_arg" in
		session_*) session=$(cloud_link "$session_arg") ;;
		*) session=$(jq -r "$job_link" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs/$session_arg/state.json" 2>/dev/null) ;;
		esac
	elif [ -n "${CLAUDE_CODE_REMOTE_SESSION_ID:-}" ]; then
		session=$(cloud_link "$CLAUDE_CODE_REMOTE_SESSION_ID")
	elif [ -n "${CLAUDE_JOB_DIR:-}" ]; then
		session=$(jq -r "$job_link" "$CLAUDE_JOB_DIR/state.json" 2>/dev/null)
	fi
	# One plain URL or nothing.
	plain_suffix "$session" https://claude.ai/code/session_ || session=''
fi

# --- The line ---------------------------------------------------------------

line=$issue
if [ -n "$pr_number" ]; then
	line="${line:+$line → }PR #$pr_number · $pr_url"
fi
[ -z "$session" ] || line="${line:+$line · }session $session"
printf '%s\n' "$line"
exit 0
