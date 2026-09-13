"""Integration tests for .github/self-hosted/provision-from-ref.sh.

The build step hands item 6's `.claude/cloud-setup.sh` the checkout it reads its
inputs from. That script is written for a cloud session: it takes `repo_dir` from
`CLAUDE_PROJECT_DIR`, requires `repo_dir/.git`, fetches
`origin +refs/heads/main:refs/remotes/origin/main`, and reads `settings.json`,
the allowlist and its own copy out of `origin/main`. These tests drive the real
contract against a throwaway upstream repository whose `main` has moved past the
pinned commit, so "provisioned from the pinned SHA" is distinguishable from
"provisioned from whatever main says now".

`test_real_item6_script_provisions` runs the repository's own
`.claude/cloud-setup.sh` through the same path once item 6 lands it; until then
it skips and the contract probe below covers the mechanics.
"""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
PROVISION = REPO_ROOT / ".github" / "self-hosted" / "provision-from-ref.sh"
REAL_SETUP = REPO_ROOT / ".claude" / "cloud-setup.sh"

GIT_ENV = {
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@example.com",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.com",
}

# Stands in for item 6's script, asserting exactly what it requires of the
# context and recording what it saw. Like the real one it cds to a temp dir.
CONTRACT_PROBE = r"""#!/bin/bash
set -euo pipefail
repo_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
out="${PROBE_OUT:?PROBE_OUT must be set}"
self=$0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT; cd "$work"
{
  printf 'self=%s\n' "$self"
  printf 'cwd=%s\n' "$PWD"
  printf 'repo_dir=%s\n' "$repo_dir"
  if [ ! -d "$repo_dir/.git" ] && [ ! -f "$repo_dir/.git" ]; then
    printf 'FAIL=not-a-git-checkout\n'; exit 1
  fi
  git -C "$repo_dir" fetch -q --depth=1 origin +refs/heads/main:refs/remotes/origin/main \
    || { printf 'FAIL=fetch-main\n'; exit 1; }
  printf 'origin_main=%s\n' "$(git -C "$repo_dir" rev-parse origin/main)"
  printf 'settings=%s\n' "$(git -C "$repo_dir" show origin/main:.claude/settings.json | tr -d ' \n')"
  printf 'allowlist=%s\n' "$(git -C "$repo_dir" show origin/main:.claude/cloud-allowlist | tr -d ' \n')"
  printf 'setup_self=%s\n' "$(git -C "$repo_dir" show origin/main:.claude/cloud-setup.sh | head -c 20 | tr -d ' \n')"
  drift=$( { git -C "$repo_dir" diff --name-only origin/main -- .claude ':(exclude).claude/worktrees' || true
             git -C "$repo_dir" ls-files --others -- .claude ':(exclude).claude/worktrees' || true
           } | sed '/^$/d' | paste -sd, - )
  printf 'drift=[%s]\n' "$drift"
  mkdir -p "$HOME/.factory-setup" && printf 'home_writable=yes\n' || printf 'home_writable=no\n'
  printf 'OK=1\n'
} >"$out"
"""

CLAUDE_STUB = r"""#!/usr/bin/env bash
# Records every invocation so the test can assert the pinned marketplace adds.
printf '%s\n' "$*" >>"${FAKE_CLAUDE_LOG:?}"
exit 0
"""


def git(*args: str, cwd: Path) -> str:
    return subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, **GIT_ENV},
    ).stdout.strip()


