#!/usr/bin/env bash
# Tests for scripts/owner-review.sh, which requests the owner's review on a
# PR at a hand-back and clears the request when the session goes back to work
# (START Step 9). gh is replaced by a stub, for owner-check.sh too, that
# serves JSON and runs each call's --jq filter through jq, as gh does:
#   STUB_ME          the sessions' login (`gh api user`)
#   STUB_PERMS       "login=permission ..." pairs for the permission reads
#   STUB_OWNER, STUB_OWNER_TYPE   the repo's owner and its type (User or Organization)
#   STUB_ADMINS      "login:type ..." the admin collaborators list returns
#   STUB_PR_STATE    the PR's state (open by default); STUB_PR_MERGED=1 sets merged_at
#   STUB_PR_AUTHOR   the PR's author (the sessions' login by default)
#   STUB_PENDING     "login:type ..." the requested reviewers when the run starts;
#                    a POST adds to them and a DELETE removes, for later reads
#   STUB_HEAD        the PR's head SHA ($head by default)
#   STUB_REVIEWS     "login:state:sha ..." the PR's reviews
#   STUB_FAIL        what fails: user, pr, repo, admins, reviews, post, delete,
#                    or a login (its permission read)
#   STUB_NOOP        post or delete: answers success and changes nothing
# Every call is logged as "<method> <endpoint> host=<host> <fields>". The doc
# cases run the one-liners SKILL.md shows, pulled out of it. Runs under macOS's
# bash 3.2 as well as a current bash, and needs jq.
#
#   bash plugins/ticket-workflow/tests/test-owner-review.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
skill="$plugin/skills/ticket-workflow"
script="$plugin/scripts/owner-review.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

command -v jq >/dev/null 2>&1 || {
	echo "test-owner-review.sh needs jq" >&2
	exit 1
}

cat >"$tmp/gh" <<'STUB_EOF'
#!/usr/bin/env bash
[ "${1:-}" = api ] || { echo "unexpected gh $*" >&2; exit 2; }
endpoint=$2
shift 2
method=GET host= filter= fields=
while [ $# -gt 0 ]; do
	case $1 in
	--hostname) host=$2; shift 2 ;;
	--jq) filter=$2; shift 2 ;;
	--paginate) shift ;;
	-X) method=$2; shift 2 ;;
	-f) fields="${fields:+$fields }$2"; shift 2 ;;
	*) echo "unexpected flag $1" >&2; exit 2 ;;
	esac
done
printf '%s %s host=%s %s\n' "$method" "$endpoint" "$host" "$fields" >>"$STUB_ARGS"
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
fails() { case " $(lower "${STUB_FAIL:-}") " in *" $(lower "$1") "*) return 0 ;; esac; return 1; }
users_json() { # users_json "<login:type ...>": a JSON array of {login, type}
	local out= pair
	for pair in $1; do out="${out:+$out,}{\"login\":\"${pair%%:*}\",\"type\":\"${pair#*:}\"}"; done
	printf '[%s]' "$out"
}
pr_json() {
	local merged=null
	[ -z "${STUB_PR_MERGED:-}" ] || merged='"2026-11-27T10:00:00Z"'
	printf '{"state":"%s","merged_at":%s,"user":{"login":"%s"},"head":{"sha":"%s"},"requested_reviewers":%s}' \
		"${STUB_PR_STATE:-open}" "$merged" "${STUB_PR_AUTHOR:-$STUB_ME}" "$STUB_HEAD" "$(users_json "$(cat "$STUB_STATE")")"
}
case $method:$endpoint in
GET:user)
	fails user && { echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1; }
	json="{\"login\":\"$STUB_ME\"}"
	;;
