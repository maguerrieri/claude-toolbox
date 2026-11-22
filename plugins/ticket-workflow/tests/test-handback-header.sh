#!/usr/bin/env bash
# Tests for scripts/handback-header.sh, the line a hand-back, a child's ping
# and a relay lead with (START Step 9, messaging.md's *Naming a PR*):
#
# - the issue comes from --issue, else, for this session's own PR (the
#   current branch's), the role marker's one issue: line, else the one issue
#   the PR's body closes; another session's PR never takes this session's
#   issue; a Jira key is printed as it is;
# - the PR comes from gh pr view (on --pr or the current branch), with a REST
#   read of the repo a URL names when gh pr view fails (a cloud session), and
#   never from origin, so a fork's checkout links the upstream PR; a --pr it
#   can't read exits 1;
# - the session link comes only from where the spawn skill's backend files
#   say: CLAUDE_CODE_REMOTE_SESSION_ID's plain session_ (or cse_) id, or a
#   local job's state.json bridgeSessionId, the same read as
#   backends/local.md's snippet, run on the same job files; anything else
#   leaves no link; --core prints the issue and PR alone;
# - no marker, no PR, Remote Control off, or a failed session read leaves that
#   part out and still exits 0; a bad or empty argument exits 2;
# - START Step 9's documented run prints the header, every doc that writes a
#   PR-naming line points at messaging.md's *Naming a PR*, and the older
#   PR-alone forms appear only where a receiver is told to accept them.
#
# gh is replaced by a stub that runs the script's own --jq filter over:
#   STUB_PR     the JSON gh pr view reads, or `graphql` for the cloud proxy's
#               refusal; empty means no PR for the branch
#   STUB_REST   the JSON the REST read gets; empty fails it
# Each run's cwd is a repo on branch `feature` (HH_CWD overrides it), so a
# PR whose head is `feature` is this session's own.
#
#   bash plugins/ticket-workflow/tests/test-handback-header.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
spawn_plugin=$(cd "$plugin/../spawn" && pwd)
script="$plugin/scripts/handback-header.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

cat >"$tmp/gh" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_ARGS"
filter=''
prev=''
for a in "$@"; do
	[ "$prev" = --jq ] && filter=$a
	prev=$a
done
case "$1 ${2:-}" in
'pr view')
	case "${STUB_PR:-}" in
	'') echo 'no pull requests found for branch "x"' >&2; exit 1 ;;
	graphql) echo 'GitHub GraphQL is not available from Claude Code sessions; use the REST API' >&2; exit 1 ;;
	esac
	printf '%s' "$STUB_PR" | jq -r "$filter"
	;;
api*)
	[ -n "${STUB_REST:-}" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
	printf '%s' "$STUB_REST" | jq -r "$filter"
	;;
*) echo "unexpected gh $*" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$tmp/gh"

mkdir -p "$tmp/roles" "$tmp/home"
git init -q -b feature "$tmp/repo"
git init -q -b feature "$tmp/fork" && git -C "$tmp/fork" remote add origin https://github.com/someone/r.git

