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
g remote add origin https://github.com/o/r.git

# The stub reads the commit's subject from the SHA in its endpoint argument
# and prints what the script's --jq would: "<verified> <reason>".
cat >"$tmp/gh" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_ARGS"
sha=${2##*/}
subject=$(git log -1 --format=%s "$sha")
[ "$subject" = "${STUB_FAIL_SUBJECT:-}" ] && { echo 'HTTP 422: No commit found' >&2; exit 1; }
[ -n "${STUB_EAT_STDIN:-}" ] && cat >/dev/null
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

err() { # err <phrase> [script args...]: "exit <n>" plus "+msg" when stderr carries <phrase>
	local phrase=$1 out code
	shift
	out=$(cd "$repo" && bash "$script" "$@" 2>&1 >/dev/null)
	code=$?
	printf 'exit %s%s' "$code" "$(case $out in *"$phrase"*) printf '+msg' ;; esac)"
}

record '|exit 0' 'every commit verified' "$(run base two)"
record '2' 'one GitHub read per commit' "$(wc -l <"$tmp/args" | tr -d ' ')"
record 'api repos/o/r/commits/'"$(g rev-parse two)"' --jq "\(.commit.verification.verified) \(.commit.verification.reason)"' \
	'the endpoint names origin'"'"'s repo, and the filter' "$(head -1 "$tmp/args")"
record 'unsigned:one|exit 1' 'an unverified commit is listed' "$(STUB_UNVERIFIED=one run base two)"
record 'unsigned:two,unsigned:one|exit 1' 'every unverified commit, newest first' "$(STUB_UNVERIFIED='one two' run base two)"
record 'unsigned:merge|exit 1' 'a merge commit is checked too' "$(STUB_UNVERIFIED=merge run base merge)"
record 'unsigned:side|exit 1' 'and the side branch it brings in' "$(STUB_UNVERIFIED=side run base merge)"
record 'unsigned:one|exit 1' 'a gh that reads stdin still sees every commit' "$(STUB_EAT_STDIN=1 STUB_UNVERIFIED=one run base two)"

# origin's URL in each form gives the same owner/repo.
for u in git@github.com:o/r.git ssh://git@github.com/o/r.git https://github.com/o/r https://x-access-token@github.com/o/r.git; do
	g remote set-url origin "$u"
	run base two >/dev/null
	record "api repos/o/r/commits/$(g rev-parse two)" "owner/repo from $u" "$(head -1 "$tmp/args" | cut -d' ' -f1-2)"
done
g remote set-url origin https://github.com/o/r.git

record 'exit 2+msg' 'a failed GitHub read' "$(STUB_FAIL_SUBJECT=one err "can't read" base two)"
record 'exit 2+msg' 'an empty range' "$(err 'no commits' two two)"
record 'exit 2+msg' 'a ref that does not resolve' "$(err 'is not a commit' base no-such-ref)"
record 'exit 2+msg' 'one ref only' "$(err 'usage' base)"
g remote set-url origin /some/local/path
record 'exit 2+msg' 'an origin URL with no owner/repo' "$(err "can't read owner/repo" base two)"
g remote set-url origin https://github.com/o/r.git

# A replace ref that parents a stand-in for two directly on base would hide
# one from the walk, while a push of two still lands it.
standin=$(g commit-tree -m two "$(g rev-parse 'two^{tree}')" -p base)
g replace two "$standin"
record 'unsigned:one|exit 1' 'a replace ref can'"'"'t hide a commit' "$(STUB_UNVERIFIED=one run base two)"
g replace -d "$(g rev-parse two)" >/dev/null
printf '%s %s\n' "$(g rev-parse two)" "$(g rev-parse base)" >"$repo/.git/info/grafts"
record 'exit 2+msg' 'a graft file is refused' "$(err 'grafts' base two)"
rm "$repo/.git/info/grafts"

git clone -q --depth 1 "file://$repo" "$tmp/shallow" 2>/dev/null
git -C "$tmp/shallow" fetch -q --depth 1 origin "$(g rev-parse base)" 2>/dev/null
record 'true' 'the clone is shallow' "$(git -C "$tmp/shallow" rev-parse --is-shallow-repository)"
record 'exit 2+msg' 'a shallow clone is refused' \
	"$(repo=$tmp/shallow err 'shallow' "$(g rev-parse base)" "$(git -C "$tmp/shallow" rev-parse HEAD)")"

finish
