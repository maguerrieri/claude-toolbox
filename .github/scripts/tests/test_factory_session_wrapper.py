"""Tests for .github/scripts/factory-session-wrapper (spec 2d option 5, item 14).

The wrapper talks to two things it cannot have in a test: the runner binary
(`claude self-hosted-runner decode-token`) and the factory token broker (over
curl). Both are stubbed with small shell scripts placed first on PATH. The
`claude` stub also stands in for the session child the wrapper execs into: it
records its arguments and the credential-bearing environment it received.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

WRAPPER = Path(__file__).resolve().parents[1] / "factory-session-wrapper"

POOL = "ccpool_01TESTPOOL"
REPO = "sprue-works/widgets"
JWT = "sk-ant-cc-eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJjY3IifQ.sig"

CLAUDE_STUB = r"""#!/usr/bin/env bash
# `decode-token`: print the claims the test supplied, or fail on request.
if [ "$1" = self-hosted-runner ] && [ "$2" = decode-token ]; then
  [ "${FAKE_DECODE_FAIL:-0}" = 1 ] && { echo "verification failed" >&2; exit 1; }
  printf '%s' "$FAKE_CLAIMS"
  exit 0
fi
# Otherwise we are the exec'd session child: record what we were handed.
{
  printf 'args=%s\n' "$*"
  printf 'GH_TOKEN=%s\n' "${GH_TOKEN:-}"
  printf 'GIT_CONFIG_COUNT=%s\n' "${GIT_CONFIG_COUNT:-}"
  env | grep '^GIT_CONFIG_' | sort
  printf 'FACTORY_SESSION_WRAPPER=%s\n' "${FACTORY_SESSION_WRAPPER:-}"
  printf 'STDIN=%s\n' "$(cat)"
} >"$FAKE_EXEC_LOG"
exit 0
"""

CURL_STUB = r"""#!/usr/bin/env bash
# Records the request the wrapper made and answers with the canned response.
out=""; hdr=""; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -H) case "$2" in @*) hdr=$(cat "${2#@}") ;; esac; shift ;;
    --data) data=$2; shift ;;
    -w|--max-time) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
