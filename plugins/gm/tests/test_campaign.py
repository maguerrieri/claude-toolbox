import os
import subprocess


def run(campaign_path, *args):
    return subprocess.run([campaign_path, *args], capture_output=True, text=True)


def git(d, *args):
    return subprocess.run(["git", "-C", d, *args], capture_output=True, text=True).stdout


def test_init_creates_dedicated_repo(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    p = run(campaign_path, "init", d, "--author", "Grognard Claude", "--email", "grognard@example.test")
    assert p.returncode == 0
    assert os.path.isfile(os.path.join(d, ".gm-campaign"))
    assert "grognard@example.test" in git(d, "config", "user.email")
    assert len(git(d, "log", "--oneline").strip().splitlines()) == 1


def test_init_defers_inside_existing_repo(campaign_path, tmp_path):
    parent = str(tmp_path / "vault")
    os.makedirs(parent)
    subprocess.run(["git", "-C", parent, "init", "-q"])
    d = os.path.join(parent, "campaign")
    p = run(campaign_path, "init", d)
    assert "deferred" in p.stdout
    assert not os.path.isfile(os.path.join(d, ".gm-campaign"))


def test_checkpoint_commits_changes(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    with open(os.path.join(d, "campaign.md"), "w") as f:
        f.write("# Session 1\n")
    p = run(campaign_path, "checkpoint", d, "--label", "session 1")
    assert "checkpoint: session 1" in p.stdout
    assert len(git(d, "log", "--oneline").strip().splitlines()) == 2


def test_checkpoint_noop_when_clean(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    assert "nothing to checkpoint" in run(campaign_path, "checkpoint", d).stdout


def test_rewind_restores_past_checkpoint(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    f = os.path.join(d, "hp.md")
    with open(f, "w") as fh:
        fh.write("HP 5\n")
    run(campaign_path, "checkpoint", d, "--label", "v1")
    target = git(d, "rev-parse", "HEAD").strip()
    with open(f, "w") as fh:
        fh.write("HP 0 (dead)\n")
    run(campaign_path, "checkpoint", d, "--label", "v2")
    p = run(campaign_path, "rewind", d, "--to", target)
    assert "rewound to" in p.stdout
    assert open(f).read() == "HP 5\n"  # restored


def test_checkpoint_defers_silently_outside_managed(campaign_path, tmp_path):
    parent = str(tmp_path / "vault")
    os.makedirs(parent)
    subprocess.run(["git", "-C", parent, "init", "-q"])
    d = os.path.join(parent, "campaign")
    run(campaign_path, "init", d)  # defers
    p = run(campaign_path, "checkpoint", d)
    assert p.returncode == 0
    assert "not a gm-managed repo" in p.stdout
