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
#   3b. A 401 (no bearer reached the broker), a 403 that is not the broker's own
#      repository_not_bound, and a helper exit 4 for any reason other than the
#      repository boundary are all inconclusive, not refusals. A non-loopback
#      http:// broker URL is refused outright, userinfo forms included.
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
assert "well-behaved broker: helper replay refuses on the repository boundary" bash -c "printf '%s' \"\$1\" | grep -q 'refuses on the repository boundary (exit 4, reason=repository_not_bound)'" _ "$out"
refute "output never contains a token" bash -c "printf '%s' \"\$1\" | grep -q ghs_fake" _ "$out"

out=$(run "$script" --bound "$A" --foreign "$B" --broker "$leaky" --skip-github 2>&1) && rc=0 || rc=$?
assert "leaky broker: FAIL" test "$rc" -eq 1
assert "leaky broker: names the cross-repo leak" bash -c "printf '%s' \"\$1\" | grep -q 'broker leaks across repos'" _ "$out"

# A 403 that is not the broker's own repository_not_bound (a WAF, an IAM policy)
# proves nothing about repository binding: inconclusive, not a refusal.
waf=$(start_broker waf FAKE_BROKER_BOUND="$A" FAKE_BROKER_403_ERROR=blocked_by_waf)
out=$(run "$script" --bound "$A" --foreign "$B" --broker "$waf" --skip-github 2>&1) && rc=0 || rc=$?
assert "a 403 that is not repository_not_bound: FAIL" test "$rc" -eq 1
assert "the non-binding 403 is named as inconclusive" bash -c "printf '%s' \"\$1\" | grep -q 'not repository_not_bound (blocked_by_waf)'" _ "$out"

# Exit 4 for another reason (wrong permissions) is not a repository-boundary
# refusal either: a broken broker must not read as isolation.
# Leaky *and* wrong-permissioned: the replay for B gets a 200 the helper then
# refuses on permissions, so its exit 4 is not a repository-boundary refusal.
badperms=$(start_broker badperms FAKE_BROKER_BOUND="$A" FAKE_BROKER_LEAK=1 FAKE_BROKER_PERMS='{"contents":"write"}')
out=$(run "$script" --bound "$A" --foreign "$B" --broker "$badperms" --skip-github 2>&1) && rc=0 || rc=$?
assert "helper exit 4 for a non-boundary reason: FAIL" test "$rc" -eq 1
assert "the replay reason is named" bash -c "printf '%s' \"\$1\" | grep -q 'reason=wrong_permissions'" _ "$out"

# A userinfo URL whose real authority is not loopback must be refused outright.
refute "a loopback-looking userinfo URL is refused" run "$script" --bound "$A" --foreign "$B" --broker "http://127.0.0.1:80@evil.example" --skip-github

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

# Every PEM private-key header, not only RSA: a scan that misses EC, DSA, OPENSSH
# or an encrypted key reports a clean environment that is not.
for pem_kind in "EC" "DSA" "OPENSSH" "ENCRYPTED"; do
	out=$(run env SOME_KEY="-----BEGIN $pem_kind PRIVATE KEY-----" "$script" --bound "$A" --foreign "$B" --broker "$good" --skip-github 2>&1) && rc=0 || rc=$?
	assert "a $pem_kind PEM key in the environment: FAIL" test "$rc" -eq 1
done

# A malformed --bound/--foreign would be refused by the broker *because* it is
# malformed, so the run could print PASS without exercising a real foreign repo.
for bad in "Acme/Repo-A?probe" "Acme/Repo-A/extra" "no-slash" "/leading" "trailing/" "../etc" "Acme/../x"; do
	refute "--foreign $bad is a usage error" run "$script" --bound "$A" --foreign "$bad" --broker "$good" --skip-github
	refute "--bound $bad is a usage error" run "$script" --bound "$bad" --foreign "$B" --broker "$good" --skip-github
done
assert "a well-formed owner/repo pair is still accepted" run "$script" --bound "$A" --foreign "$B" --broker "$good" --skip-github

# Under `set -u` a bare option at the end of the line used to die with an
# unbound-variable error instead of the documented usage error.
for opt in --bound --foreign --broker; do
	out=$("$script" $opt 2>&1) && rc=0 || rc=$?
	assert "$opt with no value is a usage error (exit 2)" test "$rc" -eq 2
	assert "$opt with no value says which option is missing" \
		bash -c "printf '%s' \"\$1\" | grep -q -- \"\$2 needs a value\"" _ "$out" "$opt"
	refute "$opt with no value is not an unbound-variable crash" \
		bash -c "printf '%s' \"\$1\" | grep -qi 'unbound variable'" _ "$out"
done

printf '\n%s\n' "$([ "$failures" -eq 0 ] && echo "all tests passed" || echo "$failures test(s) failed")"
exit "$([ "$failures" -eq 0 ] && echo 0 || echo 1)"
