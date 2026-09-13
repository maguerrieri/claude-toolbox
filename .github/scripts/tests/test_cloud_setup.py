"""Tests for .claude/cloud-setup.sh (spec section 2b, item 6).

Each test builds a throwaway origin whose `main` carries the repo's real
cloud-setup.sh (with GCP constants filled in so the key path is exercised), a
feature branch checked out from it, and recording stubs for `claude`,
`gcloud`, `curl`, and `op` on PATH. The script is run exactly as the GUI
stub and the SessionStart hook run it: origin/main's copy, through
`bash -euo pipefail -c "$script"`.
"""
import json
import os
import re
import stat
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SCRIPT = os.path.join(REPO, ".claude", "cloud-setup.sh")
ALLOWLIST = os.path.join(REPO, ".claude", "cloud-allowlist")

STUBS = {
    # `marketplace list` prints the real CLI's shape: a `> name` line followed
    # by an indented `Source:` line; `add <url>#<ref>` records `Git (url@ref)`.
    "claude": r"""#!/bin/bash
echo "claude $*" >> "$STUB_LOG"
case "$*" in
  "plugin marketplace list") cat "$STUB_STATE/markets" 2>/dev/null ;;
  "plugin list") cat "$STUB_STATE/plugins" 2>/dev/null ;;
  "plugin marketplace add "*)
    url="${4%%#*}"; ref="${4##*#}"; name=$(basename "${url%.git}"); [ "$name" = claude-toolbox ] && name=maguerrieri-toolbox
    printf '  > %s\n    Source: Git (%s@%s)\n' "$name" "$url" "$ref" >> "$STUB_STATE/markets" ;;
  "plugin marketplace remove "*)
    awk -v name="$4" '$1 == ">" { skip = ($2 == name) } !skip' "$STUB_STATE/markets" > "$STUB_STATE/markets.new" && mv "$STUB_STATE/markets.new" "$STUB_STATE/markets" ;;
  "plugin install "*) echo "  > $3" >> "$STUB_STATE/plugins" ;;
esac
""",
    "gcloud": r"""#!/bin/bash
echo "gcloud $*" >> "$STUB_LOG"
case "$1 $2" in
  "auth activate-service-account") cp "${4#--key-file=}" "$STUB_STATE/materialized-key" ;;
  "auth print-access-token") echo token ;;
esac
""",
    # The three IAM endpoints the assertion uses. The testable set is the
    # role's permissions, three foreign ones, one disabled-API permission, and
    # 250 synthetic ones on a second page, so batching and pagination are
    # exercised; the credential "holds" the role's set, plus two foreign ones
    # under STUB_IAM_EXCESS. STUB_IAM_FAIL makes every call fail.
    "curl": r"""#!/bin/bash
url="${@: -1}"; body=""
while [ $# -gt 0 ]; do case "$1" in -d) body="$2"; shift ;; esac; shift; done
echo "curl $url" >> "$STUB_LOG"
[ -n "$body" ] && printf '%s\n' "$body" >> "$STUB_STATE/iam-requests"
[ -n "${STUB_IAM_FAIL:-}" ] && exit 22
role='["logging.logEntries.list","logging.logs.list","logging.views.get"]'
case "$url" in
  *roles/logging.viewer) jq -cn --argjson r "$role" '{name: "roles/logging.viewer", includedPermissions: $r}' ;;
  *queryTestablePermissions)
    if [ -z "$(jq -r '.pageToken // ""' <<<"$body")" ]; then
      jq -cn --argjson r "$role" '{permissions: ((($r + ["run.services.list","secretmanager.versions.access","logging.exclusions.create"]) | map({name: .})) + [{name: "disabled.api.perm", apiDisabled: true}]), nextPageToken: "p2"}'
    else
      jq -cn '{permissions: [range(1; 251) | {name: ("synthetic.perm." + tostring)}]}'
    fi ;;
  *testIamPermissions)
    held='["logging.logEntries.list","logging.logs.list","logging.views.get"]'
    [ -n "${STUB_IAM_EXCESS:-}" ] && held='["logging.logEntries.list","logging.logs.list","logging.views.get","run.services.list","logging.exclusions.create"]'
    jq -c --argjson h "$held" '{permissions: [.permissions[] | select(. as $p | $h | index($p))]}' <<<"$body" ;;
esac
""",
    "op": r"""#!/bin/bash
echo "op $*" >> "$STUB_LOG"
echo '{"from":"op"}' > "${7}"
""",
}


