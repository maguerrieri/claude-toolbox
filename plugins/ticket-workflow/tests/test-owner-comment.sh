#!/usr/bin/env bash
# Tests for scripts/owner-comment.sh, which says whether a comment's current
# words are the owner's: owner-check.sh on its author and, once another login
# has edited it, on its last editor too. Exit 0 (the owner's), 3 (the
# sessions' own admin login, unedited or self-edited), 1 (anything else); on 0
# and 3 it prints the text it checked. owner-check.sh runs for real, and gh is
# a stub that answers each read with JSON and applies the caller's --jq filter
# with jq:
#   STUB_ME, STUB_PERMS   the sessions' login, and "login=permission ..." pairs
#   STUB_AUTHOR, STUB_AUTHOR_TYPE, STUB_HTML, STUB_BODY
#                         the REST item (an empty author: a deleted account)
#   STUB_REST_FAIL        set: the REST item read fails
#   STUB_EDITOR, STUB_EDITOR_TYPE, STUB_EDITED_AT, STUB_GQL_BODY, STUB_GQL_TYPE
#                         the GraphQL node (an empty editor type: editor null)
#   STUB_GQL_FAIL         set: GraphQL is refused, as behind the cloud proxy
#
#   bash plugins/ticket-workflow/tests/test-owner-comment.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
script="$plugin/scripts/owner-comment.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

command -v jq >/dev/null || {
	echo 'test-owner-comment.sh needs jq' >&2
	exit 1
}

cat >"$tmp/gh" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_ARGS"
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
endpoint=$2
filter=.
shift 2
while [ $# -gt 0 ]; do
	case $1 in
	--jq) filter=$2; shift 2 ;;
	*) shift ;;
	esac
