#!/usr/bin/env bash
# factory-token helper tests (software-factory design, section 2d / item 8b).
#
# Runs the helper against tests/fixtures/fake-broker.py (loopback, no network)
# and a stub `gh`, and pins the behaviour the spec relies on:
#
#   1. `exec` is a wrapper, not an exporter: the command it runs sees GH_TOKEN
#      (and GITHUB_TOKEN), the token never reaches stdout, stderr, or argv, and
#      the cache file is 0600.
#   2. Caching: one broker call across repeated invocations, a re-mint inside the
#      refresh window, `--force` re-mints, and the cached expiry is capped at an
#      hour.
#   3. Fail closed: proxy-injected mode (exit 3, no broker call); a token for a
#      repository other than the one asked for (exit 4); permissions that are not
#      exactly the five 2d names (exit 4); an already-expired token (exit 4); a
#      403, a 429 budget refusal, a 5xx, a malformed body, a non-loopback
#      http:// broker (userinfo forms included), a missing broker URL. Each exit-4
#      refusal carries a machine-readable [reason=…] slug, and `exec` leaves no
#      broker response behind despite replacing the shell.
#   4. `shim` installs a `gh` shim that wraps the real gh and does not recurse.
#   5. `setup-git` runs `gh auth setup-git` with the token in the environment,
#      points an SSH origin's push URL at HTTPS, sets the App's commit identity,
#      and fails closed (discarding the token) without App metadata.
#   6. `normalize-commits` rewrites author and committer of the platform-default
#      commits in the PR's own range, leaves App-authored ones alone, stops on a
#      foreign identity (exit 6), and never touches the base's history or the tree.
#   7. The repository is resolved from the origin remote in all three GitHub URL
#      forms; a lookalike host or another host is refused rather than parsed.
#
# Stdlib only: bash, jq, curl, python3, git. Run: bash plugins/ticket-workflow/tests/test-factory-token.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
helper="$here/../scripts/factory-token"
fake="$here/fixtures/fake-broker.py"
for tool in jq curl python3 git; do
	command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }
done

failures=0
ok() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$((failures + 1)); }
assert() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
refute() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi; }
# expect_exit <desc> <code> <command...>
expect_exit() {
	local desc=$1 want=$2 got=0; shift 2
	"$@" >/dev/null 2>&1 || got=$?
	if [ "$got" = "$want" ]; then ok "$desc"; else fail "$desc (exit $got, wanted $want)"; fi
}

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
		i=$((i + 1)); [ "$i" -lt 100 ] || { echo "fake broker $name did not start: $(cat "$work/$name.err")" >&2; exit 2; }
		sleep 0.05
	done
	printf 'http://127.0.0.1:%s' "$(awk '{print $2}' "$out")"
}

# A stub `gh` that records its arguments and whether it saw a real GH_TOKEN.
ghdir="$work/bin"
mkdir -p "$ghdir"
cat >"$ghdir/gh" <<'GH'
#!/usr/bin/env bash
printf '%s|%s\n' "$*" "${GH_TOKEN:-<unset>}" >>"$GH_STUB_LOG"
exit 0
GH
chmod +x "$ghdir/gh"
export GH_STUB_LOG="$work/gh.log"
: >"$GH_STUB_LOG"
export PATH="$ghdir:$PATH"

BOUND="Acme/Repo-A"
counts="$work/counts"
: >"$counts"
good=$(start_broker good FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_COUNT_FILE="$counts")
lenient=$(start_broker lenient FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_LENIENT=1)
leaky=$(start_broker leaky FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_LEAK=1)
broken=$(start_broker broken FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_STATUS=500)
noexpin=$(start_broker noexpin FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_OMIT_EXPIRES_IN=1)