class Upstream:
    """A repo whose `main` carries a second commit after the pinned one."""

    def __init__(self, tmp_path: Path, setup_script: str | None):
        self.path = tmp_path / "upstream"
        self.path.mkdir()
        git("init", "-q", "-b", "main", ".", cwd=self.path)
        claude = self.path / ".claude"
        claude.mkdir()
        (claude / "settings.json").write_text(
            '{"enabledPlugins": {"defaults@maguerrieri-toolbox": true,'
            ' "rogue@evil-marketplace": true}}\n'
        )
        (claude / "cloud-allowlist").write_text("pinned.example\n")
        if setup_script is not None:
            script = claude / "cloud-setup.sh"
            script.write_text(setup_script)
            script.chmod(0o755)
        git("add", "-A", cwd=self.path)
        git("commit", "-qm", "pinned", cwd=self.path)
        self.pinned_sha = git("rev-parse", "HEAD", cwd=self.path)
        # main moves on: a rebuild must not pick this up.
        (claude / "cloud-allowlist").write_text("pinned.example\nlater.example\n")
        if setup_script is not None:
            (claude / "cloud-setup.sh").write_text(setup_script + "\n# later, unreviewed\n")
        git("add", "-A", cwd=self.path)
        git("commit", "-qm", "later", cwd=self.path)
        self.head_sha = git("rev-parse", "HEAD", cwd=self.path)

    def blob(self, path: str, ref: str | None = None) -> str:
        return subprocess.run(
            ["git", "-C", str(self.path), "show", f"{ref or self.pinned_sha}:{path}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout


class Run:
    def __init__(self, tmp_path: Path, upstream: Upstream, **env):
        self.install_dir = tmp_path / "opt" / "factory"
        self.context_dir = tmp_path / "ctx"
        self.home = tmp_path / "home"
        self.home.mkdir()
        self.probe_out = tmp_path / "probe.txt"
        self.claude_log = tmp_path / "claude.log"
        self.claude_log.touch()
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "claude"
        stub.write_text(CLAUDE_STUB)
        stub.chmod(0o755)
        self.env = {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(self.home),
            "FACTORY_SETUP_REPO": f"file://{upstream.path}",
            "FACTORY_INSTALL_DIR": str(self.install_dir),
            "FACTORY_CONTEXT_DIR": str(self.context_dir),
            "FACTORY_RUN_AS": "",  # run as this user, not `runner`
            "PROBE_OUT": str(self.probe_out),
            "FAKE_CLAUDE_LOG": str(self.claude_log),
            **GIT_ENV,
            **env,
        }

    def __call__(self, ref: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(PROVISION), ref], capture_output=True, text=True, env=self.env
        )

    def probe(self) -> dict:
        return dict(
            line.split("=", 1)
            for line in self.probe_out.read_text().splitlines()
            if "=" in line
        )

    def claude_calls(self) -> list[str]:
        return [c for c in self.claude_log.read_text().splitlines() if c]


@pytest.fixture
def upstream(tmp_path: Path) -> Upstream:
    return Upstream(tmp_path, CONTRACT_PROBE)


# --- the context item 6's script requires -----------------------------------


def test_setup_runs_against_a_checkout_pinned_to_the_reviewed_commit(tmp_path: Path, upstream: Upstream):
    run = Run(tmp_path, upstream)
    result = run(upstream.pinned_sha)
    assert result.returncode == 0, result.stderr
    probe = run.probe()
    assert probe["OK"] == "1"
    # The failure the review caught: no checkout, no fetchable origin/main.
    assert "FAIL" not in probe
    assert probe["repo_dir"] == str(run.context_dir)
    assert probe["origin_main"] == upstream.pinned_sha, "must not follow upstream main"
    assert probe["origin_main"] != upstream.head_sha
    # Inputs come from the pinned commit, not from the newer main.
    assert probe["allowlist"] == "pinned.example"
    assert "rogue@evil-marketplace" in probe["settings"]
    assert probe["setup_self"].startswith("#!/bin/bash")
    # A clean .claude/ means the snapshot is provisioned as a trusted one.
    assert probe["drift"] == "[]"
    assert probe["home_writable"] == "yes"
    # The script still runs from its own temp dir, and it is the root-owned
    # installed copy that runs, never the writable one in the context.
    assert probe["cwd"] != probe["repo_dir"]
    assert probe["self"] == str(run.install_dir / "cloud-setup.sh")


def test_installs_the_reviewed_copy_and_records_the_sha(tmp_path: Path, upstream: Upstream):
    run = Run(tmp_path, upstream)
    assert run(upstream.pinned_sha).returncode == 0
    installed = run.install_dir / "cloud-setup.sh"
    assert installed.read_text() == upstream.blob(".claude/cloud-setup.sh")
    assert installed.read_text() != upstream.blob(".claude/cloud-setup.sh", upstream.head_sha)
    assert stat.S_IMODE(installed.stat().st_mode) == 0o444
    assert (run.install_dir / "cloud-setup.ref").read_text().strip() == upstream.pinned_sha
    assert stat.S_IMODE((run.install_dir / "cloud-setup.ref").stat().st_mode) == 0o444


def test_context_does_not_survive_the_build_step(tmp_path: Path, upstream: Upstream):
    run = Run(tmp_path, upstream)
    assert run(upstream.pinned_sha).returncode == 0
    assert not run.context_dir.exists(), "the writable context must not stay in the image"


def test_absent_setup_script_warns_without_failing_the_build(tmp_path: Path):
    bare = Upstream(tmp_path, None)
    run = Run(tmp_path, bare)
    result = run(bare.pinned_sha)
    assert result.returncode == 0
    assert "NOT provisioned" in result.stderr and "item 6 pending" in result.stderr
    assert not (run.install_dir / "cloud-setup.sh").exists()
    assert (run.install_dir / "cloud-setup.ref").read_text().strip() == bare.pinned_sha
    assert not run.context_dir.exists()


@pytest.mark.parametrize(
    "ref",
    ["main", "v1.2.3", "2107965", "", "21079652120d2a97b062c5832f74e1f49ac191c" + "Z"],
)
def test_rejects_anything_but_a_full_commit_sha(tmp_path: Path, upstream: Upstream, ref: str):
    run = Run(tmp_path, upstream)
    result = run(ref)
    assert result.returncode == 1
    assert "full 40-hex commit SHA" in result.stderr
    assert not run.probe_out.exists()


def test_refuses_a_sha_the_remote_does_not_have(tmp_path: Path, upstream: Upstream):
    run = Run(tmp_path, upstream)
    result = run("0" * 40)
    assert result.returncode == 1
    assert "could not fetch" in result.stderr
    assert not run.probe_out.exists()
    assert not run.context_dir.exists()


# --- the actual item-6 script ------------------------------------------------


@pytest.mark.skipif(
    not REAL_SETUP.exists(),
    reason="item 6's .claude/cloud-setup.sh is not in this tree yet (PR #122); "
    "the contract probe above covers the context it needs",
)
def test_real_item6_script_provisions(tmp_path: Path):
    """Run the repository's own cloud-setup.sh through the build step."""
    real = Upstream(tmp_path, REAL_SETUP.read_text())
    run = Run(tmp_path, real)
    result = run(real.pinned_sha)
    assert result.returncode == 0, result.stdout + result.stderr
    output = result.stdout + result.stderr
    # Provisioned, and from the pinned commit.
    manifest = (run.home / ".factory-setup" / "manifest").read_text()
    recorded = dict(
        line.split(" ", 1) for line in manifest.splitlines() if " " in line
    )
    assert recorded["origin_main"] == real.pinned_sha
    for key in ("script", "allowlist", "settings"):
        assert len(recorded[key]) == 64, f"{key} hash missing from the manifest"
    # Plugins installed only from the allowlisted marketplace, pinned to a ref.
    adds = [c for c in run.claude_calls() if c.startswith("plugin marketplace add")]
    assert adds, run.claude_calls()
    assert all("#" in c for c in adds), adds
    assert not any("evil-marketplace" in c for c in run.claude_calls())
    assert "evil-marketplace is not on this script's allowlist" in output
    # A clean context is a trusted one, and this repo materializes no logs key.
    assert "UNTRUSTED .claude/" not in output
    assert "no GCP project declared" in output