def git(cwd, *args):
    return subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True, text=True).stdout


@pytest.fixture
def env(tmp_path):
    """A stub PATH, a HOME, an origin with main + a feature checkout; returns a runner."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in STUBS.items():
        f = bin_dir / name
        f.write_text(body)
        f.chmod(f.stat().st_mode | stat.S_IEXEC)
    home = tmp_path / "home"
    home.mkdir()
    state = tmp_path / "stub-state"
    state.mkdir()
    log = tmp_path / "stub.log"
    log.touch()

    origin = tmp_path / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
    seed = tmp_path / "seed"
    subprocess.run(["git", "clone", "-q", str(origin), str(seed)], check=True, capture_output=True)
    git(str(seed), "config", "user.email", "t@example.com")
    git(str(seed), "config", "user.name", "t")
    claude_dir = seed / ".claude"
    (claude_dir / "hooks").mkdir(parents=True)
    with open(SCRIPT) as f:
        text = f.read()
    # Whatever the repo's copy declares, the fixture exercises the key path.
    text = re.sub(r'^GCP_PROJECT=.*$', 'GCP_PROJECT="proj"', text, count=1, flags=re.M)
    text = re.sub(r'^LOGS_VIEWER_SA=.*$', 'LOGS_VIEWER_SA="logs-viewer@proj.iam.gserviceaccount.com"', text, count=1, flags=re.M)
    (claude_dir / "cloud-setup.sh").write_text(text)
    with open(ALLOWLIST) as f:
        (claude_dir / "cloud-allowlist").write_text(f.read())
    (claude_dir / "settings.json").write_text(
        '{"enabledPlugins": {"defaults@maguerrieri-toolbox": true, "superpowers@claude-plugins-official": true, "evil@unknown-market": true}}\n')
    (claude_dir / "hooks" / "session-start.sh").write_text("#!/bin/bash\necho hook\n")
    # A branch that plants build files must not get them executed.
    (seed / "Makefile").write_text("all:\n\ttouch MAKE_RAN\n")
    (seed / "package.json").write_text('{"scripts": {"postinstall": "touch POSTINSTALL_RAN"}}\n')
    git(str(seed), "add", "-A")
    git(str(seed), "commit", "-qm", "init")
    git(str(seed), "push", "-q", "origin", "HEAD:main")
    git(str(seed), "push", "-q", "origin", "HEAD:feature")
    checkout = tmp_path / "checkout"
    subprocess.run(["git", "clone", "-q", "--branch", "feature", str(origin), str(checkout)], check=True, capture_output=True)

    class Env:
        def __init__(self):
            self.seed, self.checkout, self.home, self.log, self.state = seed, checkout, home, log, state
            self.vars = {
                **os.environ,
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "HOME": str(home),
                "STUB_LOG": str(log),
                "STUB_STATE": str(state),
                "CLAUDE_PROJECT_DIR": str(checkout),
                "FACTORY_LOGS_VIEWER_KEY": '{"type": "service_account", "client_email": "logs-viewer@proj"}',
            }
            for k in ("OP_SERVICE_ACCOUNT_TOKEN", "STUB_IAM_EXCESS", "CLOUDSDK_AUTH_ACCESS_TOKEN"):
                self.vars.pop(k, None)

        def main_script(self):
            return git(str(self.checkout), "show", "origin/main:.claude/cloud-setup.sh")

        def run(self, *args, **extra):
            """Run origin/main's copy the way the stub / hook does."""
            cmd = ["bash", "-euo", "pipefail", "-c", self.main_script(), "cloud-setup", *args]
            return subprocess.run(cmd, cwd=str(self.checkout), env={**self.vars, **extra}, capture_output=True, text=True)

        def commit_main(self, rel, text):
            path = self.seed / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            git(str(self.seed), "add", "-A")
            git(str(self.seed), "commit", "-qm", f"change {rel}")
            git(str(self.seed), "push", "-q", "origin", "HEAD:main")

        def manifest(self):
            return (self.home / ".factory-setup" / "manifest").read_text()

        def calls(self):
            return self.log.read_text()

    return Env()