# Every invocation gets its own cache dir unless a test wants sharing; GH_TOKEN
# carries the pass-through sentinel the implementer environment sets.
run() { local cache=$1; shift; FACTORY_TOKEN_CACHE_DIR="$cache" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$good" "$helper" "$@"; }
# token_of <cache-dir>
token_of() { jq -r .token "$1"/*.json; }

# --- 1. exec is a wrapper -------------------------------------------------------
c1="$work/c1"
out=$(run "$c1" --repo "$BOUND" exec -- sh -c 'printf "%s %s" "$GH_TOKEN" "$GITHUB_TOKEN"' 2>"$work/c1.err")
assert "exec runs the command with GH_TOKEN and GITHUB_TOKEN set" test "$out" = "$(token_of "$c1") $(token_of "$c1")"
# No environment flag is set for the shim to trust: the recursion guard reads
# GH_TOKEN, which a caller cannot forge without already holding a token.
assert "exec sets no FACTORY_TOKEN_ACTIVE flag for a caller to spoof" \
	test -z "$(run "$c1" --repo "$BOUND" exec -- sh -c 'printf %s "${FACTORY_TOKEN_ACTIVE:-}"')"
assert "exec works without the -- separator" test "$(run "$c1" --repo "$BOUND" exec sh -c 'printf %s "$GH_TOKEN"')" = "$(token_of "$c1")"
refute "token never on stderr" grep -q ghs_fake "$work/c1.err"
# `exec` replaces the shell, so the EXIT trap never runs: the broker response must
# already be gone, or a second copy of the token outlives the command.
# Loose mktemp files only (the 0600 cache file is deliberate and lives elsewhere).
loose_temp_with_token() { find "${TMPDIR:-/tmp}" -maxdepth 1 -type f -name 'tmp.*' -exec grep -l ghs_fake {} + 2>/dev/null | grep -q .; }
refute "no stray broker response before" loose_temp_with_token
FACTORY_TOKEN_CACHE_DIR="$work/cx" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$good" "$helper" --repo "$BOUND" exec -- true
refute "exec leaves no broker response holding the token" loose_temp_with_token
expect_exit "a refusal leaves none either" 4 env FACTORY_TOKEN_CACHE_DIR="$work/cy" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$lenient" "$helper" --repo "Acme/Repo-B" exec -- true
refute "a refused mint leaves no broker response either" loose_temp_with_token
err=$(run "$work/cerr" --repo "not-a-repo" exec -- true 2>&1 || true)
refute "a die message does not end in its exit code" bash -c "printf '%s' \"\$1\" | grep -qE '[^0-9]4\$|[^0-9]2\$'" _ "$err"
assert "cache file is mode 0600" bash -c "[ \"\$(stat -c %a \"\$1\"/*.json)\" = 600 ]" _ "$c1"
# The file must never exist as 0644 first: created under umask 077, not chmodded.
cumask="$work/cumask"
( umask 000 && FACTORY_TOKEN_CACHE_DIR="$cumask" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$good" "$helper" --repo "$BOUND" exec -- true )
assert "cache file is 0600 even under a permissive umask" bash -c "[ \"\$(stat -c %a \"\$1\"/*.json)\" = 600 ]" _ "$cumask"
rc=0; run "$c1" --repo "$BOUND" exec -- sh -c 'exit 7' || rc=$?
assert "exec passes the command's exit status through" test "$rc" -eq 7
expect_exit "exec with nothing to run is a usage error" 2 run "$c1" --repo "$BOUND" exec
refute "there is no env subcommand (a wrapper, not an exporter)" run "$c1" --repo "$BOUND" env

# --- 2. caching ----------------------------------------------------------------
before=$(wc -l <"$counts")
run "$c1" --repo "$BOUND" exec -- true
run "$c1" --repo "$BOUND" exec -- true
assert "repeat calls hit the cache (no new broker calls)" test "$(wc -l <"$counts")" -eq "$before"
run "$c1" --force --repo "$BOUND" exec -- true
assert "--force re-mints" test "$(wc -l <"$counts")" -eq $((before + 1))
before=$(wc -l <"$counts")
FACTORY_TOKEN_REFRESH_SECONDS=999999 run "$c1" --repo "$BOUND" exec -- true
assert "inside the refresh window re-mints" test "$(wc -l <"$counts")" -eq $((before + 1))
c2="$work/c2"
longlived=$(start_broker longlived FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_EXPIRES_IN=86400)
FACTORY_BROKER_URL="$longlived" FACTORY_TOKEN_CACHE_DIR="$c2" GH_TOKEN=factory-token-required "$helper" --repo "$BOUND" exec -- true
assert "cached expiry is capped at one hour" test "$(jq -r .expires_epoch "$c2"/*.json)" -le $(($(date -u +%s) + 3600))
if date -u -d 2026-01-01T00:00:00Z +%s >/dev/null 2>&1; then
	assert "expires_at without expires_in is accepted" env FACTORY_BROKER_URL="$noexpin" FACTORY_TOKEN_CACHE_DIR="$work/c3" GH_TOKEN=factory-token-required "$helper" --repo "$BOUND" exec -- true
fi

# --- 3. fail closed ------------------------------------------------------------
c4="$work/c4"
before=$(wc -l <"$counts")
expect_exit "proxy-injected mode refuses (exit 3)" 3 env FACTORY_TOKEN_CACHE_DIR="$c4" GH_TOKEN=proxy-injected FACTORY_BROKER_URL="$good" "$helper" --repo "$BOUND" exec -- true
assert "proxy-injected mode makes no broker call" test "$(wc -l <"$counts")" -eq "$before"
refute "proxy-injected mode caches nothing" ls "$c4"

c5="$work/c5"
expect_exit "a token for another repo than asked is refused (exit 4)" 4 env FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$lenient" "$helper" --repo "Acme/Repo-B" exec -- true
refute "mismatched token: nothing cached" ls "$c5"
expect_exit "well-behaved broker: foreign repo gets 403 → exit 4" 4 run "$c5" --repo "Acme/Repo-B" exec -- true
err=$(run "$c5" --repo "Acme/Repo-B" exec -- true 2>&1 || true)
assert "the foreign-repo refusal carries reason=repository_not_bound" bash -c "printf '%s' \"\$1\" | grep -q '\[reason=repository_not_bound\]'" _ "$err"
err=$(FACTORY_TOKEN_CACHE_DIR="$work/cmm" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$lenient" "$helper" --repo "Acme/Repo-B" exec -- true 2>&1 || true)
assert "a mismatched token carries reason=repository_mismatch" bash -c "printf '%s' \"\$1\" | grep -q '\[reason=repository_mismatch\]'" _ "$err"
expect_exit "broker 500 → exit 5" 5 env FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$broken" "$helper" --repo "$BOUND" exec -- true
expect_exit "unreachable broker → exit 5" 5 env FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="http://127.0.0.1:1" "$helper" --repo "$BOUND" exec -- true
expect_exit "non-loopback http:// broker refused (exit 2)" 2 env FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="http://broker.example" "$helper" --repo "$BOUND" exec -- true
# The loopback allowance is an authority check, not a prefix match: curl reads
# `http://127.0.0.1:80@evil.example` as host evil.example.
for bad_url in "http://127.0.0.1:80@evil.example" "http://localhost@evil.example/x" "http://127.0.0.1.evil.example" "http://127.0.0.1:notaport"; do
	expect_exit "http broker $bad_url is refused (exit 2)" 2 env FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$bad_url" "$helper" --repo "$BOUND" exec -- true
done
expect_exit "missing broker URL → exit 2" 2 env FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL= "$helper" --repo "$BOUND" exec -- true
expect_exit "malformed repository → exit 2" 2 run "$c5" --repo "not-a-repo" exec -- true
# A leaky broker (mints for whatever is asked) is the isolation test's to catch.
assert "leaky broker is invisible to the helper (isolation test's job)" env FACTORY_TOKEN_CACHE_DIR="$work/c5b" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$leaky" "$helper" --repo "Acme/Repo-B" exec -- true

# Permissions must be exactly the five spec 2d names.
for perms in \
	'{"contents":"write","pull_requests":"write"}' \
	'{"contents":"read","pull_requests":"write","issues":"write","checks":"read","metadata":"read"}' \
	'{"contents":"write","pull_requests":"write","issues":"read","checks":"read","metadata":"read"}' \
	'{"contents":"write","pull_requests":"write","issues":"write","checks":"write","metadata":"read"}' \
	'{"contents":"write","pull_requests":"write","issues":"write","checks":"read","metadata":"read","administration":"read"}'; do
	b=$(start_broker "perms$RANDOM" FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_PERMS="$perms")
	cp="$work/cp-$RANDOM"
	expect_exit "permissions $perms are refused (exit 4)" 4 env FACTORY_TOKEN_CACHE_DIR="$cp" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$b" "$helper" --repo "$BOUND" exec -- true
	refute "permissions $perms: nothing cached" ls "$cp"
done
b=$(start_broker permsok FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_PERMS='{"contents":"write","pull_requests":"write","issues":"write","checks":"read","metadata":"read"}')
assert "exactly the five permissions is accepted" env FACTORY_TOKEN_CACHE_DIR="$work/c9" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$b" "$helper" --repo "$BOUND" exec -- true

# A present-but-unparsable expires_at is a refusal even when expires_in is fine:
# the unparsed one may be earlier, and holding to the later value outlives it.
badat=$(start_broker badat FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_EXPIRES_AT=not-a-timestamp)
expect_exit "an unparsable expires_at is refused even with expires_in present (exit 4)" 4 env FACTORY_TOKEN_CACHE_DIR="$work/cbad" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$badat" "$helper" --repo "$BOUND" exec -- true
refute "unparsable expires_at: nothing cached" ls "$work/cbad"

expired=$(start_broker expired FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_EXPIRED=1)
c10="$work/c10"
expect_exit "an already-expired token is refused (exit 4)" 4 env FACTORY_TOKEN_CACHE_DIR="$c10" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$expired" "$helper" --repo "$BOUND" exec -- true
refute "expired token: nothing cached" ls "$c10"

budgeted=$(start_broker budgeted FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_BUDGET=1)
c11="$work/c11"
assert "first mint under the budget succeeds" env FACTORY_TOKEN_CACHE_DIR="$c11" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$budgeted" "$helper" --repo "$BOUND" exec -- true
expect_exit "a 429 budget refusal is reported as a broker refusal (exit 4)" 4 env FACTORY_TOKEN_CACHE_DIR="$work/c11b" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$budgeted" "$helper" --repo "$BOUND" exec -- true

# --- 4. shim -------------------------------------------------------------------
c6="$work/c6"
shimdir="$work/shim"
shim_out=$(cd "$work" && run "$c6" --repo "$BOUND" shim "$shimdir" 2>"$work/shim.err")
assert "shim writes an executable gh" test -x "$shimdir/gh"
assert "shim prints a PATH export putting itself first" bash -c "printf '%s' \"\$1\" | grep -q \"^export PATH=.*$shimdir\"" _ "$shim_out"
assert "shim bakes the repository in, so it works from any directory" grep -q -- "--repo" "$shimdir/gh"
assert "shim bakes the broker in, so it does not need the env var later" grep -q -- "--broker" "$shimdir/gh"
# With neither the env var nor a flag, the shim must still reach its broker.
: >"$GH_STUB_LOG"
( cd "$work" && env -u FACTORY_BROKER_URL PATH="$shimdir:$PATH" FACTORY_TOKEN_CACHE_DIR="$c6" GH_TOKEN=factory-token-required gh api /rate_limit )
assert "the shim works with FACTORY_BROKER_URL unset" grep -q "api /rate_limit|" "$GH_STUB_LOG"
expect_exit "shim refuses to install without a broker URL" 2 bash -c "cd $work && env -u FACTORY_BROKER_URL FACTORY_TOKEN_CACHE_DIR=$c6 GH_TOKEN=factory-token-required $helper --repo $BOUND shim $work/shim2"
refute "shim never prints the token" bash -c "printf '%s%s' \"\$1\" \"\$(cat \"\$2\")\" | grep -q ghs_fake" _ "$shim_out" "$work/shim.err"
: >"$GH_STUB_LOG"
( cd "$work" && PATH="$shimdir:$PATH" FACTORY_TOKEN_CACHE_DIR="$c6" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$good" gh api /rate_limit )
assert "a gh call through the shim carries the App token" grep -q "api /rate_limit|$(token_of "$c6")" "$GH_STUB_LOG"
: >"$GH_STUB_LOG"
( cd "$work" && PATH="$shimdir:$PATH" FACTORY_TOKEN_CACHE_DIR="$c6" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$good" "$helper" --repo "$BOUND" exec -- gh api /user )
assert "the shim does not recurse inside exec (one gh invocation)" test "$(wc -l <"$GH_STUB_LOG")" -eq 1
# No environment flag may turn the shim into a pass-through. A caller can set any
# variable, so a flag-based guard would let `FOO=... gh` reach the real gh with
# whatever credential the session carries — under proxy-injected mode, the user's.
for bogus in 0 1 true "$BOUND" "Other/Repo"; do
	: >"$GH_STUB_LOG"
	( cd "$work" && PATH="$shimdir:$PATH" FACTORY_TOKEN_CACHE_DIR="$c6" GH_TOKEN=factory-token-required \
		FACTORY_BROKER_URL="$good" FACTORY_TOKEN_ACTIVE="$bogus" gh api /rate_limit )
	assert "FACTORY_TOKEN_ACTIVE=$bogus still goes through the wrapper" \
		grep -q "api /rate_limit|$(token_of "$c6")" "$GH_STUB_LOG"
done
# Each environment sentinel means "no token yet", so each must be wrapped.
for sentinel in factory-token-required ""; do
	: >"$GH_STUB_LOG"
	( cd "$work" && PATH="$shimdir:$PATH" FACTORY_TOKEN_CACHE_DIR="$c6" GH_TOKEN="$sentinel" \
		FACTORY_BROKER_URL="$good" gh api /rate_limit )
	assert "GH_TOKEN=${sentinel:-(empty)} goes through the wrapper" \
		grep -q "api /rate_limit|$(token_of "$c6")" "$GH_STUB_LOG"
done
# proxy-injected is also wrapped, and the wrapper then refuses: running gh there
# would act as the user, so a non-zero exit with no gh call is the right outcome.
: >"$GH_STUB_LOG"
expect_exit "GH_TOKEN=proxy-injected is wrapped and refused (exit 3)" 3 bash -c \
	"cd $work && PATH=$(printf '%q' "$shimdir"):\$PATH FACTORY_TOKEN_CACHE_DIR=$c6 GH_TOKEN=proxy-injected FACTORY_BROKER_URL=$good gh api /rate_limit"
refute "proxy-injected: the real gh is never reached" test -s "$GH_STUB_LOG"

# The shim's default directory must not be shared across repositories: two
# implementer sessions on one VM would otherwise overwrite each other's gh.
OTHER=Acme/Repo-Other
other_broker=$(start_broker other FAKE_BROKER_BOUND="$OTHER")
cshare="$work/cshare"
d1=$( cd "$work" && FACTORY_TOKEN_CACHE_DIR="$cshare" GH_TOKEN=factory-token-required \
	"$helper" --repo "$BOUND" --broker "$good" shim 2>/dev/null | sed 's/^export PATH=//' | tr -d "'" | cut -d: -f1 )
d2=$( cd "$work" && FACTORY_TOKEN_CACHE_DIR="$cshare" GH_TOKEN=factory-token-required \
	"$helper" --repo "$OTHER" --broker "$other_broker" shim 2>/dev/null | sed 's/^export PATH=//' | tr -d "'" | cut -d: -f1 )
assert "two repositories get different default shim directories" test "$d1" != "$d2"
assert "the first repository's shim still names its own repository" grep -q -- "$BOUND" "$d1/gh"
assert "the second repository's shim names its own repository" grep -q -- "$OTHER" "$d2/gh"

# A cache entry gets the same scrutiny a fresh mint does: it may have been left by
# an older helper or a different broker, and `exec` puts it into a real process.
ctamper="$work/ctamper"
run "$ctamper" --repo "$BOUND" exec -- true >/dev/null 2>&1
tfile=$(ls "$ctamper"/*.json)
good_entry=$(cat "$tfile")
restore_entry() { printf '%s' "$good_entry" >"$tfile"; }
# Wrong permissions in the cache must not reach a process.
jq -c '.permissions = {"contents":"write","metadata":"read"}' <<<"$good_entry" >"$tfile"
assert "a cached token with the wrong permissions is re-minted, not used" \
	test "$(run "$ctamper" --repo "$BOUND" exec -- sh -c 'printf %s "$GH_TOKEN"')" = "$(token_of "$ctamper")"
restore_entry
jq -c 'del(.token)' <<<"$good_entry" >"$tfile"
assert "a cached entry with no token is re-minted" \
	test -n "$(run "$ctamper" --repo "$BOUND" exec -- sh -c 'printf %s "$GH_TOKEN"')"
restore_entry
jq -c '.expires_epoch = "soon"' <<<"$good_entry" >"$tfile"
assert "a cached entry with a non-numeric expiry is re-minted" \
	test -n "$(run "$ctamper" --repo "$BOUND" exec -- sh -c 'printf %s "$GH_TOKEN"')"
restore_entry
# The cache is bound to the broker that issued it.
assert "the cache entry records its issuing broker" test "$(jq -r '.broker' "$tfile")" = "$good"
second=$(start_broker second FAKE_BROKER_BOUND="$BOUND")
old_token=$(token_of "$ctamper")
( cd "$work" && FACTORY_TOKEN_CACHE_DIR="$ctamper" GH_TOKEN=factory-token-required \
	"$helper" --repo "$BOUND" --broker "$second" exec -- true ) >/dev/null 2>&1
assert "pointing at a different broker re-mints instead of reusing the old token" \
	test "$(jq -r '.broker' "$tfile")" = "$second"
refute "the old broker's token is not carried over" test "$(token_of "$ctamper")" = "$old_token"
# A GH_TOKEN that is already a real token means the caller is inside `exec`.
: >"$GH_STUB_LOG"
( cd "$work" && PATH="$shimdir:$PATH" FACTORY_TOKEN_CACHE_DIR="$c6" GH_TOKEN="$(token_of "$c6")" \
	FACTORY_BROKER_URL="$good" gh api /rate_limit )
assert "an already-minted GH_TOKEN short-circuits to the real gh" \
	test "$(wc -l <"$GH_STUB_LOG")" -eq 1

# A previous session's deny shim stays on PATH through CLAUDE_ENV_FILE. If `shim`
# resolved it as the real gh, the new wrapper would call the deny shim and every
# gh call stayed refused even after the broker came back.
stale="$work/stale-deny"; mkdir -p "$stale"
cat >"$stale/gh" <<'DENY'
#!/usr/bin/env bash
# factory-token-generated-shim
echo "gh is refused in this factory session" >&2
exit 3
DENY
chmod 755 "$stale/gh"
shim2="$work/shim-after-deny"
( cd "$work" && PATH="$stale:$PATH" run "$c6" --repo "$BOUND" shim "$shim2" ) >/dev/null 2>&1
assert "shim never resolves a factory-generated shim as the real gh" \
	bash -c "! grep -q $(printf '%q' "$stale/gh") $(printf '%q' "$shim2/gh")"
: >"$GH_STUB_LOG"
( cd "$work" && PATH="$shim2:$stale:$PATH" FACTORY_TOKEN_CACHE_DIR="$c6" GH_TOKEN=factory-token-required \
	FACTORY_BROKER_URL="$good" gh api /rate_limit )
assert "a session recovers after a stale deny shim: the call reaches the real gh" \
	grep -q "api /rate_limit|$(token_of "$c6")" "$GH_STUB_LOG"
# The "no real gh at all" case is covered by test-factory-shim-hook.sh, which runs
# the hook on a stripped PATH and asserts the deny shim is what lands.

# --- 5. setup-git ---------------------------------------------------------------
repo="$work/checkout"
git init -q "$repo" && git -C "$repo" remote add origin "git@github.com:$BOUND.git"
: >"$GH_STUB_LOG"
( cd "$repo" && run "$c6" setup-git 2>"$work/setup.err" )
assert "setup-git runs gh auth setup-git with the App token" grep -q "^auth setup-git|$(token_of "$c6")\$" "$GH_STUB_LOG"
# The nested call must carry the outer --repo/--broker, not re-resolve from cwd.
repo3="$work/checkout3"; c12="$work/c12"
git init -q "$repo3" && git -C "$repo3" remote add origin "https://github.com/Other/Repo"
: >"$GH_STUB_LOG"
( cd "$repo3" && FACTORY_TOKEN_CACHE_DIR="$c12" GH_TOKEN=factory-token-required "$helper" --repo "$BOUND" --broker "$good" setup-git 2>/dev/null )
assert "setup-git honours an explicit --repo over the checkout's origin" test "$(git -C "$repo3" config --local remote.origin.pushurl)" = "https://github.com/$BOUND.git"
assert "the nested gh auth setup-git used that same token" grep -q "^auth setup-git|$(token_of "$c12")\$" "$GH_STUB_LOG"
# Raw config keys, not `git remote get-url`: an environment-level insteadOf
# rewrite (the cloud git proxy has one) would mask what setup-git actually wrote.
assert "setup-git sets an HTTPS push URL for the SSH origin" test "$(git -C "$repo" config --local remote.origin.pushurl)" = "https://github.com/$BOUND.git"
assert "setup-git leaves the fetch URL alone" test "$(git -C "$repo" config --local remote.origin.url)" = "git@github.com:$BOUND.git"
assert "setup-git sets the App noreply author email" test "$(git -C "$repo" config --local user.email)" = "424242+factory-fake[bot]@users.noreply.github.com"
assert "setup-git sets the bot user.name" test "$(git -C "$repo" config --local user.name)" = "factory-fake[bot]"
refute "setup-git logs no token" grep -q ghs_fake "$work/setup.err"

noapp=$(start_broker noapp FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_NO_APP=1)
repo2="$work/checkout2"; c7="$work/c7"
git init -q "$repo2" && git -C "$repo2" remote add origin "https://github.com/$BOUND"
expect_exit "setup-git refuses when the broker names no app slug/bot id (exit 4)" 4 bash -c "cd $repo2 && FACTORY_TOKEN_CACHE_DIR=$c7 GH_TOKEN=factory-token-required FACTORY_BROKER_URL=$noapp $helper setup-git"
refute "setup-git without app metadata leaves user.email unset" git -C "$repo2" config --local user.email
refute "setup-git failure discards the cached token" ls "$c7"/*.json

# --- 6. normalize-commits --------------------------------------------------------
nrepo="$work/normalize"
git init -q -b main "$nrepo"
git -C "$nrepo" remote add origin "https://github.com/$BOUND"
commit_as() { # commit_as <repo> <name> <email> <file> <message>
	printf '%s\n' "$5" >"$1/$4"
	git -C "$1" add -A
	GIT_AUTHOR_NAME=$2 GIT_AUTHOR_EMAIL=$3 GIT_COMMITTER_NAME=$2 GIT_COMMITTER_EMAIL=$3 \
		git -C "$1" commit -q -m "$5"
}
commit_as "$nrepo" "Someone" "someone@example.com" base.txt "base commit"
git -C "$nrepo" update-ref refs/remotes/origin/main HEAD
commit_as "$nrepo" "claude" "noreply@anthropic.com" a.txt "first platform-identity commit"
commit_as "$nrepo" "factory-fake[bot]" "424242+factory-fake[bot]@users.noreply.github.com" b.txt "already the App"
commit_as "$nrepo" "claude" "noreply@anthropic.com" c.txt "second platform-identity commit"
tree_before=$(git -C "$nrepo" rev-parse 'HEAD^{tree}')
base_before=$(git -C "$nrepo" rev-parse origin/main)
( cd "$nrepo" && run "$c6" normalize-commits main 2>"$work/norm.err" )
app_email="424242+factory-fake[bot]@users.noreply.github.com"
assert "every commit in the range now carries the App author" test "$(git -C "$nrepo" log origin/main..HEAD --format='%ae' | sort -u)" = "$app_email"
assert "every commit in the range now carries the App committer" test "$(git -C "$nrepo" log origin/main..HEAD --format='%ce' | sort -u)" = "$app_email"
assert "the tree is unchanged" test "$(git -C "$nrepo" rev-parse 'HEAD^{tree}')" = "$tree_before"
assert "the base's commit is untouched" test "$(git -C "$nrepo" rev-parse origin/main)" = "$base_before"
assert "the base commit keeps its own author" test "$(git -C "$nrepo" show -s --format='%ae' origin/main)" = "someone@example.com"
assert "all three commits are still there" test "$(git -C "$nrepo" rev-list --count origin/main..HEAD)" -eq 3
assert "messages survive the rewrite" bash -c "git -C $nrepo log origin/main..HEAD --format='%s' | grep -qx 'already the App'"
( cd "$nrepo" && run "$c6" normalize-commits main 2>"$work/norm2.err" )
assert "a second run is a no-op" grep -q 'already carries the App identity' "$work/norm2.err"

# A merge commit in the range: rev-list must hand parents to the replay before
# their children, or a rewritten child would still point at an un-rewritten parent.
git -C "$nrepo" checkout -q -b side origin/main
commit_as "$nrepo" "claude" "noreply@anthropic.com" side.txt "a side-branch commit"
git -C "$nrepo" checkout -q -
GIT_AUTHOR_NAME=claude GIT_AUTHOR_EMAIL=noreply@anthropic.com \
	GIT_COMMITTER_NAME=claude GIT_COMMITTER_EMAIL=noreply@anthropic.com \
	git -C "$nrepo" merge -q --no-ff side -m "merge the side branch"
( cd "$nrepo" && run "$c6" normalize-commits main 2>"$work/norm3.err" )
assert "a range with a merge commit normalizes every author" test "$(git -C "$nrepo" log origin/main..HEAD --format='%ae' | sort -u)" = "$app_email"
assert "a range with a merge commit normalizes every committer" test "$(git -C "$nrepo" log origin/main..HEAD --format='%ce' | sort -u)" = "$app_email"
assert "the merge commit keeps both parents" test "$(git -C "$nrepo" rev-list --parents -n 1 HEAD | wc -w)" -eq 3
assert "no commit in the range still points at an un-rewritten parent" bash -c "! git -C $nrepo log origin/main..HEAD --format='%P' | tr ' ' '\n' | sort -u | xargs -r -n1 git -C $nrepo show -s --format='%ae' 2>/dev/null | grep -qx 'noreply@anthropic.com'"

commit_as "$nrepo" "A Human" "human@example.com" d.txt "a human's commit"
head_before=$(git -C "$nrepo" rev-parse HEAD)
expect_exit "a foreign author in the range stops normalize-commits (exit 6)" 6 bash -c "cd $nrepo && FACTORY_TOKEN_CACHE_DIR=$c6 GH_TOKEN=factory-token-required FACTORY_BROKER_URL=$good $helper normalize-commits main"
assert "the branch is untouched when it stops" test "$(git -C "$nrepo" rev-parse HEAD)" = "$head_before"
expect_exit "normalize-commits needs a base branch" 2 bash -c "cd $nrepo && FACTORY_TOKEN_CACHE_DIR=$c6 GH_TOKEN=factory-token-required FACTORY_BROKER_URL=$good $helper normalize-commits"

# A range containing a root commit: `git rev-list --parents` prints the hash alone
# for it, and `cut` without -s passes that whole line through, which would make the
# commit its own parent.
rrepo="$work/rootrange"
git init -q -b main "$rrepo"
git -C "$rrepo" remote add origin "https://github.com/$BOUND"
commit_as "$rrepo" "claude" "noreply@anthropic.com" r.txt "root commit, platform identity"
git -C "$rrepo" update-ref refs/remotes/origin/main "$(git -C "$rrepo" rev-parse HEAD)"
git -C "$rrepo" update-ref -d refs/remotes/origin/main
git -C "$rrepo" branch -f base_empty 2>/dev/null || true
# origin/main points at nothing before the root commit, so the root is in range.
git -C "$rrepo" symbolic-ref refs/remotes/origin/main refs/heads/empty_base 2>/dev/null || true
git -C "$rrepo" symbolic-ref -d refs/remotes/origin/main 2>/dev/null || true
commit_as "$rrepo" "claude" "noreply@anthropic.com" r2.txt "child of the root"
git -C "$rrepo" update-ref refs/remotes/origin/main "$(git -C "$rrepo" rev-list --max-parents=0 HEAD)"
rroot=$(git -C "$rrepo" rev-list --max-parents=0 HEAD)
rc=0; ( cd "$rrepo" && run "$c6" normalize-commits main 2>"$work/root.err" ) || rc=$?
assert "normalize-commits succeeds when the range abuts a root commit" test "$rc" -eq 0
assert "the root commit keeps exactly one child and no self-parent" \
	test "$(git -C "$rrepo" rev-list --count HEAD)" -eq 2
assert "the root commit itself is not rewritten into its own parent" \
	test "$(git -C "$rrepo" rev-list --max-parents=0 HEAD)" = "$rroot"

# An unusable App identity in normalize-commits must fail closed the way setup-git
# does, with the same machine-readable reason slug.
badapp=$(start_broker badapp FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_BAD_APP_ID=not-a-number)
cbad="$work/cbad"
expect_exit "normalize-commits refuses a non-numeric bot_user_id (exit 4)" 4 bash -c \
	"cd $nrepo && FACTORY_TOKEN_CACHE_DIR=$cbad GH_TOKEN=factory-token-required FACTORY_BROKER_URL=$badapp $helper normalize-commits main 2>$work/badapp.err"
assert "that refusal carries reason=no_app_identity" grep -q 'reason=no_app_identity' "$work/badapp.err"

# The refresh window may only make the helper mint earlier, never resurrect an
# expired token, and a nonsense value is refused rather than silently inverting it.
cref="$work/cref"
# Populate the cache first: with no cache file the refresh window is never consulted.
run "$cref" --repo "$BOUND" exec -- true >/dev/null 2>&1
for bad_refresh in -3600 abc 1.5 " "; do
	expect_exit "FACTORY_TOKEN_REFRESH_SECONDS=$bad_refresh is refused (exit 2)" 2 bash -c \
		"FACTORY_TOKEN_CACHE_DIR=$cref GH_TOKEN=factory-token-required FACTORY_BROKER_URL=$good FACTORY_TOKEN_REFRESH_SECONDS='$bad_refresh' $helper --repo $BOUND exec -- true"
done

# --- 7. repository resolution + status/clear -------------------------------------
assert "repo resolved from origin remote (ssh form)" bash -c "cd $repo && $helper --broker $good status | grep -q '^repository: $BOUND\$'"
git -C "$repo" remote set-url origin "https://github.com/$BOUND"
assert "repo resolved from origin remote (https form)" bash -c "cd $repo && $helper --broker $good status | grep -q '^repository: $BOUND\$'"
git -C "$repo" remote set-url origin "ssh://git@github.com/$BOUND.git"
assert "repo resolved from origin remote (ssh:// form)" bash -c "cd $repo && $helper --broker $good status | grep -q '^repository: $BOUND\$'"
for bad_origin in "https://evilgithub.com/$BOUND.git" "https://github.com.evil.test/$BOUND.git" "git@gitlab.com:$BOUND.git" "https://github.com/onepathonly"; do
	git -C "$repo" remote set-url origin "$bad_origin"
	expect_exit "origin $bad_origin is not resolved as a factory repo (exit 2)" 2 bash -c "cd $repo && $helper --broker $good status"
done
st=$(run "$c6" --repo "$BOUND" status)
refute "status prints no token" bash -c "printf '%s' \"\$1\" | grep -q ghs_fake" _ "$st"
assert "status reports the pass-through sentinel" bash -c "printf '%s' \"\$1\" | grep -q 'pass-through (sentinel)'" _ "$st"
run "$c6" --repo "$BOUND" clear
refute "clear removes the cache" ls "$c6"/*.json

printf '\n%s\n' "$([ "$failures" -eq 0 ] && echo "all tests passed" || echo "$failures test(s) failed")"
exit "$([ "$failures" -eq 0 ] && echo 0 || echo 1)"
