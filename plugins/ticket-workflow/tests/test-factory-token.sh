#!/usr/bin/env bash
# factory-token helper tests (software-factory design, section 2d / item 8b).
#
# Runs the helper against tests/fixtures/fake-broker.py (loopback, no network) and
# pins the behaviour the spec relies on:
#
#   1. `env` prints exactly one `export GH_TOKEN=…` line and nothing else on stdout;
#      the token never appears on stderr.
#   2. The token is cached for its lifetime (one broker call across repeated
#      invocations), re-minted inside the refresh window, and `--force` re-mints.
#   3. Fail closed: proxy-injected mode (exit 3, no broker call); a broker that
#      answers with a repository other than the one asked for (exit 4, nothing
#      cached, nothing exported); a broker that mints for whatever is asked is the
#      isolation test's to catch, not the helper's;
#      a 403 from the broker (exit 4); a 5xx (exit 5); a malformed body (exit 4);
#      a non-loopback http:// broker URL (exit 2).
#   4. `exec -- cmd` sees GH_TOKEN; `git-credential get` answers only for exactly
#      https://github.com (no subdomains); `setup-git` wires the credential helper,
#      rewrites an SSH origin's push URL to HTTPS, sets the App's noreply author,
#      and refuses without App metadata; a broker response with any permission set
#      other than contents+pull_requests write (+ metadata read) is refused;
#      `clear` drops the cache; `status` prints no token.
#   5. The repository is resolved from the origin remote when --repo is absent.
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
pids=()
cleanup() { for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT

# start_broker <name> [ENV=VALUE...] → prints the base URL
start_broker() {
	local name=$1; shift
	local out="$work/$name.port"
	env "$@" python3 "$fake" >"$out" 2>"$work/$name.err" &
	pids+=($!)
	local i=0
	until grep -q '^PORT ' "$out" 2>/dev/null; do
		i=$((i + 1)); [ "$i" -lt 100 ] || { echo "fake broker $name did not start: $(cat "$work/$name.err")" >&2; exit 2; }
		sleep 0.05
	done
	printf 'http://127.0.0.1:%s' "$(awk '{print $2}' "$out")"
}

BOUND="Acme/Repo-A"
counts="$work/counts"
: >"$counts"
good=$(start_broker good FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_COUNT_FILE="$counts")
leaky=$(start_broker leaky FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_LEAK=1)
lenient=$(start_broker lenient FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_LENIENT=1)
broken=$(start_broker broken FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_STATUS=500)
noexpin=$(start_broker noexpin FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_OMIT_EXPIRES_IN=1)

# Every invocation gets its own cache dir unless a test wants sharing; GH_TOKEN
# carries the pass-through sentinel the implementer environment sets.
run() { # run <cache-dir> <args...>
	local cache=$1; shift
	FACTORY_TOKEN_CACHE_DIR="$cache" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$good" "$helper" "$@"
}

# --- 1. env output shape -------------------------------------------------------
c1="$work/c1"
out=$(run "$c1" --repo "$BOUND" env 2>"$work/c1.err")
assert "env prints one export line" test "$(printf '%s\n' "$out" | wc -l)" -eq 1
assert "env line is export GH_TOKEN=<token>" bash -c "printf '%s' \"\$1\" | grep -Eq '^export GH_TOKEN=ghs_fake_Acme_Repo-A_[0-9]+$'" _ "$out"
refute "token never on stderr" grep -q ghs_fake "$work/c1.err"
assert "cache file is mode 0600" bash -c "[ \"\$(stat -c %a \"\$1\"/*.json)\" = 600 ]" _ "$c1"
assert "eval of env output exports GH_TOKEN" bash -c "eval \"\$1\"; [ -n \"\$GH_TOKEN\" ] && [ \"\$GH_TOKEN\" != factory-token-required ]" _ "$out"

# --- 2. caching ----------------------------------------------------------------
before=$(wc -l <"$counts")
run "$c1" --repo "$BOUND" env >/dev/null
run "$c1" --repo "$BOUND" env >/dev/null
assert "repeat calls hit the cache (no new broker calls)" test "$(wc -l <"$counts")" -eq "$before"
run "$c1" --force --repo "$BOUND" env >/dev/null
assert "--force re-mints" test "$(wc -l <"$counts")" -eq $((before + 1))
before=$(wc -l <"$counts")
FACTORY_TOKEN_REFRESH_SECONDS=999999 run "$c1" --repo "$BOUND" env >/dev/null
assert "inside the refresh window re-mints" test "$(wc -l <"$counts")" -eq $((before + 1))
# A cache entry for another repo is not reused: expiry math is per repo file.
cache_repo=$(jq -r .repository "$c1"/*.json)
assert "cache records the requested repository" test "$cache_repo" = "$BOUND"
# Expiry is capped at one hour whatever the broker says (spec 2d item 4).
c2="$work/c2"
longlived=$(start_broker longlived FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_EXPIRES_IN=86400)
FACTORY_BROKER_URL="$longlived" FACTORY_TOKEN_CACHE_DIR="$c2" GH_TOKEN=factory-token-required "$helper" --repo "$BOUND" env >/dev/null
exp=$(jq -r .expires_epoch "$c2"/*.json)
assert "cached expiry is capped at one hour" test "$exp" -le $(($(date -u +%s) + 3600))
# expires_at-only responses still parse (GNU date) — skipped where date -d is absent.
if date -u -d 2026-01-01T00:00:00Z +%s >/dev/null 2>&1; then
	c3="$work/c3"
	assert "expires_at without expires_in is accepted" env FACTORY_BROKER_URL="$noexpin" FACTORY_TOKEN_CACHE_DIR="$c3" GH_TOKEN=factory-token-required "$helper" --repo "$BOUND" env
fi

# --- 3. fail closed ------------------------------------------------------------
c4="$work/c4"
before=$(wc -l <"$counts")
expect_exit "proxy-injected mode refuses (exit 3)" 3 env FACTORY_TOKEN_CACHE_DIR="$c4" GH_TOKEN=proxy-injected FACTORY_BROKER_URL="$good" "$helper" --repo "$BOUND" env
assert "proxy-injected mode makes no broker call" test "$(wc -l <"$counts")" -eq "$before"
refute "proxy-injected mode caches nothing" ls "$c4"
assert "GITHUB_TOKEN=proxy-injected alone does not refuse (platform var; GH_TOKEN decides)" env FACTORY_TOKEN_CACHE_DIR="$c4" GH_TOKEN=factory-token-required GITHUB_TOKEN=proxy-injected FACTORY_BROKER_URL="$good" "$helper" --repo "$BOUND" env

c5="$work/c5"
# A broker that ignores the repository parameter and answers with its bound repo:
# the helper asked for B, got A, and must refuse without caching or exporting.
expect_exit "token for another repo than asked is refused (exit 4)" 4 env FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$lenient" "$helper" --repo "Acme/Repo-B" env
refute "mismatched token: nothing cached" ls "$c5"
out=$(FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$lenient" "$helper" --repo "Acme/Repo-B" env 2>/dev/null || true)
refute "mismatched token: nothing exported" test -n "$out"
# The well-behaved broker refuses a foreign repo at the source (403 → exit 4).
expect_exit "well-behaved broker: foreign repo gets 403 → exit 4" 4 run "$c5" --repo "Acme/Repo-B" env
refute "well-behaved broker: foreign repo caches nothing" ls "$c5"
# A leaky broker that mints for whatever is asked is *not* the helper's to catch —
# the helper only knows what it asked for — which is why the isolation test
# (test-factory-isolation.sh) exists. Pin that division of labour:
c5b="$work/c5b"
assert "leaky broker is invisible to the helper (isolation test's job)" env FACTORY_TOKEN_CACHE_DIR="$c5b" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$leaky" "$helper" --repo "Acme/Repo-B" env
expect_exit "broker 500 → exit 5" 5 env FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$broken" "$helper" --repo "$BOUND" env
expect_exit "unreachable broker → exit 5" 5 env FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="http://127.0.0.1:1" "$helper" --repo "$BOUND" env
expect_exit "non-loopback http:// broker refused (exit 2)" 2 env FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="http://broker.example" "$helper" --repo "$BOUND" env
expect_exit "missing broker URL → exit 2" 2 env FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL= "$helper" --repo "$BOUND" env
expect_exit "malformed repository → exit 2" 2 run "$c5" --repo "not-a-repo" env
# Malformed body: a broker that returns HTML.
python3 - "$work/malformed.port" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(b"<html>")
srv = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(f"PORT {srv.server_address[1]}\n")
srv.serve_forever()
PY
pids+=($!)
until [ -s "$work/malformed.port" ]; do sleep 0.05; done
malformed="http://127.0.0.1:$(awk '{print $2}' "$work/malformed.port")"
expect_exit "malformed broker body → exit 4" 4 env FACTORY_TOKEN_CACHE_DIR="$c5" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$malformed" "$helper" --repo "$BOUND" env

# --- 4. exec, git-credential, setup-git, status, clear --------------------------
c6="$work/c6"
assert "exec -- sees GH_TOKEN" bash -c "[ \"\$(FACTORY_TOKEN_CACHE_DIR=$c6 GH_TOKEN=factory-token-required FACTORY_BROKER_URL=$good $helper --repo $BOUND exec -- sh -c 'printf %s \"\$GH_TOKEN\"')\" = \"\$(jq -r .token $c6/*.json)\" ]"
cred=$(printf 'protocol=https\nhost=github.com\n\n' | run "$c6" --repo "$BOUND" git-credential get)
assert "git-credential get answers with x-access-token" bash -c "printf '%s' \"\$1\" | grep -q '^username=x-access-token$'" _ "$cred"
assert "git-credential get carries the cached token" bash -c "printf '%s' \"\$1\" | grep -q \"^password=\$(jq -r .token $c6/*.json)\$\"" _ "$cred"
other=$(printf 'protocol=https\nhost=gitlab.com\n\n' | run "$c6" --repo "$BOUND" git-credential get)
refute "git-credential get is silent for other hosts" test -n "$other"
sub=$(printf 'protocol=https\nhost=evil.github.com\n\n' | run "$c6" --repo "$BOUND" git-credential get)
refute "git-credential get is silent for github.com subdomains" test -n "$sub"
plain=$(printf 'protocol=http\nhost=github.com\n\n' | run "$c6" --repo "$BOUND" git-credential get)
refute "git-credential get is silent for plain http" test -n "$plain"
noop=$(printf 'protocol=https\nhost=github.com\n\n' | run "$c6" --repo "$BOUND" git-credential store)
refute "git-credential store is a no-op" test -n "$noop"

repo="$work/checkout"
git init -q "$repo" && git -C "$repo" remote add origin "git@github.com:$BOUND.git"
( cd "$repo" && run "$c6" setup-git 2>"$work/setup.err" )
assert "setup-git sets the credential helper to this script" bash -c "git -C $repo config --local --get-all credential.helper | tail -1 | grep -q \"^!'.*/factory-token' git-credential\$\""
assert "setup-git resets the helper list first (empty entry precedes it)" test "$(git -C "$repo" config --local --get-all credential.helper | head -1)" = ""
# The wired helper actually answers git: a credential fill through git itself.
assert "git credential fill uses the helper" bash -c "cd $repo && printf 'protocol=https\nhost=github.com\n\n' | FACTORY_TOKEN_CACHE_DIR=$c6 GH_TOKEN=factory-token-required FACTORY_BROKER_URL=$good GIT_TERMINAL_PROMPT=0 git credential fill | grep -q '^password=ghs_fake'"
( cd "$repo" && run "$c6" setup-git 2>/dev/null )
assert "setup-git is idempotent (one empty entry, one helper)" test "$(git -C "$repo" config --local --get-all credential.helper | wc -l)" -eq 2
assert "setup-git sets the App noreply author email" test "$(git -C "$repo" config --local user.email)" = "424242+factory-fake[bot]@users.noreply.github.com"
assert "setup-git sets the bot user.name" test "$(git -C "$repo" config --local user.name)" = "factory-fake[bot]"
# Raw config keys, not `git remote get-url`: an environment-level insteadOf rewrite
# (the cloud git proxy has one) would mask what setup-git actually wrote.
assert "setup-git sets an HTTPS push URL for the SSH origin" test "$(git -C "$repo" config --local remote.origin.pushurl)" = "https://github.com/$BOUND.git"
assert "setup-git leaves the fetch URL alone" test "$(git -C "$repo" config --local remote.origin.url)" = "git@github.com:$BOUND.git"
assert "git resolves the push transport to HTTPS" bash -c "cd $repo && git remote -v | grep -q '^origin.https://github.com/$BOUND.git (push)\$'"
refute "setup-git logs no token" grep -q ghs_fake "$work/setup.err"
# Broker responses without App metadata or with the wrong permissions are refused.
noapp=$(start_broker noapp FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_NO_APP=1)
repo2="$work/checkout2"; c7="$work/c7"
git init -q "$repo2" && git -C "$repo2" remote add origin "https://github.com/$BOUND"
expect_exit "setup-git refuses when the broker names no app slug/bot id (exit 4)" 4 bash -c "cd $repo2 && FACTORY_TOKEN_CACHE_DIR=$c7 GH_TOKEN=factory-token-required FACTORY_BROKER_URL=$noapp $helper setup-git"
refute "setup-git without app metadata leaves user.email unset" git -C "$repo2" config --local user.email
for perms in '{"contents":"write"}' '{"contents":"read","pull_requests":"write"}' '{"contents":"write","pull_requests":"write","administration":"write"}' '{"contents":"write","pull_requests":"write","metadata":"write"}'; do
	b=$(start_broker "perms$RANDOM" FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_PERMS="$perms")
	c8="$work/c8-$RANDOM"
	expect_exit "permissions $perms are refused (exit 4)" 4 env FACTORY_TOKEN_CACHE_DIR="$c8" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$b" "$helper" --repo "$BOUND" env
	refute "permissions $perms: nothing cached" ls "$c8"
done
b=$(start_broker permsok FAKE_BROKER_BOUND="$BOUND" FAKE_BROKER_PERMS='{"contents":"write","pull_requests":"write","metadata":"read"}')
assert "permissions with metadata: read are accepted" env FACTORY_TOKEN_CACHE_DIR="$work/c9" GH_TOKEN=factory-token-required FACTORY_BROKER_URL="$b" "$helper" --repo "$BOUND" env
# 5. repository resolved from origin (no --repo)
assert "repo resolved from origin remote (ssh form)" bash -c "cd $repo && $helper --broker $good status | grep -q '^repository: $BOUND\$'" 
git -C "$repo" remote set-url origin "https://github.com/$BOUND"
assert "repo resolved from origin remote (https form)" bash -c "cd $repo && $helper --broker $good status | grep -q '^repository: $BOUND\$'"
st=$(run "$c6" --repo "$BOUND" status)
refute "status prints no token" bash -c "printf '%s' \"\$1\" | grep -q ghs_fake" _ "$st"
assert "status reports the pass-through sentinel" bash -c "printf '%s' \"\$1\" | grep -q 'pass-through (sentinel)'" _ "$st"
run "$c6" --repo "$BOUND" clear
refute "clear removes the cache" ls "$c6"/*.json

printf '\n%s\n' "$([ "$failures" -eq 0 ] && echo "all tests passed" || echo "$failures test(s) failed")"
exit "$([ "$failures" -eq 0 ] && echo 0 || echo 1)"