def test_provisions_plugins_pinned_and_from_allowlist_only(env):
    r = env.run()
    assert r.returncode == 0, r.stdout + r.stderr
    calls = env.calls()
    assert "claude plugin marketplace add https://github.com/maguerrieri/claude-toolbox.git#main" in calls
    assert "claude plugin marketplace add https://github.com/anthropics/claude-plugins-official.git#main" in calls
    assert "claude plugin install defaults@maguerrieri-toolbox" in calls
    assert "claude plugin install superpowers@claude-plugins-official" in calls
    assert "evil@unknown-market" not in calls
    assert "skipping evil@unknown-market: marketplace unknown-market is not on this script's allowlist" in r.stdout
    assert "MAKE_RAN" not in os.listdir(env.checkout) and "POSTINSTALL_RAN" not in os.listdir(env.checkout)


def test_provisioning_is_idempotent(env):
    assert env.run().returncode == 0
    env.log.write_text("")
    assert env.run().returncode == 0
    calls = env.calls()
    assert "marketplace add" not in calls and "marketplace remove" not in calls and "plugin install" not in calls
    assert "claude plugin marketplace update maguerrieri-toolbox" in calls


def test_marketplace_registered_from_another_source_is_replaced(env):
    """A same-named marketplace that is not the pinned git URL and ref is removed and re-added."""
    (env.state / "markets").write_text("  > maguerrieri-toolbox\n    Source: GitHub (maguerrieri/claude-toolbox)\n"
                                       "  > claude-plugins-official\n    Source: Git (https://github.com/anthropics/claude-plugins-official.git@v1)\n")
    r = env.run()
    assert r.returncode == 0, r.stdout + r.stderr
    calls = env.calls()
    assert "claude plugin marketplace remove maguerrieri-toolbox" in calls
    assert "claude plugin marketplace remove claude-plugins-official" in calls
    assert "claude plugin marketplace add https://github.com/maguerrieri/claude-toolbox.git#main" in calls
    assert "claude plugin marketplace add https://github.com/anthropics/claude-plugins-official.git#main" in calls
    assert "marketplace update" not in calls
    assert "registered from 'GitHub (maguerrieri/claude-toolbox)', not the pinned source; replacing it" in r.stdout
    assert (env.state / "markets").read_text().count("Source: Git (https://github.com/maguerrieri/claude-toolbox.git@main)") == 1


def test_materializes_logs_key_and_asserts_iam(env):
    r = env.run()
    assert r.returncode == 0, r.stdout + r.stderr
    calls = env.calls()
    assert "gcloud auth activate-service-account logs-viewer@proj.iam.gserviceaccount.com --key-file=" in calls
    assert "gcloud config set project proj --quiet" in calls
    assert "curl https://iam.googleapis.com/v1/roles/logging.viewer" in calls
    assert "curl https://iam.googleapis.com/v1/permissions:queryTestablePermissions" in calls
    assert "curl https://cloudresourcemanager.googleapis.com/v1/projects/proj:testIamPermissions" in calls
    assert (env.state / "materialized-key").read_text().startswith('{"type": "service_account"')
    assert "IAM OK: of 256 testable permissions on proj the credential holds 3, all within roles/logging.viewer" in r.stdout
    # The key file never survives the run.
    assert not [p for p in env.checkout.rglob("logs-viewer-key.json")]


def test_key_from_base64_variable(env):
    import base64
    key = base64.b64encode(b'{"type": "service_account", "b64": true}').decode()
    r = env.run(FACTORY_LOGS_VIEWER_KEY=key)
    assert r.returncode == 0, r.stdout + r.stderr
    assert '"b64": true' in (env.state / "materialized-key").read_text()


def test_key_falls_back_to_op_with_a_warning(env):
    env.vars.pop("FACTORY_LOGS_VIEWER_KEY")
    r = env.run(OP_SERVICE_ACCOUNT_TOKEN="x")
    assert r.returncode == 0, r.stdout + r.stderr
    assert 'op document get gcp-logs-viewer-key --vault Claude (personal)' in env.calls()
    assert "transitional" in r.stdout
    assert (env.state / "materialized-key").read_text() == '{"from":"op"}\n'


