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
assert "exec sets FACTORY_TOKEN_ACTIVE for the shim to see" test "$(run "$c1" --repo "$BOUND" exec -- sh -c 'printf %s "$FACTORY_TOKEN_ACTIVE"')" = 1
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
refute "shim never prints the token" bash -c "printf '%s%s' \"\$1\" \"\$(cat \"\$2\")\" | grep -q ghs_fake" _ "$shim_out" "$work/shim.err"
: >"$GH_STUB_LOG"
( cd "$work" && PATH="$shimdir:$PATH" FACTORY_TOKEN_CACHE_DIR="$c6" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$good" gh api /rate_limit )
assert "a gh call through the shim carries the App token" grep -q "api /rate_limit|$(token_of "$c6")" "$GH_STUB_LOG"
: >"$GH_STUB_LOG"
( cd "$work" && PATH="$shimdir:$PATH" FACTORY_TOKEN_CACHE_DIR="$c6" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$good" "$helper" --repo "$BOUND" exec -- gh api /user )
assert "the shim does not recurse inside exec (one gh invocation)" test "$(wc -l <"$GH_STUB_LOG")" -eq 1

# --- 5. setup-git ---------------------------------------------------------------
repo="$work/checkout"
git init -q "$repo" && git -C "$repo" remote add origin "git@github.com:$BOUND.git"
: >"$GH_STUB_LOG"
( cd "$repo" && run "$c6" setup-git 2>"$work/setup.err" )
assert "setup-git runs gh auth setup-git with the App token" grep -q "^auth setup-git|$(token_of "$c6")\$" "$GH_STUB_LOG"
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

commit_as "$nrepo" "A Human" "human@example.com" d.txt "a human's commit"
head_before=$(git -C "$nrepo" rev-parse HEAD)
expect_exit "a foreign author in the range stops normalize-commits (exit 6)" 6 bash -c "cd $nrepo && FACTORY_TOKEN_CACHE_DIR=$c6 GH_TOKEN=factory-token-required FACTORY_BROKER_URL=$good $helper normalize-commits main"
assert "the branch is untouched when it stops" test "$(git -C "$nrepo" rev-parse HEAD)" = "$head_before"
expect_exit "normalize-commits needs a base branch" 2 bash -c "cd $nrepo && FACTORY_TOKEN_CACHE_DIR=$c6 GH_TOKEN=factory-token-required FACTORY_BROKER_URL=$good $helper normalize-commits"

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