GET:repos/*/collaborators/*/permission)
	who=${endpoint%/permission}
	who=${who##*/}
	fails "$who" && { echo "{\"message\":\"Not Found\"}"; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
	perm=none
	for pair in ${STUB_PERMS:-}; do
		[ "$(lower "${pair%%=*}")" = "$(lower "$who")" ] && perm=${pair#*=}
	done
	json="{\"permission\":\"$perm\"}"
	;;
GET:repos/*/collaborators)
	fails admins && { echo 'gh: Must have push access to view repository collaborators. (HTTP 403)' >&2; exit 1; }
	json=$(users_json "${STUB_ADMINS:-}")
	;;
POST:repos/*/pulls/*/requested_reviewers | DELETE:repos/*/pulls/*/requested_reviewers)
	verb=$(lower "$method")
	fails "$verb" && { echo '{"message":"Validation Failed"}'; echo 'gh: Reviews may only be requested from collaborators. (HTTP 422)' >&2; exit 1; }
	if [ "${STUB_NOOP:-}" != "$verb" ]; then
		who=${fields#"reviewers[]="}
		kept=
		for pair in $(cat "$STUB_STATE"); do
			[ "$(lower "${pair%%:*}")" = "$(lower "$who")" ] || kept="${kept:+$kept }$pair"
		done
		[ "$verb" = delete ] || kept="${kept:+$kept }$who:User"
		printf '%s' "$kept" >"$STUB_STATE"
	fi
	json=$(pr_json)
	;;
GET:repos/*/pulls/*/reviews\?per_page=100)
	fails reviews && { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
	out=
	for r in ${STUB_REVIEWS:-}; do
		who=${r%%:*} rest=${r#*:}
		out="${out:+$out,}{\"user\":{\"login\":\"$who\"},\"state\":\"${rest%%:*}\",\"commit_id\":\"${rest#*:}\"}"
	done
	json="[$out]"
	;;
GET:repos/*/pulls/*)
	fails pr && { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
	json=$(pr_json)
	;;
GET:repos/*/*)
	fails repo && { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
	json="{\"owner\":{\"login\":\"${STUB_OWNER:-}\",\"type\":\"${STUB_OWNER_TYPE:-User}\"}}"
	;;
*) echo "unexpected $method $endpoint" >&2; exit 2 ;;
esac
if [ -n "$filter" ]; then
	printf '%s' "$json" | jq -r "$filter"
else
	printf '%s\n' "$json"
fi
STUB_EOF
chmod +x "$tmp/gh"
head=1111111111111111111111111111111111111111
old_head=2222222222222222222222222222222222222222
export STUB_ARGS="$tmp/args" STUB_STATE="$tmp/state" STUB_HEAD=$head

# run [VAR=value ...] -- [script args...]: runs the script in a clean
# environment, leaving its exit code in $rc, its stdout in $out, its stderr in
# $err, the stub's calls in $calls (one per line) and its writes (POST and
# DELETE) in $writes.
base_vars=(STUB_ME=sprue-works-bot STUB_OWNER=maguerrieri STUB_OWNER_TYPE=User
	"STUB_PERMS=maguerrieri=admin sprue-works-bot=write alice=admin mate=write")
run() {
	local -a vars=()
	local pending=
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		case $1 in STUB_PENDING=*) pending=${1#STUB_PENDING=} ;; esac
		vars+=("$1")
		shift
	done
	shift
	: >"$STUB_ARGS"
	printf '%s' "$pending" >"$STUB_STATE"
	# ${vars[@]+...}: bash 3.2 calls an empty array unbound under set -u.
	out=$(env -i PATH="$PATH" HOME="$tmp" TMPDIR="$tmp" STUB_ARGS="$STUB_ARGS" STUB_STATE="$STUB_STATE" \
		STUB_HEAD="$STUB_HEAD" OWNER_CHECK_GH="$tmp/gh" "${base_vars[@]}" ${vars[@]+"${vars[@]}"} \
		bash "${script_path:-$script}" "$@" 2>"$tmp/err")
	rc=$?
	err=$(cat "$tmp/err")
	calls=$(cat "$STUB_ARGS")
	writes=$(grep -E '^(POST|DELETE) ' "$STUB_ARGS")
}
lines() { printf '%s' "$1" | grep -c ''; }
pr_url=https://github.com/maguerrieri/claude-toolbox/pull/5
writes_to="repos/maguerrieri/claude-toolbox/pulls/5/requested_reviewers host=github.com"

# --- request ---------------------------------------------------------------

run -- request $pr_url
record 0 "request: exit" "$rc"
record "owner-review: requested maguerrieri's review on maguerrieri/claude-toolbox#5" "request: says so" "$out"
record "POST $writes_to reviewers[]=maguerrieri" "request: one POST, for the user who owns the repo" "$writes"
record "" "request: nothing on stderr" "$err"
record maguerrieri:User "request: GitHub now lists the owner" "$(cat "$STUB_STATE")"

run STUB_PENDING=maguerrieri:User -- request $pr_url
record "0 owner-review: already requested from maguerrieri on maguerrieri/claude-toolbox#5" "already pending: nothing to do" "$rc $out"
record "" "already pending: no second request, so no second notification" "$writes"
run STUB_PENDING=MaGuErRiErI:User -- request $pr_url
record "0 " "already pending, matched case-insensitively" "$rc $writes"

# A pending bot, or a teammate someone asked for, is no owner request.
run "STUB_PENDING=Copilot:Bot mate:User" -- request $pr_url
record "0 POST $writes_to reviewers[]=maguerrieri" "other pending reviewers don't stand in for the owner" "$rc $writes"

# A head the owner already reviewed has nothing new to ask about.
for st in APPROVED COMMENTED CHANGES_REQUESTED; do
	run "STUB_REVIEWS=Copilot:COMMENTED:$head MaGuerrieri:$st:$head" -- request $pr_url
	record "0 " "the owner's $st review of the head: no request" "$rc $writes"
done
case $out in *"maguerrieri already reviewed its head 1111111, so any reply since reaches them without a request") said=yes ;; *) said="no ($out)" ;; esac
record yes "a reviewed head: says so" "$said"
run "STUB_REVIEWS=maguerrieri:APPROVED:$old_head" -- request $pr_url
record "0 POST $writes_to reviewers[]=maguerrieri" "the owner reviewed an older head: request" "$rc $writes"
run "STUB_REVIEWS=maguerrieri:DISMISSED:$head maguerrieri:PENDING:$head alice:APPROVED:$head" -- request $pr_url
record "0 POST $writes_to reviewers[]=maguerrieri" "a dismissed or pending review, or someone else's, doesn't count" "$rc $writes"
record 1 "the reviews are read once, every page" "$(printf '%s\n' "$calls" | grep -c '^GET repos/maguerrieri/claude-toolbox/pulls/5/reviews?per_page=100 host=github.com $')"

