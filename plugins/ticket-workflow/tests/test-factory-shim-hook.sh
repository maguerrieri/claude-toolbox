#!/usr/bin/env bash
# SessionStart hook tests: hooks/factory-shim.sh (software-factory design 2d).
#
# The hook's job is to make every `gh` call in a factory implementer session
# carry the App token — and, when it cannot, to make that visible rather than
# leave `gh` running as the user:
#
#   1. Outside a factory environment (no FACTORY_BROKER_URL) it is a no-op.
#   2. With a reachable broker it installs the wrapping shim and puts it first on
#      PATH via CLAUDE_ENV_FILE.
#   3. In proxy-injected mode — exactly when an unwrapped gh would act as the
#      *user* rather than fail on the sentinel — it installs a DENY shim instead,
#      so the first gh call fails loudly. (An unreachable broker is not that case:
#      pass-through mode means an unwrapped gh fails on its own, so the wrapping
#      shim is installed and each call fails closed.)
#   4. It never blocks the session: exit 0 in every case.
#
# Run: bash plugins/ticket-workflow/tests/test-factory-shim-hook.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
hook="$root/hooks/factory-shim.sh"
fake="$here/fixtures/fake-broker.py"
for tool in jq curl python3 git; do command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }; done

failures=0
ok() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$((failures + 1)); }
assert() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
refute() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi; }

work=$(mktemp -d)
pidfile="$work/pids"; : >"$pidfile"
cleanup() { while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done <"$pidfile"; rm -rf "$work"; }
trap cleanup EXIT

env "FAKE_BROKER_BOUND=Acme/Repo-A" python3 "$fake" >"$work/port" 2>"$work/broker.err" &
echo $! >>"$pidfile"
i=0; until grep -q '^PORT ' "$work/port" 2>/dev/null; do i=$((i+1)); [ "$i" -lt 100 ] || { echo "broker did not start" >&2; exit 2; }; sleep 0.05; done
broker="http://127.0.0.1:$(awk '{print $2}' "$work/port")"

# A stub gh for the hook's shim to wrap.
ghdir="$work/bin"; mkdir -p "$ghdir"
printf '#!/usr/bin/env bash\nexit 0\n' >"$ghdir/gh"; chmod +x "$ghdir/gh"
export PATH="$ghdir:$PATH"

# run_hook <env-file> [VAR=VALUE...] → runs the hook, returns its exit status
run_hook() {
	local envfile=$1; shift
	: >"$envfile"
	env CLAUDE_PLUGIN_ROOT="$root" CLAUDE_ENV_FILE="$envfile" FACTORY_TOKEN_CACHE_DIR="$work/cache" "$@" bash "$hook"
}

# --- 1. no-op outside a factory environment ---------------------------------------
e1="$work/env1"
assert "no FACTORY_BROKER_URL: exits 0" run_hook "$e1" env -u FACTORY_BROKER_URL
refute "no FACTORY_BROKER_URL: writes nothing to the env file" test -s "$e1"

# --- 2. the happy path -------------------------------------------------------------
e2="$work/env2"
out=$(run_hook "$e2" FACTORY_BROKER_URL="$broker" FACTORY_REPO=Acme/Repo-A GH_TOKEN=factory-token-required 2>"$work/e2.err")
assert "with a reachable broker: exits 0" test -n "$out"
assert "it exports a PATH putting a shim first" grep -q '^export PATH=' "$e2"
shim_dir=$(sed -n 's/^export PATH=//p' "$e2" | tr -d "'" | cut -d: -f1)
assert "the shim it points at exists and is executable" test -x "$shim_dir/gh"
assert "the shim wraps the helper" grep -q 'factory-token' "$shim_dir/gh"
refute "the shim is not the deny shim" grep -q 'is refused in this factory session' "$shim_dir/gh"
refute "no token is printed" grep -q ghs_fake "$work/e2.err"

# --- 3. the deny path ---------------------------------------------------------------
# Proxy-injected mode: the helper exits 3, and an unwrapped gh would act as the user.
e3="$work/env3"
assert "proxy-injected mode: still exits 0 (never blocks the session)" run_hook "$e3" FACTORY_BROKER_URL="$broker" FACTORY_REPO=Acme/Repo-A GH_TOKEN=proxy-injected
assert "proxy-injected mode: a PATH is still exported" grep -q '^export PATH=' "$e3"
deny_dir=$(sed -n 's/^export PATH=//p' "$e3" | tr -d "'" | cut -d: -f1)
assert "proxy-injected mode: the shim installed is the deny shim" grep -q 'is refused in this factory session' "$deny_dir/gh"
rc=0; PATH="$deny_dir:$PATH" gh api /user >/dev/null 2>"$work/deny.err" || rc=$?
assert "the deny shim refuses with a non-zero status" test "$rc" -ne 0
assert "the deny shim explains why" grep -q 'could not mint' "$work/deny.err"
assert "the deny shim warns against bypassing it" grep -q 'acts as the user' "$work/deny.err"

# An unreachable broker is a different case: the session is still in pass-through
# mode, so an unwrapped gh reads the sentinel and fails on its own. The wrapping
# shim is installed and each call fails closed with the broker's error.
e4="$work/env4"
assert "unreachable broker: exits 0" run_hook "$e4" FACTORY_BROKER_URL="http://127.0.0.1:1" FACTORY_REPO=Acme/Repo-A GH_TOKEN=factory-token-required
shim4=$(sed -n 's/^export PATH=//p' "$e4" | tr -d "'" | cut -d: -f1)
assert "unreachable broker: the wrapping shim is installed" grep -q 'factory-token' "$shim4/gh"
rc=0
PATH="$shim4:$PATH" FACTORY_TOKEN_CACHE_DIR="$work/cache4" GH_TOKEN=factory-token-required gh api /user >/dev/null 2>&1 || rc=$?
assert "unreachable broker: a gh call through the shim fails closed" test "$rc" -ne 0

# --- 5. no gh on PATH ---------------------------------------------------------------
# The hook used to exit early when gh was absent, installing no guard at all. If gh
# then appears later (a PATH change, a tool install), an unwrapped call would act as
# the user under proxy-injected mode. `shim` refuses when there is no real gh to
# wrap, and that refusal must reach the deny shim like any other.
e5="$work/env5"
empty_path="$work/nogh"; mkdir -p "$empty_path"
for t in bash sh env printf mkdir chmod id cat jq curl python3 sed grep tr paste cut; do
	src=$(command -v "$t" 2>/dev/null) && ln -sf "$src" "$empty_path/$t"
done
assert "no gh on PATH: still exits 0" \
	env PATH="$empty_path" CLAUDE_ENV_FILE="$e5" CLAUDE_PLUGIN_ROOT="$root" FACTORY_TOKEN_CACHE_DIR="$work/cache5" \
	FACTORY_BROKER_URL="$broker" FACTORY_REPO=Acme/Repo-A GH_TOKEN=factory-token-required \
	bash "$hook"
assert "no gh on PATH: a deny shim is installed rather than nothing" grep -q '^export PATH=' "$e5"
nogh_dir=$(sed -n 's/^export PATH=//p' "$e5" | tr -d "'" | cut -d: -f1)
assert "no gh on PATH: the shim installed is the deny shim" grep -q 'is refused in this factory session' "$nogh_dir/gh"

printf '\n%s\n' "$([ "$failures" -eq 0 ] && echo "all tests passed" || echo "$failures test(s) failed")"
exit "$([ "$failures" -eq 0 ] && echo 0 || echo 1)"
