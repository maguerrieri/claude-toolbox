#!/usr/bin/env bash
# Tests for scripts/gh-verified.sh, the best-effort check that GitHub marks
# every commit in a range verified: which commits it lists, and its setup
# errors. gh is replaced by a stub that calls a commit unverified when its
# subject is listed in $STUB_UNVERIFIED, and fails for $STUB_FAIL_SUBJECT.
#
#   bash plugins/ticket-workflow/tests/test-gh-verified.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
script="$plugin/scripts/gh-verified.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

repo=$tmp/repo
git init -q -b main "$repo"
g() { git -C "$repo" "$@"; }
g config user.email a@x
g config user.name A
g commit -q --allow-empty -m base
g tag base
g commit -q --allow-empty -m one
g commit -q --allow-empty -m two
g tag two
g switch -q --detach base
g commit -q --allow-empty -m side
g tag side
g switch -q --detach two
g merge -q --no-ff --no-edit -m merge side
g tag merge

# The stub reads the commit's subject from the SHA in its endpoint argument
# and prints what the script's --jq would: "<verified> <reason>".
cat >"$tmp/gh" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_ARGS"
sha=${2##*/}
subject=$(git log -1 --format=%s "$sha")
[ "$subject" = "${STUB_FAIL_SUBJECT:-}" ] && { echo 'HTTP 422: No commit found' >&2; exit 1; }
case " ${STUB_UNVERIFIED:-} " in
*" $subject "*) echo 'false unsigned' ;;
*) echo 'true valid' ;;
esac
STUB_EOF
chmod +x "$tmp/gh"
export GH_VERIFIED_GH="$tmp/gh" STUB_ARGS="$tmp/args"

run() { # run [script args...]: "<reason>:<subject>,…|exit <n>", run in the repo
	local out code
	: >"$tmp/args"
	out=$(cd "$repo" && bash "$script" "$@" 2>/dev/null)
	code=$?
	printf '%s|exit %s' "$(printf '%s' "$out" | awk 'NF { print $2 ":" $3 }' | paste -sd, -)" "$code"
}

record '|exit 0' 'every commit verified' "$(run base two)"
record '2' 'one GitHub read per commit' "$(wc -l <"$tmp/args" | tr -d ' ')"
record 'api repos/{owner}/{repo}/commits/'"$(g rev-parse two)"' --jq "\(.commit.verification.verified) \(.commit.verification.reason)"' \
	'the endpoint and filter' "$(head -1 "$tmp/args")"
record 'unsigned:one|exit 1' 'an unverified commit is listed' "$(STUB_UNVERIFIED=one run base two)"
record 'unsigned:two,unsigned:one|exit 1' 'every unverified commit, newest first' "$(STUB_UNVERIFIED='one two' run base two)"
record 'unsigned:merge|exit 1' 'a merge commit is checked too' "$(STUB_UNVERIFIED=merge run base merge)"
record 'unsigned:side|exit 1' 'and the side branch it brings in' "$(STUB_UNVERIFIED=side run base merge)"
record '|exit 2' 'a failed GitHub read' "$(STUB_FAIL_SUBJECT=one run base two)"
record '|exit 2' 'an empty range' "$(run two two)"
record '|exit 2' 'a ref that does not resolve' "$(run base no-such-ref)"
record '|exit 2' 'one ref only' "$(run base)"

git clone -q --depth 1 "file://$repo" "$tmp/shallow" 2>/dev/null
git -C "$tmp/shallow" fetch -q --depth 1 origin "$(g rev-parse base)" 2>/dev/null
record '|exit 2' 'a shallow clone is refused' \
	"$(repo=$tmp/shallow run "$(g rev-parse base)" "$(git -C "$tmp/shallow" rev-parse HEAD)")"

finish