# hh [VAR=value ...] [-- script args ...]: the script's output, run in
# ${HH_CWD:-$tmp/repo} in an environment holding only these variables, with
# this session's marker under $tmp/roles (session t1). Each run's gh calls
# are in $tmp/args, and every run's in $tmp/all-args.
hh() {
	local vars=()
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		vars+=("$1")
		shift
	done
	[ $# -eq 0 ] || shift
	: >"$tmp/args"
	(cd "${HH_CWD:-$tmp/repo}" && env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_ROLES_DIR="$tmp/roles" \
		CLAUDE_CODE_SESSION_ID=t1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
		HANDBACK_HEADER_GH="$tmp/gh" STUB_ARGS="$tmp/args" ${vars[@]+"${vars[@]}"} \
		bash "$script" "$@" 2>/dev/null)
	last_exit=$?
	cat "$tmp/args" >>"$tmp/all-args"
}
# code [VAR=value ...] [-- script args ...]: the script's exit code.
code() {
	hh "$@" >/dev/null
	printf '%s' "$last_exit"
}
marker() { # marker <content>: this session's role marker, or none for ''
	rm -f "$tmp/roles/t1"
	[ -z "$1" ] || printf '%s\n' "$1" >"$tmp/roles/t1"
}
job() { # job <dir> <state.json text>
	mkdir -p "$1" && printf '%s\n' "$2" >"$1/state.json"
}
pr_json() { # pr_json <number> <url> <body> [<head branch>, feature by default]
	jq -cn --argjson n "$1" --arg u "$2" --arg b "$3" --arg h "${4:-feature}" \
		'{number: $n, url: $u, headRefName: $h, body: $b}'
}
rest_json() { # rest_json <number> <html_url> <body> [<head branch>]
	jq -cn --argjson n "$1" --arg u "$2" --arg b "$3" --arg h "${4:-feature}" \
		'{number: $n, html_url: $u, head: {ref: $h}, body: $b}'
}

url=https://github.com/o/r/pull/360
own=$(pr_json 360 "$url" $'## Summary\n- x\n\nCloses #356\n')
other=https://github.com/o/r/pull/361
job "$tmp/job-on" '{"bridgeSessionId": "cse_01ABCDEFGHJKMNPQRSTVWXYZ", "bridgeOutboundOnly": false}'
job "$tmp/job-off" '{"bridgeSessionId": null, "bridgeOutboundOnly": null}'
job "$tmp/job-bad" 'not json'
mkdir -p "$tmp/job-empty"
link=https://claude.ai/code/session_01ABCDEFGHJKMNPQRSTVWXYZ

# --- Each part, and each part missing ---------------------------------------

marker ''
record '' "no marker, no PR, no session: an empty line" "$(hh)"
record 0 "and it still exits 0" "$(code)"
record 'gh: pr view --json number,url,headRefName,body' "the PR is the current branch's, through gh pr view" \
	"$(hh >/dev/null; sed -E 's/ --jq .*//; s/^/gh: /' "$tmp/args")"

marker $'implementer\nissue: 356\nnotify: x'
record '#356' "the marker's issue, with no PR yet" "$(hh)"
record 0 "no PR yet, with no --pr, still exits 0" "$(code)"
record "#356 → PR #360 · $url" "the issue and the PR" "$(hh STUB_PR="$own")"
record "#356 → PR #360 · $url · session $link" "and the session, from CLAUDE_JOB_DIR's state.json" \
	"$(hh STUB_PR="$own" CLAUDE_JOB_DIR="$tmp/job-on")"
record "#356 · session $link" "no PR yet keeps the issue and the session" "$(hh CLAUDE_JOB_DIR="$tmp/job-on")"
record "#356 → PR #360 · $url" "Remote Control off (bridgeSessionId null): no session part" \
	"$(hh STUB_PR="$own" CLAUDE_JOB_DIR="$tmp/job-off")"
record "#356 → PR #360 · $url" "a job file that isn't JSON: no session part" \
	"$(hh STUB_PR="$own" CLAUDE_JOB_DIR="$tmp/job-bad")"
record "#356 → PR #360 · $url" "a job directory with no state.json: no session part" \
	"$(hh STUB_PR="$own" CLAUDE_JOB_DIR="$tmp/job-empty")"
record 0 "a failed session read still exits 0" "$(code STUB_PR="$own" CLAUDE_JOB_DIR="$tmp/job-bad")"
record "#356 → PR #360 · $url" "--no-session leaves this session's link out" \
	"$(hh STUB_PR="$own" CLAUDE_JOB_DIR="$tmp/job-on" -- --no-session)"
record "#356 → PR #360" "--core prints the issue and the PR alone, no URL or session" \
	"$(hh STUB_PR="$own" CLAUDE_JOB_DIR="$tmp/job-on" -- --core)"

marker ''
record "#356 → PR #360 · $url" "no marker: the one issue the PR closes" "$(hh STUB_PR="$own")"
record "PR #360 · $url" "no marker and a PR closing two issues: no issue part" \
	"$(hh STUB_PR="$(pr_json 360 "$url" $'Closes #356\nCloses #304')")"
record "PR #360 · $url" "no marker and a PR closing none" "$(hh STUB_PR="$(pr_json 360 "$url" 'No footer')")"
record "PR #360 · $url" "a PR with a null body" \
	"$(hh STUB_PR='{"number": 360, "url": "https://github.com/o/r/pull/360", "headRefName": "feature", "body": null}')"

# --- Which issue ------------------------------------------------------------

marker $'implementer\nissue: 356'
record "#356 → PR #360 · $url" "this session's PR keeps the recorded issue, among two it closes" \
	"$(hh STUB_PR="$(pr_json 360 "$url" $'Closes #304\nCloses #356')")"
record "#356 → PR #360 · $url" "and with --pr naming it, its head being this branch" \
	"$(hh STUB_PR="$(pr_json 360 "$url" 'Closes #304')" -- --pr "$url")"
record "#356 → PR #360 · $url" "a body with no closing keyword (Jira's PR_REF) keeps the recorded issue" \
	"$(hh STUB_PR="$(pr_json 360 "$url" 'Implements it.')")"
record "#346 → PR #361 · $other" "another session's PR takes its own issue, not this session's" \
	"$(hh STUB_PR="$(pr_json 361 "$other" 'Closes #346' other)" -- --pr 361)"
record "PR #361 · $other" "another session's PR closing two issues: no issue part" \
	"$(hh STUB_PR="$(pr_json 361 "$other" $'Closes #1\nCloses #2' other)" -- --pr 361)"
record "PR #361 · $other" "another session's PR closing none (Jira): no issue part, never this session's" \
	"$(hh STUB_PR="$(pr_json 361 "$other" 'Implements ABC-13' other)" -- --pr 361)"
record "PR #361" "and its --core" "$(hh STUB_PR="$(pr_json 361 "$other" 'Implements ABC-13' other)" -- --pr 361 --core)"
record "#356 → PR #360 · $url" "another branch's PR that closes the recorded issue keeps it (past FINISH Step 4)" \
	"$(hh STUB_PR="$(pr_json 360 "$url" $'Closes #304\nCloses #356' gone)" -- --pr "$url")"
record "PR #360 · $url" "but not one closing two other issues" \
	"$(hh STUB_PR="$(pr_json 360 "$url" $'Closes #304\nCloses #305' gone)" -- --pr "$url")"
record "#999 → PR #360 · $url" "outside a repo (no current branch), a --pr is another's" \
	"$(HH_CWD="$tmp" hh STUB_PR="$(pr_json 360 "$url" 'Closes #999')" -- --pr "$url")"
record "#999 → PR #360 · $url" "--issue wins over the marker and the PR" "$(hh STUB_PR="$own" -- --issue 999)"
record "#999" "--issue with a leading #" "$(hh -- --issue '#999')"
record "ABC-12 → PR #360 · $url" "a Jira key, printed as it is" "$(hh STUB_PR="$own" -- --issue ABC-12)"
marker $'implementer\nissue: ABC-12'
record "ABC-12" "a Jira key from the marker" "$(hh)"
record "ABC-12 → PR #360 · $url" "an incidental closing keyword in this session's own PR doesn't replace its key" \
	"$(hh STUB_PR="$(pr_json 360 "$url" 'Implements ABC-12; fixes #45 in the vendored lib')")"
marker $'implementer\nissue: 356\nissue: 357'
record "PR #360 · $url" "two recorded issues, the PR closing two others: no issue part" \
	"$(hh STUB_PR="$(pr_json 360 "$url" 'Closes #1, closes #2')")"
record "#357 → PR #360 · $url" "two recorded issues: the one the PR closes" \
	"$(hh STUB_PR="$(pr_json 360 "$url" 'Closes #357')")"
record "" "two recorded issues and no PR: no issue part" "$(hh)"
marker 'planner'
record "#356 → PR #360 · $url" "a marker with no issue line: the PR's" "$(hh STUB_PR="$own")"

marker ''
for body in 'Fixes #12' 'fixed #12' 'Resolves: #12' 'resolved #12' 'close #12' $'Closes #12\ncloses #12'; do
	record "#12 → PR #360 · $url" "the closing keyword in '${body//$'\n'/ | }'" \
		"$(hh STUB_PR="$(pr_json 360 "$url" "$body")")"
done
for body in 'See #12' 'Closes o/x#12' 'Discloses #12' 'Closes #12x'; do
	record "PR #360 · $url" "no closing reference in '$body'" "$(hh STUB_PR="$(pr_json 360 "$url" "$body")")"
done

# --- Which PR ---------------------------------------------------------------

marker $'implementer\nissue: 356'
hh STUB_PR="$own" -- --pr "$url" >/dev/null
record "pr view $url --json number,url,headRefName,body" "--pr is passed to gh pr view as it is" \
	"$(sed -E 's/ --jq .*//' "$tmp/args")"

# A fork's checkout: origin is the fork, and the PR is upstream's. The script
# never reads origin: gh pr view on the URL, or the REST read of the repo the
# URL names.
up=https://github.com/up/r/pull/7
: >"$tmp/all-args"
record "#356 → PR #7 · $up" "a fork's checkout links the upstream PR gh reports" \
	"$(HH_CWD="$tmp/fork" hh STUB_PR="$(pr_json 7 "$up" 'Closes #356')" -- --pr "$up")"
record "#356 → PR #7 · $up" "and, with gh pr view refused, the REST read of the URL's repo" \
	"$(HH_CWD="$tmp/fork" hh STUB_PR=graphql STUB_REST="$(rest_json 7 "$up" 'Closes #356')" -- --pr "$up")"
record "api --hostname github.com repos/up/r/pulls/7" "the REST read names the URL's host and repo, not origin's" \
	"$(grep '^api' "$tmp/all-args" | sed -E 's/ --jq .*//')"
record 3 "both fork runs' gh calls were seen" "$(grep -c . "$tmp/all-args")"
record 0 "no gh call in either names the fork" "$(grep -c someone "$tmp/all-args")"

ghe=https://ghe.example.com/o/r/pull/5
hh STUB_PR=graphql STUB_REST="$(rest_json 5 "$ghe" '')" -- --pr "$ghe" >/dev/null
record "api --hostname ghe.example.com repos/o/r/pulls/5" "another host's URL reads that host" \
	"$(grep '^api' "$tmp/args" | sed -E 's/ --jq .*//')"
hh STUB_PR=graphql STUB_REST="$(rest_json 360 "$url" '')" GH_HOST=ghe.example.com -- --pr "$url" >/dev/null
record "api --hostname github.com repos/o/r/pulls/360" "a github.com URL names its host even with GH_HOST set to another" \
	"$(grep '^api' "$tmp/args" | sed -E 's/ --jq .*//')"
record "#356" "gh pr view refused for a number: no REST guess at the repo" \
	"$(hh STUB_PR=graphql STUB_REST="$(rest_json 360 "$url" '')" -- --pr 360)"
record 0 "and no REST read" "$(hh STUB_PR=graphql -- --pr 360 >/dev/null; grep -c '^api' "$tmp/args")"
record "#356" "both reads failing: no PR part" "$(hh STUB_PR=graphql -- --pr "$url")"
record 1 "and a --pr it couldn't read exits 1, so the caller adds the URL it holds" \
	"$(code STUB_PR=graphql -- --pr "$url")"
record 1 "as does a --pr number gh pr view can't find" "$(code -- --pr 360)"

for bad in '{"number": 360, "url": "https://github.com/o/r/pull/361", "body": ""}' \
	'{"number": 360, "url": "javascript:alert(1)//pull/360", "body": ""}' \
	'{"number": 360, "url": "https://github.com/o/r/pull/360 https://evil/pull/360", "body": ""}' \
	'{"number": 360, "url": "https://github.com/o/r/pull/360\nhttps://evil", "body": ""}' \
	'{"number": 360, "url": "https://github.com/o/r/pull/360", "headRefName": "a\tb", "body": ""}' \
	'{"number": "360x", "url": "https://github.com/o/r/pull/360", "body": ""}' \
	'{"number": 360, "url": "https://github.com/o/r/issues/360", "body": ""}' \
	'{"url": "https://github.com/o/r/pull/360"}'; do
	record "#356" "a PR read that isn't well formed is left out: $bad" "$(hh STUB_PR="$bad")"
done

# --- Which session ----------------------------------------------------------

marker $'implementer\nissue: 356'
record "#356 · session https://claude.ai/code/session_01XYZ" "a cloud session's own session_ id" \
	"$(hh CLAUDE_CODE_REMOTE_SESSION_ID=session_01XYZ)"
record "#356 · session https://claude.ai/code/session_01XYZ" "a cloud cse_ id, mapped as backends/local.md records" \
	"$(hh CLAUDE_CODE_REMOTE_SESSION_ID=cse_01XYZ)"
record "#356 · session https://claude.ai/code/session_01XYZ" "the cloud id wins over a job directory" \
	"$(hh CLAUDE_CODE_REMOTE_SESSION_ID=session_01XYZ CLAUDE_JOB_DIR="$tmp/job-on")"
for bad in session_ cse_ 'session_01](https://evil' 'session_01 x' $'session_01\nx' $'cse_01\n' 'session_a_b' x; do
	record "#356" "a cloud id that isn't a plain session_ or cse_ id: '$bad'" \
		"$(hh CLAUDE_CODE_REMOTE_SESSION_ID="$bad" CLAUDE_JOB_DIR="$tmp/job-on")"
done
record "#356" "a terminal session (no job directory, not cloud): no session part" "$(hh)"
record "#356 · session https://claude.ai/code/session_01XYZ" "--session with a session_ id (a cloud child)" \
	"$(hh -- --session session_01XYZ)"

# --session <short id> is backends/local.md's read: run its snippet and the
# script on the same job files and expect the same link, or none, for each.
local_md="$spawn_plugin/skills/spawn/backends/local.md"
ids="a0000001 a0000002 a0000003 a0000004 a0000005 a0000006 a0000007 a0000008 a0000009 a0000010"
snippet=$(extract_block "$local_md" '.bridgeSessionId' | sed "s/<short id> <short id>/$ids/")
record yes "link snippet found in local.md" "$([ -n "$snippet" ] && echo yes || echo no)"
cfg="$tmp/config"
mk() { mkdir -p "$cfg/jobs/$1" && printf '%s\n' "$2" >"$cfg/jobs/$1/state.json"; }
mk a0000001 '{"bridgeSessionId": "cse_01ABCDEFGHJKMNPQRSTVWXYZ", "bridgeOutboundOnly": false}'
mk a0000002 '{"bridgeSessionId": null}'
mk a0000003 '{"state": "done"}'
mk a0000005 '{"bridgeSessionId": "cse_abc\n"}'
mk a0000006 '{"bridgeSessionId": "session_01ABCDEFGHJKMNPQRSTVWXYZ"}'
mk a0000007 '{"bridgeSessionId": 12}'
mk a0000008 'not json'
mk a0000009 '{"bridgeSessionId": "cse_ab](https://example.com/x"}'
mk a0000010 '{"bridgeSessionId": "cse_"}'
from_doc=$(CLAUDE_CONFIG_DIR="$cfg" bash -c "$snippet" 2>/dev/null)
marker ''
from_script=$(for id in $ids; do
	got=$(hh CLAUDE_CONFIG_DIR="$cfg" -- --session "$id")
	got=${got#session }
	printf '%s\t%s\n' "$id" "${got:--}"
done)
record "$from_doc" "--session <short id> links exactly what local.md's read does" "$from_script"
record "session $link" "and finds \$HOME/.claude's jobs without CLAUDE_CONFIG_DIR" \
	"$(mkdir -p "$tmp/home/.claude/jobs" && cp -R "$cfg/jobs/a0000001" "$tmp/home/.claude/jobs/" && hh -- --session a0000001)"
record "session $link" "--session wins over this session's own job" \
	"$(hh CLAUDE_CONFIG_DIR="$cfg" CLAUDE_JOB_DIR="$tmp/job-off" -- --session a0000001)"

# --- Usage ------------------------------------------------------------------

usage_case() { # usage_case <script args ...>: expect exit 2
	record 2 "usage error: $*" "$(code CLAUDE_JOB_DIR="$tmp/job-on" -- "$@")"
}
usage_case --pr 'x;y'
usage_case --pr https://github.com/o/r/issues/1
usage_case --pr "$(printf '%s\n%s' "$url" "$url")"
usage_case --pr
usage_case --pr ''
usage_case --issue 'a b'
usage_case --issue -x
usage_case --issue
usage_case --issue ''
usage_case --session ../x
usage_case --session a/b
usage_case --session _x
usage_case --session ''
usage_case --session a0000001 --no-session
usage_case --core --session a0000001
usage_case --bogus
usage_case extra

# --- The docs ---------------------------------------------------------------

skill="$plugin/skills/ticket-workflow"
repo=$(cd "$plugin/../.." && pwd)

# START Step 9's documented run, with its placeholder filled, prints the header.
step9=$(extract_block "$skill/SKILL.md" 'handback-header.sh" --pr <pr url>')
record yes "START Step 9's header block found in SKILL.md" "$([ -n "$step9" ] && echo yes || echo no)"
marker $'implementer\nissue: 356'
record "#356 → PR #360 · $url · session $link" "START Step 9's block, run as documented, prints the header" \
	"$(cd "$tmp/repo" && : >"$tmp/args" && env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_ROLES_DIR="$tmp/roles" \
		CLAUDE_CODE_SESSION_ID=t1 HANDBACK_HEADER_GH="$tmp/gh" STUB_ARGS="$tmp/args" STUB_PR="$own" \
		CLAUDE_JOB_DIR="$tmp/job-on" CLAUDE_TICKET_WORKFLOW_ROOT="$plugin" \
		bash -c "${step9//<pr url>/$url}" 2>/dev/null)"

# Every doc that writes a PR-naming line points at the one definition, and the
# older forms that name the PR alone appear only where a receiver is told to
# accept them: a paragraph (blank-line separated) holding one says "older
# sender".
for f in SKILL.md messaging.md notifier.md phases/finish.md phases/epic.md \
	roles/implementer.md roles/planner.md roles/epic-coordinator.md profiles/default.md; do
	record yes "$f names messaging.md's *Naming a PR* or the header script" \
		"$(grep -q 'Naming a PR\|handback-header\.sh' "$skill/$f" && echo yes || echo no)"
done
old_forms='(finish|merged): #<pr>|raise: cap <[a-z]+> on PR #|request: PR #|resumed: [a-z]+( <[a-z]+>)? on PR #|restack: #<(parent|pr)>|restack #<(pr|yours|child|dependent)> onto|PR #<pr> needs the owner'
scan_old() { # scan_old <file>: one line per paragraph using a PR-alone form without saying "older sender"
	awk -v f="${1#"$repo/"}" -v re="$old_forms" '
		function check() { if (para ~ re && tolower(para) !~ /older sender/) print f ": " substr(para, 1, 80); para = "" }
		/^[ \t]*$/ { check(); next }
		{ para = para " " $0 }
		END { check() }
	' "$1"
}
printf '%s\n' 'ping `merged: #<pr>` when done' '' 'then `raise: cap <n> on PR #<pr>`' '' \
	'An older sender may send `finish: #<pr> (grant: …)`.' '' 'answers `resumed: cap <n> on PR #<pr>`' '' \
	'`restack: #<parent> merged into main;' 'restack #<yours> onto main`' >"$tmp/old.md"
record 4 "the scan finds each PR-alone form outside an older-sender paragraph" "$(scan_old "$tmp/old.md" | grep -c .)"
older=$(find "$skill" "$plugin/commands" -name '*.md' -print | sort | while read -r f; do scan_old "$f"; done)
record "" "the PR-alone forms appear only where a receiver accepts an older sender" "$older"
record yes "messaging.md's *Naming a PR* lists the older forms" \
	"$(awk '/^## Naming a PR/{on=1} on && /^\*\*Older senders/{print "yes"; exit}' "$skill/messaging.md")"

finish