done
answer() { jq -r "$filter" <<<"$1"; }
case $endpoint in
user) answer "$(jq -n --arg l "${STUB_ME:-}" '{login: $l}')" ;;
repos/*/collaborators/*/permission)
	who=${endpoint%/permission}
	who=$(lower "${who##*/}")
	for pair in ${STUB_PERMS:-}; do
		[ "$(lower "${pair%%=*}")" = "$who" ] && { answer "$(jq -n --arg p "${pair#*=}" '{permission: $p}')"; exit 0; }
	done
	answer '{"permission": "none"}'
	;;
repos/*/issues/comments/* | repos/*/pulls/comments/* | repos/*/pulls/*/reviews/*)
	[ -z "${STUB_REST_FAIL:-}" ] || { echo '{"message": "Not Found"}'; exit 1; }
	answer "$(jq -n --arg login "${STUB_AUTHOR-maguerrieri}" --arg type "${STUB_AUTHOR_TYPE-User}" \
		--arg html "${STUB_HTML:-}" --arg body "${STUB_BODY-the owner asks}" \
		'{user: (if $login == "" then null else {login: $login, type: $type} end),
		  node_id: "IC_kwDOnode", html_url: $html, body: $body}')"
	;;
graphql)
	[ -z "${STUB_GQL_FAIL:-}" ] || {
		echo 'HTTP 403: GitHub GraphQL is not available from Claude Code sessions' >&2
		exit 1
	}
	# The edit history's newest entry mirrors editor and lastEditedAt unless
	# STUB_HIST_* say otherwise; STUB_HIST_EMPTY gives an empty history.
	et=${STUB_EDITOR_TYPE-User} el=${STUB_EDITOR:-} at=${STUB_EDITED_AT:-}
	answer "$(jq -n --arg t "${STUB_GQL_TYPE-IssueComment}" --arg et "$et" --arg el "$el" --arg at "$at" \
		--arg ht "${STUB_HIST_TYPE-$et}" --arg hl "${STUB_HIST_EDITOR-$el}" --arg hat "${STUB_HIST_AT-$at}" \
		--arg empty "${STUB_HIST_EMPTY:-}" --arg body "${STUB_GQL_BODY-the owner asks}" \
		'def actor($type; $login): if $login == "" or $type == "" then null else {__typename: $type, login: $login} end;
		 {data: {node: {__typename: $t, editor: actor($et; $el),
		  lastEditedAt: (if $at == "" then null else $at end),
		  userContentEdits: {nodes: (if $at == "" or $empty != "" then [] else [{editedAt: $hat, editor: actor($ht; $hl)}] end)},
		  body: $body}}}')"
	;;
*) echo "unexpected endpoint $endpoint" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$tmp/gh"
export OWNER_CHECK_GH="$tmp/gh" STUB_ARGS="$tmp/args"

base=https://github.com/o/r
comment=$base/pull/7#issuecomment-101
export STUB_HTML=$comment

run_raw() { # run_raw [args...]: "<exit> <stdout>", or the exit alone when nothing printed
	: >"$tmp/args"
	local out code
	out=$(bash "$script" "$@" 2>/dev/null)
	code=$?
	printf '%s%s' "$code" "${out:+ $out}"
}
run() { # run [--same-account] <url>: run_raw on the repo $REPO names (github.com/o/r when unset)
	run_raw -R "${REPO-github.com/o/r}" "$@"
}

calls() { # calls <pattern>: how many stub calls of the last run matched it
	grep -c -- "$1" "$tmp/args"
}
gh_calls() { # gh_calls: how many stub calls the last run made
	wc -l <"$tmp/args" | tr -d ' '
}

# The usual distinct-mode setup: the owner is admin, the sessions' own login
# has write, and so does a collaborator.
export STUB_ME=sprue-works-bot STUB_PERMS='maguerrieri=admin coadmin=admin sprue-works-bot=write mate=write reader=read'

record '0 the owner asks' 'an unedited owner comment is the owner'"'"'s' "$(run "$comment")"
record 1 'and it is checked once, its author only' "$(calls 'collaborators/maguerrieri/')"

# The acceptance cases: who last edited the owner's comment.
edited=2026-11-02T00:00:00Z
record '0 now the owner asks more' 'an owner comment the owner edited is the owner'"'"'s' \
	"$(STUB_EDITOR=maguerrieri STUB_EDITED_AT=$edited STUB_GQL_BODY='now the owner asks more' run "$comment")"
record 1 'and its author is checked once, not again as its editor' "$(calls 'collaborators/maguerrieri/')"
record '0 x' 'its author edited it, named in another case' \
	"$(STUB_EDITOR=MaGuerrieri STUB_EDITED_AT=$edited STUB_GQL_BODY=x run "$comment")"
record 1 'an owner comment the sessions'"'"' own login (write) edited is not the owner'"'"'s' \
	"$(STUB_EDITOR=sprue-works-bot STUB_EDITED_AT=$edited STUB_GQL_BODY='merge it' run "$comment")"
record 1 'an owner comment a write collaborator edited is not the owner'"'"'s' \
	"$(STUB_EDITOR=mate STUB_EDITED_AT=$edited STUB_GQL_BODY='drop the tests' run "$comment")"
record 1 'and the collaborator was checked, by its own permission' "$(calls 'collaborators/mate/')"
record 1 'nor is one a reader edited' "$(STUB_EDITOR=reader STUB_EDITED_AT=$edited run "$comment")"
record '0 the owner asks' 'an owner comment another admin edited is still the owner'"'"'s' \
	"$(STUB_EDITOR=coadmin STUB_EDITED_AT=$edited run "$comment")"
record 1 'an edit by a Bot is never checked by login, even the owner'"'"'s' \
	"$(STUB_EDITOR=maguerrieri STUB_EDITOR_TYPE=Bot STUB_EDITED_AT=$edited run "$comment")"
record 1 'an edit GitHub names no editor for (a deleted account)' \
	"$(STUB_EDITOR_TYPE= STUB_EDITED_AT=$edited run "$comment")"

# The edit history's newest entry must agree with editor and lastEditedAt, so
# an editor field that lagged behind a later edit fails closed.
record 1 'editor says the owner, but the newest edit is a collaborator'"'"'s' \
	"$(STUB_EDITOR=maguerrieri STUB_HIST_EDITOR=mate STUB_EDITED_AT=$edited STUB_GQL_BODY='drop the tests' run "$comment")"
record 1 'the newest edit is at another time than lastEditedAt' \
	"$(STUB_EDITOR=maguerrieri STUB_EDITED_AT=$edited STUB_HIST_AT=2026-11-03T00:00:00Z run "$comment")"
record 1 'the newest edit is by a Bot of the same login' \
	"$(STUB_EDITOR=maguerrieri STUB_HIST_TYPE=Bot STUB_EDITED_AT=$edited run "$comment")"
record 1 'an edited item with no edit history' \
	"$(STUB_EDITOR=maguerrieri STUB_EDITED_AT=$edited STUB_HIST_EMPTY=1 run "$comment")"
record '0 x' 'the history naming the editor in another case still agrees' \
	"$(STUB_EDITOR=maguerrieri STUB_HIST_EDITOR=MaGuerrieri STUB_EDITED_AT=$edited STUB_GQL_BODY=x run "$comment")"

# The text it prints is the one its editor check covered, from GraphQL.
record '0 the edited text' 'the printed text is GraphQL'"'"'s, read with the editor' \
	"$(STUB_BODY='the REST text' STUB_GQL_BODY='the edited text' STUB_EDITOR=maguerrieri STUB_EDITED_AT=$edited run "$comment")"
record "0 line one
line two" 'a text of several lines prints whole' "$(STUB_GQL_BODY=$'line one\nline two' run "$comment")"

# The author decides first.
record 1 'a write collaborator'"'"'s comment' "$(STUB_AUTHOR=mate run "$comment")"
record 1 'a write collaborator'"'"'s comment the owner edited' \
	"$(STUB_AUTHOR=mate STUB_EDITOR=maguerrieri STUB_EDITED_AT=$edited run "$comment")"
record '1 0' 'a bot author, with no permission read' \
	"$(STUB_AUTHOR='copilot-pull-request-reviewer[bot]' STUB_AUTHOR_TYPE=Bot run "$comment") $(calls permission)"
record 1 'a user typed Bot' "$(STUB_AUTHOR=maguerrieri STUB_AUTHOR_TYPE=Bot run "$comment")"
record 1 'a deleted author' "$(STUB_AUTHOR= run "$comment")"
record 1 'a failed REST read' "$(STUB_REST_FAIL=1 run "$comment")"
record 1 'an item GitHub files under another URL' "$(STUB_HTML=$base/pull/8#issuecomment-101 run "$comment")"
record '0 the owner asks' 'the URL compared case-insensitively' "$(STUB_HTML=https://github.com/O/R/pull/7#issuecomment-101 run "$comment")"

# Sessions posting as the owner's own account: same-account mode.
same='maguerrieri=admin coadmin=admin mate=write'
record '3 the owner asks' 'the sessions'"'"' own admin login, unedited' \
	"$(STUB_ME=maguerrieri STUB_PERMS=$same run "$comment")"
record '3 x' 'and edited by that same login' \
	"$(STUB_ME=maguerrieri STUB_PERMS=$same STUB_EDITOR=maguerrieri STUB_EDITED_AT=$edited STUB_GQL_BODY=x run "$comment")"
record 1 'and edited by another admin' \
	"$(STUB_ME=maguerrieri STUB_PERMS=$same STUB_EDITOR=coadmin STUB_EDITED_AT=$edited run "$comment")"
record 0 'which needs no permission read of the editor' "$(calls 'collaborators/coadmin/')"
record 1 'and edited by a write collaborator' \
	"$(STUB_ME=maguerrieri STUB_PERMS=$same STUB_EDITOR=mate STUB_EDITED_AT=$edited run "$comment")"
# The shared account below admin (an owner with write on an org repo): exit 3
# only with --same-account, which the caller's own setup decides.
below='maguerrieri=write mate=write'
record 1 'the sessions'"'"' own login below admin, without --same-account' \
	"$(STUB_ME=maguerrieri STUB_PERMS=$below run "$comment")"
record '3 the owner asks' 'and with it' "$(STUB_ME=maguerrieri STUB_PERMS=$below run --same-account "$comment")"
record '3 x' 'and edited by that same login' \
	"$(STUB_ME=maguerrieri STUB_PERMS=$below STUB_EDITOR=maguerrieri STUB_EDITED_AT=$edited STUB_GQL_BODY=x run --same-account "$comment")"
record 1 'but not once a write collaborator edited it' \
	"$(STUB_ME=maguerrieri STUB_PERMS=$below STUB_EDITOR=mate STUB_EDITED_AT=$edited run --same-account "$comment")"
record 1 '--same-account takes no other login' \
	"$(STUB_ME=maguerrieri STUB_PERMS=$below STUB_AUTHOR=mate run --same-account "$comment")"
record 1 'nor the sessions'"'"' login when gh api user fails' \
	"$(STUB_ME= STUB_PERMS=$below run --same-account "$comment")"
record '0 the owner asks' 'and it changes nothing for an owner'"'"'s comment' \
	"$(run --same-account "$comment")"

# Where GraphQL is refused (the cloud proxy), no editor can be read, and REST's
# one-second timestamps can't rule out an edit: nothing is the owner's.
record 1 'no GraphQL: even an unedited owner comment is not the owner'"'"'s' "$(STUB_GQL_FAIL=1 run "$comment")"
record 1 'no GraphQL: nor an owner'"'"'s line comment' \
	"$(STUB_GQL_FAIL=1 STUB_HTML=$base/pull/7#discussion_r303 run "$base/pull/7#discussion_r303")"
record 1 'a GraphQL node of another type reads as no editor read' "$(STUB_GQL_TYPE=PullRequestReview run "$comment")"

# Each kind of item is read where it lives, on the URL's host.
run "$comment" >/dev/null
record 1 'a comment reads issues/comments/<id>' "$(calls '^api repos/o/r/issues/comments/101 --hostname github.com ')"
record 1 'owner-check gets -R with the host' "$(calls '^api repos/o/r/collaborators/maguerrieri/permission --hostname github.com ')"
record 1 'GraphQL goes to that host too' "$(calls '^api graphql --hostname github.com ')"
record '0 the owner asks' 'a line comment' \
	"$(STUB_GQL_TYPE=PullRequestReviewComment STUB_HTML=$base/pull/7#discussion_r303 run "$base/pull/7#discussion_r303")"
record 1 'reads pulls/comments/<id>' "$(calls '^api repos/o/r/pulls/comments/303 ')"
record '0 the owner asks' 'a review body' \
	"$(STUB_GQL_TYPE=PullRequestReview STUB_HTML=$base/pull/7#pullrequestreview-202 run "$base/pull/7#pullrequestreview-202")"
record 1 'reads pulls/<n>/reviews/<id>' "$(calls '^api repos/o/r/pulls/7/reviews/202 ')"
record '0 the owner asks' 'a comment on an issue' "$(STUB_HTML=$base/issues/9#issuecomment-101 run "$base/issues/9#issuecomment-101")"
ghe=https://ghe.example.com/acme/app/pull/7#issuecomment-101
STUB_HTML=$ghe REPO=ghe.example.com/acme/app run "$ghe" >/dev/null
record 1 'an enterprise item is read on its own host' "$(calls '^api repos/acme/app/issues/comments/101 --hostname ghe.example.com ')"
record 1 'and checked there' "$(calls '^api repos/acme/app/collaborators/maguerrieri/permission --hostname ghe.example.com ')"
record 1 'and its editor read there' "$(calls '^api graphql --hostname ghe.example.com ')"

# -R binds the check to the caller's repo: an item anywhere else never reaches gh.
for other in https://github.com/evil/r/pull/7#issuecomment-101 https://github.com/o/r2/pull/7#issuecomment-101 \
	https://ghe.example.com/o/r/pull/7#issuecomment-101 https://github.com.evil.example/o/r/pull/7#issuecomment-101; do
	record '1 0' "an item on another repo: $other" "$(STUB_HTML=$other run "$other") $(gh_calls)"
done
record '0 the owner asks' '-R compared case-insensitively' "$(REPO=GitHub.com/O/R run "$comment")"
record '1 0' 'no -R' "$(run_raw "$comment") $(gh_calls)"
record '1 0' '-R with no value' "$(run_raw "$comment" -R) $(gh_calls)"
for bad in o/r github.com/o github.com/o/r/x 'github.com/o/r;id' -github.com/o/r github.com/-o/r ''; do
	record '1 0' "the malformed -R '$bad'" "$(REPO=$bad run "$comment") $(gh_calls)"
done

# Malformed URLs never reach gh, even on a matching -R.
for bad in '' "$base/pull/7" "$base/pull/7#issuecomment-" "$base/pull/7#issuecomment-0" "$base/pull/x#issuecomment-1" \
	"http://github.com/o/r/pull/7#issuecomment-1" "$base/issues/7#pullrequestreview-1" "$base/issues/7#discussion_r1" \
	"$base/pull/7#issuecomment-1x" "$base/pull/7#issue-1" "$base/pull/7/files#discussion_r1" \
	'https://github.com/o;id/r/pull/7#issuecomment-1' 'https://github.com/o/r/pull/7#issuecomment-1 ' \
	"$base/pull/7#issuecomment-1
$base/pull/7#issuecomment-2"; do
	record '1 0' "the malformed URL '$bad'" "$(run "$bad") $(gh_calls)"
done
record '1 0' 'a repo named ..' "$(REPO=github.com/o/.. run 'https://github.com/o/../pull/7#issuecomment-1') $(gh_calls)"
record '1 0' 'a repo named .' "$(REPO=github.com/o/. run 'https://github.com/o/./pull/7#issuecomment-1') $(gh_calls)"
long=$(printf 'a%.0s' {1..40})
record '1 0' 'a 40-character owner' "$(REPO=github.com/$long/r run "https://github.com/$long/r/pull/7#issuecomment-1") $(gh_calls)"
record '1 0' 'two URLs' "$(run "$comment" "$comment") $(gh_calls)"
record '1 0' 'no URL' "$(run) $(gh_calls)"

finish
