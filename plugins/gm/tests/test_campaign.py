import json
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


def test_init_refuses_existing_nongm_repo(campaign_path, tmp_path):
    d = str(tmp_path / "existing")
    os.makedirs(d)
    subprocess.run(["git", "-C", d, "init", "-q"])
    p = run(campaign_path, "init", d)
    assert "refusing" in p.stdout
    assert not os.path.isfile(os.path.join(d, ".gm-campaign"))


def test_rewind_removes_files_added_after_target(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    with open(os.path.join(d, "a.md"), "w") as f:
        f.write("a\n")
    run(campaign_path, "checkpoint", d, "--label", "has a")
    target = git(d, "rev-parse", "HEAD").strip()
    with open(os.path.join(d, "b.md"), "w") as f:
        f.write("b\n")
    run(campaign_path, "checkpoint", d, "--label", "has b")
    run(campaign_path, "rewind", d, "--to", target)
    assert os.path.isfile(os.path.join(d, "a.md"))
    assert not os.path.isfile(os.path.join(d, "b.md"))  # added after target -> gone


def test_rewind_bad_ref_is_clean(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    before = len(git(d, "log", "--oneline").strip().splitlines())
    p = run(campaign_path, "rewind", d, "--to", "deadbeef")
    assert "no such checkpoint" in p.stdout
    assert len(git(d, "log", "--oneline").strip().splitlines()) == before  # no stray commit


# ---- GM screen: hidden state under .gm/ ------------------------------------

def _gm_state(d):
    return json.load(open(os.path.join(d, ".gm", "state.json")))


def test_gm_clock_seal_advance_and_reveal(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    p = run(campaign_path, "gm-clock", d, "lanternwright", "--segments", "4")
    assert "sealed" in p.stdout
    assert "0/4" not in p.stdout            # neutral write: no fill value echoed
    run(campaign_path, "gm-clock", d, "lanternwright", "--advance", "2")
    r = run(campaign_path, "gm-reveal", d, "lanternwright")
    assert "2/4" in r.stdout                # reveal surfaces it (run via Bash -> collapses)
    assert _gm_state(d)["clocks"]["lanternwright"]["filled"] == 2


def test_gm_clock_caps_and_reports_complete(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    run(campaign_path, "gm-clock", d, "doom", "--segments", "3")
    p = run(campaign_path, "gm-clock", d, "doom", "--advance", "5")  # overfill
    assert "(complete)" in p.stdout
    assert _gm_state(d)["clocks"]["doom"]["filled"] == 3  # clamped to segments


def test_gm_clock_set(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    run(campaign_path, "gm-clock", d, "c", "--segments", "6", "--set", "4")
    assert _gm_state(d)["clocks"]["c"]["filled"] == 4


def test_gm_seal_arg_and_reveal(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    secret = "The Lanternwright is Briar, lighting her own way back."
    p = run(campaign_path, "gm-seal", d, "the-answer", secret)
    assert "sealed" in p.stdout
    assert secret not in p.stdout           # neutral write: value never echoed
    r = run(campaign_path, "gm-reveal", d, "the-answer")
    assert secret in r.stdout               # reveal surfaces it
    assert _gm_state(d)["secrets"]["the-answer"] == secret


def test_gm_seal_stdin(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    secret = "multi\nline\nsecret"
    p = subprocess.run([campaign_path, "gm-seal", d, "note"],
                       input=secret, capture_output=True, text=True)
    assert "sealed" in p.stdout
    assert _gm_state(d)["secrets"]["note"] == secret


def test_gm_list_shows_ids_not_values(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    run(campaign_path, "gm-clock", d, "doom", "--segments", "4", "--advance", "1")
    run(campaign_path, "gm-seal", d, "twist", "the butler did it")
    p = run(campaign_path, "gm-list", d)
    assert "clock: doom" in p.stdout
    assert "secret: twist" in p.stdout
    assert "the butler did it" not in p.stdout  # names only, never values
    assert "1/4" not in p.stdout                # never the fill either


def test_gm_reveal_all(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    run(campaign_path, "gm-clock", d, "doom", "--segments", "4", "--advance", "3")
    run(campaign_path, "gm-seal", d, "twist", "it was a dream")
    p = run(campaign_path, "gm-reveal", d)  # no id -> everything (GM reloads the screen)
    assert "clock 'doom': 3/4" in p.stdout
    assert "it was a dream" in p.stdout


def test_gm_state_lives_in_sealed_dir_not_stdout(campaign_path, tmp_path):
    """The point: the value is on disk under .gm/, never in the write's stdout."""
    d = str(tmp_path / "camp")
    run(campaign_path, "init", d)
    p = run(campaign_path, "gm-seal", d, "answer", "Smith is the spy")
    assert os.path.isfile(os.path.join(d, ".gm", "state.json"))
    assert "Smith is the spy" not in p.stdout  # not in the (collapsed) write output
    assert "Smith is the spy" in open(os.path.join(d, ".gm", "state.json")).read()


def test_gm_works_in_deferred_campaign(campaign_path, tmp_path):
    """gm-* writes plain files even when gm defers git (inside an existing repo)."""
    parent = str(tmp_path / "vault")
    os.makedirs(parent)
    subprocess.run(["git", "-C", parent, "init", "-q"])
    d = os.path.join(parent, "campaign")
    run(campaign_path, "init", d)  # defers
    p = run(campaign_path, "gm-seal", d, "x", "hidden")
    assert "sealed" in p.stdout
    assert _gm_state(d)["secrets"]["x"] == "hidden"