run -- request maguerrieri/claude-toolbox#5
record "0 POST $writes_to reviewers[]=maguerrieri" "request by <owner>/<repo>#<n>" "$rc $writes"
run -- request $pr_url/
record "0 POST $writes_to reviewers[]=maguerrieri" "a trailing slash on the URL" "$rc $writes"

# Another GitHub host: every read and write goes there, owner-check.sh's included.
run -- request https://ghe.example.com/o/r/pull/9
record "0 POST repos/o/r/pulls/9/requested_reviewers host=ghe.example.com reviewers[]=maguerrieri" \
	"another host: the request goes there" "$rc $writes"
record 0 "another host: no call goes anywhere else" "$(printf '%s\n' "$calls" | grep -vc 'host=ghe.example.com ')"

# --- clear -----------------------------------------------------------------

run STUB_PENDING=maguerrieri:User -- clear $pr_url
record 0 "clear: exit" "$rc"
record "owner-review: cleared maguerrieri's review request on maguerrieri/claude-toolbox#5, until the next hand-back requests it again" \
	"clear: says so" "$out"
record "DELETE $writes_to reviewers[]=maguerrieri" "clear: one DELETE, for the owner" "$writes"
record "" "clear: GitHub no longer lists the owner" "$(cat "$STUB_STATE")"

run -- clear $pr_url
record "0 " "clear with nothing pending: nothing to do" "$rc $writes"
record "owner-review: no review request was cleared on maguerrieri/claude-toolbox#5: none is pending from maguerrieri" \
	"clear with nothing pending: says so" "$out"

# clear removes only the owner's request, never one a person asked for or a bot's.
run "STUB_PENDING=Copilot:Bot mate:User maguerrieri:User" -- clear $pr_url
record "0 DELETE $writes_to reviewers[]=maguerrieri" "clear: only the owner's request goes" "$rc $writes"
record "Copilot:Bot mate:User" "clear: the others stay pending" "$(cat "$STUB_STATE")"
run "STUB_PENDING=mate:User alice:User" -- clear $pr_url
record "0 " "clear: another admin someone asked for is left alone" "$rc $writes"