printf '%s\n' "$(jq -cn --arg url "$url" --arg auth "$hdr" --arg data "$data" '{url:$url,auth:$auth,data:$data}')" >>"$FAKE_BROKER_LOG"
[ "${FAKE_CURL_FAIL:-0}" = 1 ] && { echo "curl: (7) Failed to connect" >&2; exit 7; }
printf '%s' "$FAKE_BROKER_BODY" >"$out"
printf '%s' "${FAKE_BROKER_STATUS:-200}"
"""


def _write_exec(path: Path, body: str) -> Path:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def good_claims(**overrides) -> str:
    claims = {
        "iss": "ccr",
        "sub": "ccr:session:session_01TEST",
        "aud": ["anthropic-api", POOL],
        "exp": 4102444800,
        "ccr:role": "session_worker",
        "ccr:session_id": "session_01TEST",
        "ccr:pool_id": POOL,
        "ccr:org_id": "org_01TEST",
        "act": {"sub": "user:user_01TEST", "email": "someone@example.com"},
    }
    claims.update(overrides)
    return json.dumps(claims)


def broker_body(token="ghs_testtoken", repository=REPO, minutes=60) -> str:
    exp = datetime.now(timezone.utc) + timedelta(minutes=minutes)
    return json.dumps(
        {"token": token, "expires_at": exp.strftime("%Y-%m-%dT%H:%M:%SZ"), "repository": repository}
    )


class Harness:
    def __init__(self, tmp_path: Path):
        self.tmp = tmp_path
        self.bin = tmp_path / "bin"
        self.bin.mkdir()
        self.claude = _write_exec(self.bin / "claude", CLAUDE_STUB)
        _write_exec(self.bin / "curl", CURL_STUB)
        self.cache = tmp_path / "cache"
        self.exec_log = tmp_path / "exec.log"
        self.broker_log = tmp_path / "broker.log"
        self.checkout = self._make_checkout()
        self.env = {
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(tmp_path),
            "FACTORY_TOKEN_BROKER_URL": "https://broker.example",
            "FACTORY_POOL_ID": POOL,
            "FACTORY_REPO": REPO,
            "FACTORY_TOKEN_CACHE_DIR": str(self.cache),
            "CLAUDE_RUNNER_CLAUDE_BIN": str(self.claude),
            "CLAUDE_CODE_SESSION_ACCESS_TOKEN": JWT,
            "CLAUDE_CODE_REMOTE_SESSION_UUID": str(uuid.uuid4()),
            "FAKE_CLAIMS": good_claims(),
            "FAKE_BROKER_BODY": broker_body(),
            "FAKE_EXEC_LOG": str(self.exec_log),
            "FAKE_BROKER_LOG": str(self.broker_log),
        }

    def _make_checkout(self) -> Path:
        path = self.tmp / "checkout"
        subprocess.run(["git", "init", "-q", str(path)], check=True)
        subprocess.run(
            ["git", "-C", str(path), "remote", "add", "origin", f"https://github.com/{REPO}.git"],
            check=True,
        )
        return path

    def run(self, *args, stdin: str | None = None, cwd: Path | None = None, **env):
        merged = {**self.env, **{k: v for k, v in env.items() if v is not None}}
        for k, v in env.items():
            if v is None:
                merged.pop(k, None)
        return subprocess.run(
            [str(WRAPPER), *args],
            input=stdin,
            capture_output=True,
            text=True,
            env=merged,
            cwd=str(cwd or self.checkout),
        )

    def exec_record(self) -> dict:
        record = {}
        for line in self.exec_log.read_text().splitlines():
            key, _, value = line.partition("=")
            record[key] = value
        return record

    def broker_calls(self) -> list[dict]:
        if not self.broker_log.exists():
            return []
        return [json.loads(line) for line in self.broker_log.read_text().splitlines()]


@pytest.fixture
def h(tmp_path: Path) -> Harness:
    return Harness(tmp_path)


def assert_refused(result: subprocess.CompletedProcess, h: Harness, *needles: str) -> None:
    assert result.returncode == 1, result
    assert not h.exec_log.exists(), "the session child must not start"
    for needle in needles:
        assert needle in result.stderr, result.stderr
    assert "ghs_" not in result.stdout + result.stderr


# --- command mode -----------------------------------------------------------


def test_command_mints_exports_and_execs(h: Harness):
    result = h.run("command", "--foo", "bar", stdin="control-channel")
    assert result.returncode == 0, result.stderr
    record = h.exec_record()
    assert record["args"] == "--foo bar"
    assert record["GH_TOKEN"] == "ghs_testtoken"
    assert record["STDIN"] == "control-channel", "stdin must reach the child"
    assert record["FACTORY_SESSION_WRAPPER"] == str(WRAPPER)
    # Helper list reset, then ours, then useHttpPath.
    assert record["GIT_CONFIG_COUNT"] == "3"
    assert record["GIT_CONFIG_KEY_0"] == "credential.helper" and record["GIT_CONFIG_VALUE_0"] == ""
    assert record["GIT_CONFIG_VALUE_1"] == f"{WRAPPER} credential"
    assert record["GIT_CONFIG_KEY_2"] == "credential.useHttpPath" and record["GIT_CONFIG_VALUE_2"] == "true"
    # The token never leaks to the wrapper's own output.
    assert "ghs_" not in result.stdout + result.stderr
    # Exactly one exchange, bearing the session JWT, asking for this repo.
    calls = h.broker_calls()
    assert len(calls) == 1
    assert calls[0]["url"] == "https://broker.example/v1/session-token"
    assert calls[0]["auth"] == f"Authorization: Bearer {JWT}"
    assert json.loads(calls[0]["data"]) == {"repository": REPO}
    # Cache is private to the owner.
    (cache_file,) = h.cache.glob("factory-token-*.json")
    assert stat.S_IMODE(cache_file.stat().st_mode) == 0o600


def test_command_sets_bot_email_when_configured(h: Harness):
    result = h.run("command", FACTORY_APP_BOT_EMAIL="123+factory[bot]@users.noreply.github.com")
    assert result.returncode == 0, result.stderr
    record = h.exec_record()
    assert record["GIT_CONFIG_COUNT"] == "4"
    assert record["GIT_CONFIG_KEY_3"] == "user.email"
    assert record["GIT_CONFIG_VALUE_3"] == "123+factory[bot]@users.noreply.github.com"


def test_command_appends_to_existing_git_config_env(h: Harness):
    result = h.run("command", GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="core.x", GIT_CONFIG_VALUE_0="y")
    assert result.returncode == 0, result.stderr
    record = h.exec_record()
    assert record["GIT_CONFIG_COUNT"] == "4"
    assert record["GIT_CONFIG_KEY_0"] == "core.x"
    assert record["GIT_CONFIG_KEY_1"] == "credential.helper" and record["GIT_CONFIG_VALUE_1"] == ""


def test_command_prefers_fresh_jwt_from_ingress_file(h: Harness, tmp_path: Path):
    fresh = tmp_path / "ingress-token"
    fresh.write_text("sk-ant-cc-refreshed.token.sig\n")
    result = h.run("command", CLAUDE_SESSION_INGRESS_TOKEN_FILE=str(fresh))
    assert result.returncode == 0, result.stderr
    assert h.broker_calls()[0]["auth"] == "Authorization: Bearer sk-ant-cc-refreshed.token.sig"


@pytest.mark.parametrize(
    "claims, reason",
    [
        (good_claims(aud=["anthropic-api", "ccpool_OTHER"], **{"ccr:pool_id": "ccpool_OTHER"}), "other environment"),
        (good_claims(aud=["anthropic-api"]), "audience lacks the pool"),
        (good_claims(**{"ccr:role": "runner"}), "not a session_worker"),
        (good_claims(iss="someone-else"), "wrong issuer"),
        (good_claims(act={"sub": "agent:agent_01TEST"}), "agent-created session"),
        (good_claims(act={}), "no creator subject"),
    ],
)
def test_command_refuses_bad_claims(h: Harness, claims: str, reason: str):
    result = h.run("command", FAKE_CLAIMS=claims)
    assert_refused(result, h, "session token is not a session_worker token")
    assert h.broker_calls() == [], f"{reason}: the broker must not be asked"


def test_command_refuses_when_decode_token_fails(h: Harness):
    result = h.run("command", FAKE_DECODE_FAIL="1")
    assert_refused(result, h, "decode-token failed")
    assert h.broker_calls() == []


def test_command_refuses_hosted_session_token(h: Harness):
    result = h.run("command", CLAUDE_CODE_SESSION_ACCESS_TOKEN="sk-ant-si-hosted.token.sig")
    assert_refused(result, h, "sk-ant-cc-")
    assert h.broker_calls() == []


def test_command_refuses_checkout_of_another_repo(h: Harness, tmp_path: Path):
    other = tmp_path / "other"
    subprocess.run(["git", "init", "-q", str(other)], check=True)
    subprocess.run(["git", "-C", str(other), "remote", "add", "origin", "git@github.com:sprue-works/other.git"], check=True)
    result = h.run("command", cwd=other)
    assert_refused(result, h, "this environment serves sprue-works/widgets", "sprue-works/other")
    assert h.broker_calls() == []


def test_command_refuses_without_a_checkout(h: Harness, tmp_path: Path):
    empty = tmp_path / "empty"
    empty.mkdir()
    result = h.run("command", cwd=empty)
    assert_refused(result, h, "no git checkout with an origin remote")


def test_command_honors_checkout_dir_override(h: Harness, tmp_path: Path):
    empty = tmp_path / "empty"
    empty.mkdir()
    result = h.run("command", cwd=empty, FACTORY_CHECKOUT_DIR=str(h.checkout))
    assert result.returncode == 0, result.stderr


def test_command_refuses_token_for_another_repo(h: Harness):
    result = h.run("command", FAKE_BROKER_BODY=broker_body(repository="sprue-works/other"))
    assert_refused(result, h, "not a token for sprue-works/widgets")


def test_command_refuses_broker_error(h: Harness):
    result = h.run("command", FAKE_BROKER_STATUS="403", FAKE_BROKER_BODY='{"error":"pool not bound"}')
    assert_refused(result, h, "HTTP 403", "pool not bound")


def test_command_refuses_broker_unreachable(h: Harness):
    result = h.run("command", FAKE_CURL_FAIL="1")
    assert_refused(result, h, "token broker unreachable")


def test_command_refuses_plain_http_broker(h: Harness):
    result = h.run("command", FACTORY_TOKEN_BROKER_URL="http://broker.example")
    assert_refused(result, h, "must be https")
    assert h.broker_calls() == []


@pytest.mark.parametrize("missing", ["FACTORY_POOL_ID", "FACTORY_REPO", "FACTORY_TOKEN_BROKER_URL", "CLAUDE_RUNNER_CLAUDE_BIN"])
def test_command_requires_configuration(h: Harness, missing: str):
    result = h.run("command", **{missing: None})
    assert_refused(result, h, f"{missing} is not set")


# --- credential helper --------------------------------------------------------


def credential_request(host="github.com", path=f"{REPO}.git", protocol="https") -> str:
    lines = [f"protocol={protocol}", f"host={host}"]
    if path is not None:
        lines.append(f"path={path}")
    return "\n".join(lines) + "\n\n"


def test_credential_get_answers_for_the_bound_repo(h: Harness):
    result = h.run("credential", "get", stdin=credential_request())
    assert result.returncode == 0, result.stderr
    assert result.stdout == "username=x-access-token\npassword=ghs_testtoken\n"
    assert len(h.broker_calls()) == 1


def test_credential_get_accepts_case_and_no_git_suffix(h: Harness):
    result = h.run("credential", "get", stdin=credential_request(path="Sprue-Works/Widgets"))
    assert result.returncode == 0
    assert "password=ghs_testtoken" in result.stdout


@pytest.mark.parametrize(
    "request_text",
    [
        credential_request(path="sprue-works/other.git"),
        credential_request(host="gitlab.com"),
        credential_request(protocol="http"),
    ],
)
def test_credential_get_stays_silent_for_anything_else(h: Harness, request_text: str):
    result = h.run("credential", "get", stdin=request_text)
    assert result.returncode == 0
    assert result.stdout == ""
    assert h.broker_calls() == []


def test_credential_store_and_erase_are_noops(h: Harness):
    for verb in ("store", "erase"):
        result = h.run("credential", verb, stdin=credential_request())
        assert result.returncode == 0 and result.stdout == ""
    assert h.broker_calls() == []


def test_credential_reuses_cached_token_until_near_expiry(h: Harness):
    first = h.run("credential", "get", stdin=credential_request())
    assert first.returncode == 0
    second = h.run("credential", "get", stdin=credential_request(), FAKE_BROKER_BODY=broker_body(token="ghs_second"))
    assert second.returncode == 0
    assert "password=ghs_testtoken" in second.stdout, "still fresh: no re-mint"
    assert len(h.broker_calls()) == 1
    # Now age the cache: a token with four minutes left is re-minted.
    (cache_file,) = h.cache.glob("factory-token-*.json")
    cache_file.write_text(broker_body(token="ghs_stale", minutes=4))
    third = h.run("credential", "get", stdin=credential_request(), FAKE_BROKER_BODY=broker_body(token="ghs_third"))
    assert "password=ghs_third" in third.stdout
    assert len(h.broker_calls()) == 2


def test_token_prints_only_the_token(h: Harness):
    result = h.run("token")
    assert result.returncode == 0, result.stderr
    assert result.stdout == "ghs_testtoken\n"
    assert result.stderr == ""


# --- checkout hook ------------------------------------------------------------


def make_remote(tmp_path: Path) -> tuple[Path, str, str]:
    """A bare repo at <remotes>/sprue-works/widgets.git with main and feature."""
    remotes = tmp_path / "remotes"
    work = tmp_path / "seed"
    subprocess.run(["git", "init", "-q", "-b", "main", str(work)], check=True)
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@x", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@x"}
    (work / "README").write_text("main\n")
    subprocess.run(["git", "-C", str(work), "add", "."], check=True)
    subprocess.run(["git", "-C", str(work), "commit", "-q", "-m", "main"], check=True, env=env)
    main_sha = subprocess.run(["git", "-C", str(work), "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    subprocess.run(["git", "-C", str(work), "checkout", "-q", "-b", "feature"], check=True)
    (work / "README").write_text("feature\n")
    subprocess.run(["git", "-C", str(work), "commit", "-q", "-am", "feature"], check=True, env=env)
    feature_sha = subprocess.run(["git", "-C", str(work), "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    bare = remotes / "sprue-works" / "widgets.git"
    bare.parent.mkdir(parents=True)
    subprocess.run(["git", "clone", "-q", "--bare", str(work), str(bare)], check=True)
    subprocess.run(["git", "-C", str(bare), "symbolic-ref", "HEAD", "refs/heads/main"], check=True)
    return remotes, main_sha, feature_sha


def head_of(path: Path) -> str:
    return subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()


@pytest.mark.parametrize(
    "repo_url",
    [
        f"https://github.com/{REPO}.git",
        f"https://github.com/{REPO}",
        f"git@github.com:{REPO}.git",
        f"ssh://git@github.com/{REPO}.git",
    ],
)
def test_checkout_clones_the_bound_repo_at_the_requested_ref(h: Harness, tmp_path: Path, repo_url: str):
    remotes, _, feature_sha = make_remote(tmp_path)
    target = tmp_path / "ws" / "checkout"
    result = h.run(
        "checkout",
        cwd=tmp_path,
        FACTORY_GITHUB_URL=f"file://{remotes}",
        CLAUDE_RUNNER_REPO_URL=repo_url,
        CLAUDE_RUNNER_REPO_REF="feature",
        CLAUDE_RUNNER_CHECKOUT_PATH=str(target),
        CLAUDE_RUNNER_SESSION_UUID=str(uuid.uuid4()),
        CLAUDE_CODE_REMOTE_SESSION_UUID=None,
        CLAUDE_RUNNER_CLAUDE_BIN=None,
    )
    assert result.returncode == 0, result.stderr
    assert (target / ".git").is_dir()
    assert head_of(target) == feature_sha
    assert (target / "README").read_text() == "feature\n"
    origin = subprocess.run(["git", "-C", str(target), "remote", "get-url", "origin"], check=True, capture_output=True, text=True).stdout.strip()
    assert origin == f"file://{remotes}/{REPO}.git", "clone URL comes from FACTORY_REPO, not the request"


def test_checkout_defaults_to_the_default_branch(h: Harness, tmp_path: Path):
    remotes, main_sha, _ = make_remote(tmp_path)
    target = tmp_path / "ws" / "checkout"
    result = h.run(
        "checkout",
        cwd=tmp_path,
        FACTORY_GITHUB_URL=f"file://{remotes}",
        CLAUDE_RUNNER_REPO_URL=f"https://github.com/{REPO}.git",
        CLAUDE_RUNNER_REPO_REF="",
        CLAUDE_RUNNER_CHECKOUT_PATH=str(target),
        CLAUDE_RUNNER_FETCH_DEPTH="full",
    )
    assert result.returncode == 0, result.stderr
    assert head_of(target) == main_sha


def test_checkout_refuses_another_repo(h: Harness, tmp_path: Path):
    remotes, _, _ = make_remote(tmp_path)
    target = tmp_path / "ws" / "checkout"
    result = h.run(
        "checkout",
        cwd=tmp_path,
        FACTORY_GITHUB_URL=f"file://{remotes}",
        CLAUDE_RUNNER_REPO_URL="https://github.com/sprue-works/other.git",
        CLAUDE_RUNNER_CHECKOUT_PATH=str(target),
    )
    assert result.returncode == 1
    assert "this environment serves sprue-works/widgets" in result.stderr
    assert "sprue-works/other" in result.stderr
    assert not target.exists()


def test_checkout_refuses_unparseable_url(h: Harness, tmp_path: Path):
    result = h.run(
        "checkout",
        cwd=tmp_path,
        CLAUDE_RUNNER_REPO_URL="https://github.com/",
        CLAUDE_RUNNER_CHECKOUT_PATH=str(tmp_path / "x"),
    )
    assert result.returncode == 1
    assert "cannot parse repository" in result.stderr


def test_usage_without_a_subcommand(h: Harness):
    result = h.run()
    assert result.returncode == 1
    assert "usage" in result.stderr


def test_wrapper_is_executable_and_uses_bash():
    assert os.access(WRAPPER, os.X_OK)
    assert WRAPPER.read_text().startswith("#!/usr/bin/env bash\n")
    assert shutil.which("bash")