def test_declared_key_without_source_fails_provisioning(env):
    """A repo that declares a project must get its key: no snapshot without it."""
    env.vars.pop("FACTORY_LOGS_VIEWER_KEY")
    r = env.run()
    assert r.returncode == 1
    assert "gcloud" not in env.calls()
    assert "no logs key available" in r.stdout and "no snapshot manifest written" in r.stderr
    assert not (env.home / ".factory-setup" / "manifest").exists()
    # Plugins were still provisioned before the key step.
    assert "claude plugin install defaults@maguerrieri-toolbox" in env.calls()


def test_iam_enumerates_every_testable_permission_in_batches(env):
    assert env.run().returncode == 0
    requests = (env.state / "iam-requests").read_text().splitlines()
    tests = [json.loads(b) for b in requests if "fullResourceName" not in b]
    queries = [json.loads(b) for b in requests if "fullResourceName" in b]
    assert [q.get("pageToken") for q in queries] == [None, "p2"]  # both pages fetched
    assert queries[0]["fullResourceName"] == "//cloudresourcemanager.googleapis.com/projects/proj"
    assert len(tests) == 3 and all(len(t["permissions"]) <= 100 for t in tests)  # 256 names, 100 per call
    requested = {p for t in tests for p in t["permissions"]}
    assert "synthetic.perm.250" in requested and "logging.exclusions.create" in requested
    assert "disabled.api.perm" not in requested


def test_excess_iam_revokes_key_and_fails_provisioning(env):
    r = env.run(STUB_IAM_EXCESS="1")
    assert r.returncode == 1
    assert "IAM: EXCESS: the credential holds permissions outside roles/logging.viewer: logging.exclusions.create,run.services.list" in r.stdout
    assert "gcloud auth revoke logs-viewer@proj.iam.gserviceaccount.com --quiet" in env.calls()
    assert not (env.home / ".factory-setup" / "manifest").exists()


def test_unprovable_iam_scope_fails_closed(env):
    """A check that cannot run (API down, unknown names) is not a pass."""
    r = env.run(STUB_IAM_FAIL="1")
    assert r.returncode == 1
    assert "cannot assert" in r.stdout and "scope not proven" in r.stdout
    assert "gcloud auth revoke logs-viewer@proj.iam.gserviceaccount.com --quiet" in env.calls()
    assert not (env.home / ".factory-setup" / "manifest").exists()


def test_assert_iam_mode(env):
    ok = env.run("--assert-iam")
    assert ok.returncode == 0 and "IAM OK" in ok.stdout, ok.stdout + ok.stderr
    bad = env.run("--assert-iam", STUB_IAM_EXCESS="1")
    assert bad.returncode == 1 and "EXCESS" in bad.stdout
    down = env.run("--assert-iam", STUB_IAM_FAIL="1")
    assert down.returncode == 2 and "cannot assert" in down.stdout


def test_assert_iam_is_a_noop_without_a_project(env):
    """The repo's own copy, when it declares no GCP project, has nothing to assert."""
    with open(SCRIPT) as f:
        text = f.read()
    if 'GCP_PROJECT=""' not in text:
        pytest.skip("this repo's copy declares a project")
    r = subprocess.run(["bash", "-euo", "pipefail", "-c", text, "cloud-setup", "--assert-iam"],
                       cwd=str(env.checkout), env=env.vars, capture_output=True, text=True)
    assert r.returncode == 0 and "nothing to assert" in r.stdout, r.stdout + r.stderr


def test_untrusted_claude_dir_withholds_key(env):
    (env.checkout / ".claude" / "hooks" / "session-start.sh").write_text("#!/bin/bash\nenv\n")
    (env.checkout / ".claude" / "extra.sh").write_text("echo new\n")
    r = env.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "UNTRUSTED .claude/" in r.stdout
    assert ".claude/extra.sh" in r.stdout and ".claude/hooks/session-start.sh" in r.stdout
    assert "gcloud auth activate" not in env.calls()
    # Plugins still provision; the manifest is still written.
    assert "claude plugin install defaults@maguerrieri-toolbox" in env.calls()
    assert "script " in env.manifest()


def test_worktrees_under_claude_are_not_drift(env):
    wt = env.checkout / ".claude" / "worktrees" / "issue-1"
    wt.mkdir(parents=True)
    (wt / "file").write_text("x")
    r = env.run("--verify")
    assert "UNTRUSTED" not in r.stdout