# --- nothing to do: exit 0, no write ---------------------------------------

for sub in request clear; do
	run STUB_ME=maguerrieri STUB_PENDING=alice:User -- $sub $pr_url
	record "0 " "$sub: the sessions post as the owner's account, so nothing to do" "$rc $writes"
	case $out in *"the sessions post as the owner's account (maguerrieri, an admin)"*) said=yes ;; *) said=no ;; esac
	record yes "$sub: same-account mode says why" "$said"

	run STUB_PR_STATE=closed STUB_PR_MERGED=1 STUB_PENDING=maguerrieri:User -- $sub $pr_url
	record "0 " "$sub: a merged PR" "$rc $writes"
	case $out in *": it has merged") said=yes ;; *) said=no ;; esac
	record yes "$sub: a merged PR says so" "$said"
	record 1 "$sub: a merged PR needs only the PR read" "$(lines "$calls")"

	run STUB_PR_STATE=closed -- $sub $pr_url
	case $out in *": it is closed") said=yes ;; *) said=no ;; esac
	record "0 yes" "$sub: a closed PR" "$rc $said"

	run -- $sub $pr_url --owner none
	record "0 0" "$sub --owner none: nothing runs" "$rc $(lines "$calls")"
	case $out in *"the repo's Owner review line says none") said=yes ;; *) said=no ;; esac
	record yes "$sub --owner none: says why" "$said"
done

run STUB_PR_AUTHOR=MaGuerrieri -- request $pr_url
record "0 " "the owner opened the PR: GitHub won't let its author review it" "$rc $writes"
case $out in *"maguerrieri opened it, and GitHub won't let a PR's author review it") said=yes ;; *) said=no ;; esac
record yes "the owner opened the PR: says so" "$said"

# --- --owner, from the repo's Owner review line ------------------------------

run -- request $pr_url --owner alice
record "0 POST $writes_to reviewers[]=alice" "--owner names the login to request" "$rc $writes"
run STUB_PENDING=alice:User -- clear --owner alice $pr_url
record "0 DELETE $writes_to reviewers[]=alice" "--owner names the login to clear, before the PR too" "$rc $writes"
run STUB_PENDING=maguerrieri:User -- clear $pr_url --owner alice
record "0 " "clear --owner leaves another login's request alone" "$rc $writes"

run -- request $pr_url --owner mate
record "1 " "--owner below admin: exit 1, no request" "$rc $writes"
record "owner-review: the owner's review wasn't requested on maguerrieri/claude-toolbox#5: the Owner review line names mate, who isn't the owner by owner-check.sh (mate has write on maguerrieri/claude-toolbox, not admin)" \
	"--owner below admin: says why, with owner-check.sh's reason" "$out"
run -- request $pr_url --owner sprue-works-bot
record "1 " "--owner naming the sessions' own login" "$rc $writes"

# --- an organization's repo -------------------------------------------------

org=(STUB_OWNER=sprue-works STUB_OWNER_TYPE=Organization)
run "${org[@]}" "STUB_ADMINS=maguerrieri:User some-app:Bot" -- request $pr_url
record "0 POST $writes_to reviewers[]=maguerrieri" "an organization's repo with one admin: that admin" "$rc $writes"
admins_read=$(printf '%s\n' "$calls" | grep -c '^GET repos/maguerrieri/claude-toolbox/collaborators host=github.com permission=admin per_page=100$')
record 1 "the admin list is read once, filtered to admins, one page" "$admins_read"

run "${org[@]}" "STUB_ADMINS=sprue-works-bot:User maguerrieri:User" "STUB_PERMS=maguerrieri=admin sprue-works-bot=admin" -- request $pr_url
record "0 " "the sessions' login among the admins: same-account mode" "$rc $writes"

run "${org[@]}" "STUB_ADMINS=alice:User maguerrieri:User" -- request $pr_url
record "0 " "several admins: nobody is requested" "$rc $writes"
record "owner-review: the owner's review wasn't requested on maguerrieri/claude-toolbox#5: maguerrieri/claude-toolbox has several admins (alice maguerrieri), so name the owner with an Owner review line" \
	"several admins: names them and the line" "$out"
