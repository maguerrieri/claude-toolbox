#!/usr/bin/env bash
# Tests for scripts/owner-check.sh, which says whether a GitHub login is the
# owner's by its live permission on the repo: exit 0 (an admin, while the
# sessions' own login isn't one), 3 (the sessions' own login, an admin), 1
# (anything else). gh is replaced by a stub:
#   STUB_ME          what `gh api user` prints (the sessions' login)
#   STUB_PERMS       "login=permission ..." pairs, matched case-insensitively
#   STUB_FAIL        logins whose permission read fails; "user" fails `gh api user`
#   STUB_EMPTY       logins whose permission read succeeds with no output
#
#   bash plugins/ticket-workflow/tests/test-owner-check.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
script="$plugin/scripts/owner-check.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

cat >"$tmp/gh" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_ARGS"
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
endpoint=$2
case $endpoint in
user)
	case " ${STUB_FAIL:-} " in *" user "*) echo 'HTTP 401: Bad credentials' >&2; exit 1 ;; esac
	printf '%s\n' "${STUB_ME:-}"
	;;
repos/*/collaborators/*/permission)
	who=${endpoint%/permission}
	who=$(lower "${who##*/}")
	case " $(lower "${STUB_FAIL:-}") " in
	*" $who "*) printf '{"message":"%s is not a user"}' "$who"; echo "gh: $who is not a user (HTTP 404)" >&2; exit 1 ;;
	esac
	case " $(lower "${STUB_EMPTY:-}") " in *" $who "*) exit 0 ;; esac
	for pair in ${STUB_PERMS:-}; do
		[ "$(lower "${pair%%=*}")" = "$who" ] && { printf '%s\n' "${pair#*=}"; exit 0; }
	done
	echo 'none'
	;;
*) echo "unexpected endpoint $endpoint" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$tmp/gh"
export OWNER_CHECK_GH="$tmp/gh" STUB_ARGS="$tmp/args"

run() { # run [script args...]: the exit code
	: >"$tmp/args"
	bash "$script" "$@" >/dev/null 2>&1
	printf '%s' "$?"
}

calls() { # calls: how many times the stub ran during the last run
	wc -l <"$tmp/args" | tr -d ' '
}

# The usual distinct-mode setup: the owner is admin, the bot has write.
export STUB_ME=sprue-works-bot STUB_PERMS='maguerrieri=admin sprue-works-bot=write mate=write reader=read outsider=none'

record 0 'an admin, while the sessions'"'"' login is not one' "$(run -R o/r maguerrieri)"
record 'api repos/o/r/collaborators/maguerrieri/permission --jq .permission' \
	'the permission read names -R'"'"'s repo and the login' "$(grep -m1 maguerrieri "$tmp/args")"
record 0 'a login matched case-insensitively' "$(run -R o/r MaGuErRiErI)"
record 1 'write permission' "$(run -R o/r mate)"
record 1 'read permission' "$(run -R o/r reader)"
record 1 'no permission' "$(run -R o/r outsider)"
record 1 'maintain is not admin' "$(STUB_PERMS='maguerrieri=maintain sprue-works-bot=write' run -R o/r maguerrieri)"
record 1 'the sessions'"'"' own login, below admin' "$(run -R o/r sprue-works-bot)"
record 1 'and in another case' "$(run -R o/r Sprue-Works-Bot)"

# Sessions posting as the owner's own account: same-account mode.
record 3 'the sessions'"'"' own login, an admin' "$(STUB_ME=maguerrieri run -R o/r maguerrieri)"
record 3 'matched case-insensitively' "$(STUB_ME=maguerrieri run -R o/r MAGUERRIERI)"
record 3 'and with gh printing the login in another case' "$(STUB_ME=MaGuerrieri run -R o/r maguerrieri)"
record 1 'another admin, while the sessions'"'"' login is an admin' \
	"$(STUB_ME=maguerrieri STUB_PERMS='maguerrieri=admin coadmin=admin' run -R o/r coadmin)"

# Logins that must never reach a URL or the shell: no gh call at all.
for bad in 'copilot-pull-request-reviewer[bot]' 'chatgpt-codex-connector[bot]' '' '-lead' 'trail-' 'two--dash' \
	'has space' 'a/b' '../x' '$(id)' 'x;id' "$(printf 'a%.0s' {1..40})" "$(printf 'a-%.0s' {1..19})ab"; do
	record '1 calls=0' "the malformed login '$bad'" "$(run -R o/r "$bad") calls=$(calls)"
done
record 0 'a 39-character login is a valid one' \
	"$(STUB_PERMS="$(printf 'a%.0s' {1..39})=admin" run -R o/r "$(printf 'a%.0s' {1..39})")"

# Failed reads trust no one.
record 1 'a failed gh api user' "$(STUB_FAIL=user run -R o/r maguerrieri)"
record 1 'a failed read of the login'"'"'s permission' "$(STUB_FAIL=maguerrieri run -R o/r maguerrieri)"
record 1 'a failed read of the sessions'"'"' permission' "$(STUB_FAIL=sprue-works-bot run -R o/r maguerrieri)"
record 1 'an empty permission read' "$(STUB_EMPTY=maguerrieri run -R o/r maguerrieri)"
record 1 'an empty sessions'"'"' login' "$(STUB_ME= run -R o/r maguerrieri)"
record 1 'a malformed sessions'"'"' login' "$(STUB_ME='bot[bot]' run -R o/r maguerrieri)"
record 1 'a missing gh' "$(OWNER_CHECK_GH="$tmp/no-such-gh" run -R o/r maguerrieri)"

# Usage and -R.
record '1 calls=0' 'no login' "$(run -R o/r) calls=$(calls)"
record '1 calls=0' 'two logins' "$(run -R o/r maguerrieri mate) calls=$(calls)"
record '1 calls=0' '-R with no value' "$(run maguerrieri -R) calls=$(calls)"
for bad in 'o' 'o/r/x' '/r' 'o/' 'o/..' 'o/.' '-o/r' 'o/r;id' 'o o/r'; do
	record '1 calls=0' "the malformed repo '$bad'" "$(run -R "$bad" maguerrieri) calls=$(calls)"
done
record 0 'a repo name with dots, dashes and underscores' "$(run -R my-org/my_repo.js maguerrieri)"

# With no -R, the repo is origin's.
repo=$tmp/repo
git init -q -b main "$repo"
for u in https://github.com/o/r.git git@github.com:o/r.git ssh://git@github.com/o/r https://x-access-token@github.com/o/r/; do
	git -C "$repo" remote remove origin 2>/dev/null
	git -C "$repo" remote add origin "$u"
	: >"$tmp/args"
	(cd "$repo" && bash "$script" maguerrieri >/dev/null 2>&1)
	record 'api repos/o/r/collaborators/maguerrieri/permission --jq .permission' \
		"the repo read from origin $u" "$(grep -m1 maguerrieri "$tmp/args")"
done
git -C "$repo" remote set-url origin /some/local/path
record 1 'an origin with no owner/repo' "$(cd "$repo" && run maguerrieri)"
mkdir "$tmp/plain"
record 1 'no -R outside a repo' "$(cd "$tmp/plain" && GIT_CEILING_DIRECTORIES=$tmp run maguerrieri)"

finish