def test_manifest_records_origin_main_hashes(env):
    assert env.run().returncode == 0
    m = env.manifest()
    import hashlib
    script_sha = hashlib.sha256(env.main_script().encode()).hexdigest()
    allow_sha = hashlib.sha256(git(str(env.checkout), "show", "origin/main:.claude/cloud-allowlist").encode()).hexdigest()
    settings_sha = hashlib.sha256(git(str(env.checkout), "show", "origin/main:.claude/settings.json").encode()).hexdigest()
    assert f"script {script_sha}" in m and f"allowlist {allow_sha}" in m and f"settings {settings_sha}" in m
    assert re.search(r"origin_main [0-9a-f]{40}", m)


def test_verify_ok_then_stale_after_main_changes(env):
    assert env.run().returncode == 0
    r = env.run("--verify")
    assert r.returncode == 0 and "SETUP OK" in r.stdout and "UNTRUSTED" not in r.stdout
    env.commit_main(".claude/cloud-allowlist", "level: trusted\nhost: broker.example\n")
    r = env.run("--verify")
    assert r.returncode == 0 and "SETUP STALE" in r.stdout
    assert "bump the (v1) comment" in r.stdout


def test_verify_stale_after_plugin_set_changes(env):
    """The plugin set comes from settings.json, so a settings-only change on main is stale too."""
    assert env.run().returncode == 0
    env.commit_main(".claude/settings.json", '{"enabledPlugins": {"defaults@maguerrieri-toolbox": true, "gm@maguerrieri-toolbox": true}}\n')
    r = env.run("--verify")
    assert "SETUP STALE" in r.stdout


def test_verify_absent_without_snapshot(env):
    r = env.run("--verify")
    assert r.returncode == 0 and "SETUP ABSENT" in r.stdout


def test_verify_reports_remote_override(env):
    (env.checkout / ".claude" / "settings.json").write_text('{"remote": {"defaultEnvironmentId": "env_x"}}')
    r = env.run("--verify")
    assert "PROJECT remote.* OVERRIDE PRESENT" in r.stdout
    assert "UNTRUSTED .claude/" in r.stdout  # the edit itself is drift


def test_verify_never_fails_when_origin_unreachable(env):
    git(str(env.checkout), "remote", "set-url", "origin", str(env.checkout.parent / "nowhere.git"))
    r = env.run("--verify")
    assert r.returncode == 0 and "SETUP VERIFY SKIPPED" in r.stdout


def test_provision_refuses_when_origin_unreachable(env):
    git(str(env.checkout), "remote", "set-url", "origin", str(env.checkout.parent / "nowhere.git"))
    r = env.run()
    assert r.returncode == 1 and "refusing to provision" in r.stderr
    assert "claude" not in env.calls() and "gcloud" not in env.calls()


def test_branch_copy_is_never_what_runs(env):
    """The stub runs origin/main's text; a branch edit to the script is inert."""
    (env.checkout / ".claude" / "cloud-setup.sh").write_text("#!/bin/bash\necho BRANCH_MARKER\n")
    r = env.run()
    assert "BRANCH_MARKER" not in r.stdout and r.returncode == 0
    assert "UNTRUSTED .claude/" in r.stdout


def test_unknown_mode_is_an_error(env):
    r = env.run("--bogus")
    assert r.returncode == 1 and "unknown mode" in r.stderr


def test_recorded_gui_stub_runs_the_main_copy(env, tmp_path):
    """The stub text spec 2b records, run verbatim against this fixture."""
    spec = os.path.join(REPO, "docs", "superpowers", "specs", "2026-09-11-software-factory-design.md")
    if not os.path.exists(spec):
        pytest.skip("the stub is recorded in claude-toolbox's spec; this repo carries a copy of the script only")
    with open(spec) as f:
        text = f.read()
    m = re.search(r"```bash\n(# factory-implementer setup script \(v1\).*?)```", text, re.S)
    assert m, "spec 2b must record the GUI stub"
    stub = m.group(1)
    r = subprocess.run(["bash", "-c", stub], cwd=str(env.checkout), env=env.vars, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "snapshot manifest written" in r.stdout
    # With origin/main unreachable the stub fails closed before running anything.
    git(str(env.checkout), "remote", "set-url", "origin", str(tmp_path / "nowhere.git"))
    env.log.write_text("")
    r = subprocess.run(["bash", "-c", stub], cwd=str(env.checkout), env=env.vars, capture_output=True, text=True)
    assert r.returncode != 0 and env.calls() == ""