record "1" "several admins: no permission read beyond the sessions' own" "$(printf '%s\n' "$calls" | grep -c '/permission ')"
run "${org[@]}" "STUB_ADMINS=alice:User maguerrieri:User" STUB_PENDING=maguerrieri:User -- clear $pr_url
record "0 " "several admins: clear removes nothing a person asked for" "$rc $writes"
run "${org[@]}" "STUB_ADMINS=alice:User maguerrieri:User" -- request $pr_url --owner maguerrieri
record "0 POST $writes_to reviewers[]=maguerrieri" "several admins: the Owner review line picks one" "$rc $writes"

run "${org[@]}" "STUB_ADMINS=mate:User" "STUB_PERMS=mate=admin sprue-works-bot=write" -- request $pr_url
record "0 POST $writes_to reviewers[]=mate" "an admin who passes owner-check.sh is the owner, whatever the name" "$rc $writes"
run "${org[@]}" STUB_ADMINS=sprue-works-bot:User -- request $pr_url
record "0 " "an organization's repo with no admin to ask" "$rc $writes"
record "owner-review: the owner's review wasn't requested on maguerrieri/claude-toolbox#5: maguerrieri/claude-toolbox has no admin other than the sessions' own login to ask" \
	"no admin to ask: says so" "$out"

# --- failures: exit 1, no write ---------------------------------------------

check_fail() { # check_fail <label> <expected line ending> <writes tried> [VAR=value ...] -- <args>
	local label=$1 ending=$2 tried=$3
	shift 3
	run "$@"
	record "1 $tried" "$label: exit 1, with $tried writes tried" "$rc $(lines "$writes")"
	case $out in *"$ending") said=yes ;; *) said="no ($out)" ;; esac
	record yes "$label: says why" "$said"
	record 1 "$label: one line" "$(lines "$out")"
}
check_fail "the PR read fails" "can't read the PR (gh: Not Found (HTTP 404))" 0 STUB_FAIL=pr -- request $pr_url
check_fail "gh api user fails" "can't read the sessions' own login (gh api user): gh: Bad credentials (HTTP 401)" 0 STUB_FAIL=user -- request $pr_url
check_fail "the repo read fails" "can't read the repo (gh: Not Found (HTTP 404))" 0 STUB_FAIL=repo -- request $pr_url
check_fail "the owner's permission read fails" \
	"can't confirm the repo's owner maguerrieri is the owner by owner-check.sh (can't read maguerrieri's permission on maguerrieri/claude-toolbox)" 0 \
	STUB_FAIL=maguerrieri -- request $pr_url
check_fail "the admin list read fails" "can't list the repo's admins (gh: Must have push access to view repository collaborators. (HTTP 403))" 0 \
	"${org[@]}" STUB_FAIL=admins -- request $pr_url
check_fail "a lone admin's permission read fails" \
	"can't confirm maguerrieri/claude-toolbox's one admin alice is the owner by owner-check.sh (can't read alice's permission on maguerrieri/claude-toolbox)" 0 \
	"${org[@]}" "STUB_ADMINS=alice:User" STUB_FAIL=alice -- request $pr_url
check_fail "the reviews read fails" "can't read the PR's reviews (gh: Not Found (HTTP 404))" 0 STUB_FAIL=reviews -- request $pr_url
check_fail "a PR with no head" "can't read the PR's head" 0 STUB_HEAD= -- request $pr_url

# owner-check.sh missing, or not running: a failure, never "nobody to ask".
mkdir -p "$tmp/lone" "$tmp/broken"
cp "$script" "$tmp/lone/owner-review.sh"
cp "$script" "$tmp/broken/owner-review.sh"
printf '#!/usr/bin/env bash\nexit 126\n' >"$tmp/broken/owner-check.sh"
script_path=$tmp/lone/owner-review.sh
check_fail "owner-check.sh missing" "owner-check.sh isn't beside this script, in $tmp/lone" 0 -- request $pr_url
record 0 "owner-check.sh missing: no gh call" "$(lines "$calls")"
script_path=$tmp/broken/owner-review.sh
for sub in request clear; do
	check_fail "owner-check.sh doesn't run: $sub" "owner-check.sh failed (exit 126) on sprue-works-bot" 0 \
		STUB_PENDING=maguerrieri:User -- $sub $pr_url
