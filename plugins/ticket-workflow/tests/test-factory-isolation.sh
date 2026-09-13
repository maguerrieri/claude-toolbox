#!/usr/bin/env bash
# Tests for scripts/factory-isolation-test (spec 2d / item 8b), against
# tests/fixtures/fake-broker.py on loopback (--skip-github; the GitHub half needs a
# real installation token and runs in the cloud session per factory-identity.md).
#
#   1. A well-behaved broker (403 for a foreign repo) passes.
#   2. A broker that mints for any repository asked (the leak the spec's test
#      exists to catch) fails on path 1; an unreachable or 5xx broker fails as
#      inconclusive rather than passing as "no token".
#   3. A bearer-shaped or PEM value in the environment fails path 4.
#   3b. A 401 (no bearer reached the broker) is inconclusive, not a refusal, and a
#      non-loopback http:// broker URL is refused outright.
#   4. Usage errors: same repo for both, missing args.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../scripts/factory-isolation-test"
fake="$here/fixtures/fake-broker.py"
for tool in jq curl python3; do command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }; done

failures=0
ok() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$((failures + 1)); }
assert() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
refute() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi; }

work=$(mktemp -d)
# start_broker runs inside $(...) subshells, so PIDs go to a file the parent reads
# at cleanup (an array append in the subshell would be lost and the servers leak).
pidfile="$work/pids"
: >"$pidfile"
cleanup() {
	while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done <"$pidfile"
	rm -rf "$work"
}
trap cleanup EXIT
start_broker() {
	local name=$1; shift
	local out="$work/$name.port"
	env "$@" python3 "$fake" >"$out" 2>"$work/$name.err" &
	echo $! >>"$pidfile"
	local i=0
	until grep -q '^PORT ' "$out" 2>/dev/null; do
		i=$((i + 1)); [ "$i" -lt 100 ] || { echo "fake broker $name did not start" >&2; exit 2; }
		sleep 0.05
	done
	printf 'http://127.0.0.1:%s' "$(awk '{print $2}' "$out")"
}

A="Acme/Repo-A"; B="Acme/Repo-B"
good=$(start_broker good FAKE_BROKER_BOUND="$A")
leaky=$(start_broker leaky FAKE_BROKER_BOUND="$A" FAKE_BROKER_LEAK=1)

# A clean environment: no sentinel (local), no bearer-shaped values.
run() { env -i PATH="$PATH" HOME="$HOME" "$@"; }

out=$(run "$script" --bound "$A" --foreign "$B" --broker "$good" --skip-github 2>&1) && rc=0 || rc=$?
assert "well-behaved broker: PASS" test "$rc" -eq 0
assert "well-behaved broker: reports the foreign 403 as a refusal" bash -c "printf '%s' \"\$1\" | grep -q 'refused (HTTP 403)'" _ "$out"
assert "well-behaved broker: helper replay refuses with exit 4" bash -c "printf '%s' \"\$1\" | grep -q 'helper replayed with --repo Acme/Repo-B refuses (exit 4'" _ "$out"
refute "output never contains a token" bash -c "printf '%s' \"\$1\" | grep -q ghs_fake" _ "$out"

out=$(run "$script" --bound "$A" --foreign "$B" --broker "$leaky" --skip-github 2>&1) && rc=0 || rc=$?
assert "leaky broker: FAIL" test "$rc" -eq 1
assert "leaky broker: names the cross-repo leak" bash -c "printf '%s' \"\$1\" | grep -q 'broker leaks across repos'" _ "$out"

# A broker that is down, or answers 5xx, is inconclusive and must FAIL, not pass.
out=$(run "$script" --bound "$A" --foreign "$B" --broker "http://127.0.0.1:1" --skip-github 2>&1) && rc=0 || rc=$?
assert "unreachable broker: FAIL (inconclusive, not isolated)" test "$rc" -eq 1
assert "unreachable broker: all three broker paths report inconclusive" test "$(printf '%s' "$out" | grep -c 'inconclusive')" -eq 3
broken=$(start_broker broken FAKE_BROKER_BOUND="$A" FAKE_BROKER_STATUS=500)
out=$(run "$script" --bound "$A" --foreign "$B" --broker "$broken" --skip-github 2>&1) && rc=0 || rc=$?
assert "broker answering 500: FAIL" test "$rc" -eq 1

bearer="fb_$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' | cut -c1-43)"
out=$(run env FACTORY_BROKER_BEARER="$bearer" "$script" --bound "$A" --foreign "$B" --broker "$good" --skip-github 2>&1) && rc=0 || rc=$?
assert "bearer in the environment: FAIL" test "$rc" -eq 1
assert "bearer in the environment: both the shape and the name are flagged" bash -c "printf '%s' \"\$1\" | grep -q 'bearer-shaped' && printf '%s' \"\$1\" | grep -q 'names a broker/App credential variable'" _ "$out"
refute "bearer value is never echoed" bash -c "printf '%s' \"\$1\" | grep -q \"\$2\"" _ "$out" "$bearer"

out=$(run env SOME_KEY="-----BEGIN RSA PRIVATE KEY-----" "$script" --bound "$A" --foreign "$B" --broker "$good" --skip-github 2>&1) && rc=0 || rc=$?
assert "PEM in the environment: FAIL" test "$rc" -eq 1

out=$(run env GH_TOKEN=proxy-injected "$script" --bound "$A" --foreign "$B" --broker "$good" --skip-github 2>&1) && rc=0 || rc=$?
assert "proxy-injected environment: FAIL (M1 not in effect)" test "$rc" -eq 1
assert "proxy-injected environment: the helper replay is reported as not exercised" bash -c "printf '%s' \"\$1\" | grep -q 'exit 3'" _ "$out"
out=$(run env GH_TOKEN=factory-token-required "$script" --bound "$A" --foreign "$B" --broker "$good" --skip-github 2>&1) && rc=0 || rc=$?
assert "pass-through sentinel environment: PASS" test "$rc" -eq 0

# A bearer that never reaches the broker (401) proves nothing: inconclusive, not pass.
nobearer=$(start_broker nobearer FAKE_BROKER_BOUND="$A" FAKE_BROKER_REQUIRE_BEARER=neverSent)
out=$(run "$script" --bound "$A" --foreign "$B" --broker "$nobearer" --skip-github 2>&1) && rc=0 || rc=$?
assert "401 from the broker: FAIL (no bearer reached it)" test "$rc" -eq 1
assert "401 is reported as no bearer, not as a refusal" bash -c "printf '%s' \"\$1\" | grep -q 'no bearer reached the broker'" _ "$out"

refute "a non-loopback http:// broker URL is a usage error" run "$script" --bound "$A" --foreign "$B" --broker "http://broker.example" --skip-github
refute "same repo for --bound and --foreign is a usage error" run "$script" --bound "$A" --foreign "$A" --broker "$good" --skip-github
refute "missing --foreign is a usage error" run "$script" --bound "$A" --broker "$good" --skip-github

printf '\n%s\n' "$([ "$failures" -eq 0 ] && echo "all tests passed" || echo "$failures test(s) failed")"
exit "$([ "$failures" -eq 0 ] && echo 0 || echo 1)"