done
check_fail "owner-check.sh doesn't run, on an organization's repo" "owner-check.sh failed (exit 126) on sprue-works-bot" 0 \
	"${org[@]}" STUB_ADMINS=maguerrieri:User -- request $pr_url
script_path=
check_fail "the request fails" "the request for maguerrieri failed (gh: Reviews may only be requested from collaborators. (HTTP 422))" 1 \
	STUB_FAIL=post -- request $pr_url
check_fail "a request GitHub doesn't list" "GitHub accepted the request for maguerrieri but doesn't list it" 1 \
	STUB_NOOP=post -- request $pr_url
check_fail "the removal fails" "removing maguerrieri's request failed (gh: Reviews may only be requested from collaborators. (HTTP 422))" 1 \
	STUB_FAIL=delete STUB_PENDING=maguerrieri:User -- clear $pr_url
check_fail "a removal GitHub still lists" "GitHub accepted the removal of maguerrieri's request but still lists it" 1 \
	STUB_NOOP=delete STUB_PENDING=maguerrieri:User -- clear $pr_url

# --- usage errors: exit 2, nothing runs --------------------------------------

for bad in https://github.com/o/r/issues/7 https://github.com/o/r/pull/7/files http://github.com/o/r/pull/7 \
	'o/r#7; rm -rf x' o/r 'o/.#7' 'o/..#7' '-o/r#7' '' 'https://github.com/-o/r/pull/7'; do
	run -- request "$bad"
	record "2 0" "rejects '$bad'" "$rc $(lines "$calls")"
done
for args in "" "request" "ask o/r#1" "request o/r#1 o/r#2" "request o/r#1 --owner" "request o/r#1 --owner 'a b'" \
	"request o/r#1 --owner x[bot]" "request o/r#1 --owner a --owner b" "clear o/r#1 --all"; do
	eval "set -- $args"
	run -- "$@"
	record "2 0" "usage: '$args'" "$rc $(lines "$calls")"
done

# --- the docs' one-liners ----------------------------------------------------

# Prints the first line, in any fenced code block of <file>, that ends with <text>.
fenced_line_ending() { # fenced_line_ending <file> <text>
	awk -v t="$2" '
		/^[ \t]*```/ { in_block = !in_block; next }
		in_block && length($0) >= length(t) && substr($0, length($0) - length(t) + 1) == t { print; exit }
	' "$1"
}

# Runs that line as the docs show it, with <pr url> filled in and the plugin
# root pointing at this checkout.
run_doc() { # run_doc <file> <text> [VAR=value ...]
	local file=$1 text=$2 line pending=
	shift 2
	line=$(fenced_line_ending "$file" "$text" | sed -e "s|<pr url>|$pr_url|g")
	record yes "doc line found: $text in ${file#"$skill"/}" "$([ -n "$line" ] && echo yes || echo no)"
	for v in "$@"; do case $v in STUB_PENDING=*) pending=${v#STUB_PENDING=} ;; esac; done
	: >"$STUB_ARGS"
	printf '%s' "$pending" >"$STUB_STATE"
	env -i PATH="$PATH" HOME="$tmp" TMPDIR="$tmp" STUB_ARGS="$STUB_ARGS" STUB_STATE="$STUB_STATE" \
		STUB_HEAD="$STUB_HEAD" OWNER_CHECK_GH="$tmp/gh" CLAUDE_TICKET_WORKFLOW_ROOT="$plugin" "${base_vars[@]}" "$@" \
		bash -c "$line" >/dev/null 2>&1
	writes=$(grep -E '^(POST|DELETE) ' "$STUB_ARGS")
}

run_doc "$skill/SKILL.md" 'owner-review.sh" request <pr url>'
record "POST $writes_to reviewers[]=maguerrieri" "START Step 9's request runs as documented" "$writes"
run_doc "$skill/SKILL.md" 'owner-review.sh" clear <pr url>' STUB_PENDING=maguerrieri:User
record "DELETE $writes_to reviewers[]=maguerrieri" "START Step 9's clear runs as documented" "$writes"

finish
