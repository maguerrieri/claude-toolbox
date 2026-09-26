"""The GM screen at rest (#171): nothing secret sits in plaintext on disk under .gm/,
and nothing a sealed forge leaves outside it. Claude Code's Bash edit-diff view shows
every file a command changes, so a sealed file has to read as noise."""
import json
import os
import re
import subprocess

import pytest

import gm_screen

# A sealed forge's pool and a sealed answer: none of these may appear, whole or in
# part, in any file the sealed flow leaves on disk.
SECRET_ENTRIES = [
    "A drowned bell rings from below the waterline.",
    "Your own face, older, mouthing a name you have not heard yet.",
    "A ladder of knotted hair descending into warm dark.",
]
SEALED_ANSWER = "Marrow the ferryman poisoned the well to hide the crossing."
RESERVOIR = ("# well-glimpse frame\n\n## Reservoir\n"
             + "".join(f"- {e}\n" for e in SECRET_ENTRIES)
             + "\n## Cold storage\n")


def run(path, *args, stdin=None):
    return subprocess.run([path, *args], input=stdin, capture_output=True, text=True)


def git(d, *args):
    return subprocess.run(["git", "-C", d, *args], capture_output=True, text=True).stdout


def new_campaign(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    os.makedirs(d)
    with open(os.path.join(d, "campaign.md"), "w") as f:
        f.write("---\nadapter: generic\n---\n")
    run(campaign_path, "init", d)
    return d


def all_files(d):
    for dirpath, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if x != ".git"]
        for name in files:
            yield os.path.join(dirpath, name)


def plaintext_hits(d, needles):
    """(file, needle) for every needle found in plaintext in any file under d."""
    hits = []
    for p in all_files(d):
        with open(p, encoding="utf-8", errors="replace") as f:
            data = f.read()
        hits += [(os.path.relpath(p, d), n) for n in needles if n in data]
    return hits


def sealed_forge(forge_path, d, kind="well-glimpse"):
    """The gm:screen subagent's steps: draft the reservoir under .gm/forge/ (Write
    tool), then harvest it into the sealed table, consuming the draft."""
    draft = os.path.join(d, ".gm", "forge", f"{kind}.md")
    os.makedirs(os.path.dirname(draft), exist_ok=True)
    with open(draft, "w") as f:
        f.write(RESERVOIR)
    table = os.path.join(d, ".gm", "tables", f"{kind}.md")
    return run(forge_path, "harvest", "--consume", draft, table), draft, table


# ---- the codec ------------------------------------------------------------

@pytest.mark.parametrize("text", ["", "one line", "multi\nline\n", "ünïcødé — ☠\n" * 50])
def test_seal_round_trips(text):
    sealed = gm_screen.seal(text)
    assert sealed.startswith(gm_screen.MAGIC)
    assert gm_screen.unseal(sealed) == text


def test_sealed_text_reads_as_noise():
    sealed = gm_screen.seal(SEALED_ANSWER)
    for word in ("Marrow", "ferryman", "poisoned", "well"):
        assert word not in sealed
    assert all(len(line) <= 76 for line in sealed.splitlines()[1:])


def test_plaintext_passes_through_unseal():
    assert gm_screen.unseal('{"secrets": {}}\n') == '{"secrets": {}}\n'


def test_corrupt_sealed_data_is_an_error_not_garbage():
    with pytest.raises(ValueError):
        gm_screen.unseal(gm_screen.HEADER + "not base64 at all!!\n")


def test_behind_screen():
    assert gm_screen.behind_screen("/c/.gm/tables/x.md")
    assert gm_screen.behind_screen("/c/.gm/state.json")
    assert not gm_screen.behind_screen("/c/tables/x.md")
    assert not gm_screen.behind_screen("/c/.gm")          # the dir itself, not a file in it
    assert not gm_screen.behind_screen("/c/docs/generation/.gmx/x.md")


# ---- acceptance: no plaintext secret on disk ------------------------------

def test_sealed_flow_leaves_no_plaintext_secret_anywhere(campaign_path, forge_path, roll_path, tmp_path):
    """The fixture's entries, grepped against every file the sealed flow leaves in the
    campaign, find nothing — and the readers still read them."""
    d = new_campaign(campaign_path, tmp_path)
    p, draft, table = sealed_forge(forge_path, d)
    assert p.returncode == 0, p.stderr
    assert "(sealed)" in p.stdout
    # a sealed answer, as the gm:screen subagent seals it: drafted, then consumed
    answer = os.path.join(d, ".gm", "inbox", "the-well.md")
    os.makedirs(os.path.dirname(answer))
    with open(answer, "w") as f:
        f.write(SEALED_ANSWER + "\n")
    s = run(campaign_path, "gm-seal", d, "the-well", "--from", answer)
    assert s.returncode == 0, s.stderr
    run(campaign_path, "gm-clock", d, "the-watchers", "--segments", "6", "--advance", "2")
    run(campaign_path, "checkpoint", d, "--label", "sealed")

    needles = SECRET_ENTRIES + [SEALED_ANSWER, "Marrow", "drowned bell", "knotted hair"]
    assert plaintext_hits(d, needles) == []
    assert not os.path.exists(draft) and not os.path.exists(answer)   # drafts consumed
    assert not os.path.exists(os.path.join(d, "docs"))                # no reservoir outside .gm/
    assert "Marrow" not in git(d, "log", "-p", "--all")               # nor in git history

    # the readers decode transparently
    assert SEALED_ANSWER in run(campaign_path, "gm-reveal", d, "the-well").stdout
    assert "clock 'the-watchers': 2/6" in run(campaign_path, "gm-reveal", d, "the-watchers").stdout
    listing = run(campaign_path, "gm-list", d).stdout
    assert "secret: the-well" in listing and "clock: the-watchers" in listing
    r = run(roll_path, "table", table, "--n", "3", "--json")
    assert r.returncode == 0, r.stderr
    assert sorted(json.loads(r.stdout)["picks"]) == sorted(SECRET_ENTRIES)


def test_every_write_leaves_state_sealed(campaign_path, tmp_path):
    d = new_campaign(campaign_path, tmp_path)
    state = os.path.join(d, ".gm", "state.json")
    for args in (["gm-clock", d, "c", "--segments", "4"], ["gm-clock", d, "c", "--advance", "1"],
                 ["gm-clock", d, "c", "--set", "3"], ["gm-seal", d, "x", "Secretive text"]):
        assert run(campaign_path, *args).returncode == 0
        assert gm_screen.is_sealed(open(state).read())
    run(campaign_path, "gm-seal", d, "y", stdin="Stdin secret\n")
    raw = open(state).read()
    assert "Secretive" not in raw and "Stdin" not in raw


# ---- gm-seal --from -------------------------------------------------------

def test_gm_seal_from_consumes_the_draft(campaign_path, tmp_path):
    d = new_campaign(campaign_path, tmp_path)
    draft = tmp_path / "draft.md"
    draft.write_text("line one\nline two\n")
    p = run(campaign_path, "gm-seal", d, "twist", "--from", str(draft))
    assert p.returncode == 0, p.stderr
    assert "line one" not in p.stdout
    assert not draft.exists()
    assert run(campaign_path, "gm-reveal", d, "twist").stdout == "line one\nline two\n"


def test_gm_seal_from_reads_a_draft_the_sweep_already_sealed(campaign_path, tmp_path):
    d = new_campaign(campaign_path, tmp_path)
    draft = os.path.join(d, ".gm", "inbox", "t.md")
    os.makedirs(os.path.dirname(draft))
    with open(draft, "w") as f:
        f.write(gm_screen.seal("already sealed\n"))
    run(campaign_path, "gm-seal", d, "t", "--from", draft)
    assert run(campaign_path, "gm-reveal", d, "t").stdout.strip() == "already sealed"


def test_gm_seal_rejects_text_and_from_together(campaign_path, tmp_path):
    d = new_campaign(campaign_path, tmp_path)
    draft = tmp_path / "draft.md"
    draft.write_text("x\n")
    p = run(campaign_path, "gm-seal", d, "t", "inline", "--from", str(draft))
    assert p.returncode != 0 and "not both" in p.stderr
    assert draft.exists()  # nothing consumed on a refused call


def test_gm_seal_from_a_missing_draft_is_a_clean_error(campaign_path, tmp_path):
    d = new_campaign(campaign_path, tmp_path)
    p = run(campaign_path, "gm-seal", d, "t", "--from", str(tmp_path / "nope.md"))
    assert p.returncode != 0 and p.stderr.startswith("campaign:")
    assert "Traceback" not in p.stderr


# ---- legacy plaintext .gm/ ------------------------------------------------

def write_legacy(d):
    os.makedirs(os.path.join(d, ".gm", "tables"))
    with open(os.path.join(d, ".gm", "state.json"), "w") as f:
        json.dump({"clocks": {"doom": {"filled": 1, "segments": 4}},
                   "secrets": {"twist": "Old plaintext twist"}}, f)
    with open(os.path.join(d, ".gm", "tables", "old.md"), "w") as f:
        f.write("# old\n- Old plaintext entry\n")


def test_legacy_plaintext_state_and_tables_still_read(campaign_path, roll_path, tmp_path):
    d = new_campaign(campaign_path, tmp_path)
    write_legacy(d)
    assert "Old plaintext twist" in run(campaign_path, "gm-reveal", d, "twist").stdout
    assert "clock: doom" in run(campaign_path, "gm-list", d).stdout
    r = run(roll_path, "table", os.path.join(d, ".gm", "tables", "old.md"), "--seed", "1")
    assert "Old plaintext entry" in r.stdout


def test_a_write_seals_legacy_state_on_first_touch(campaign_path, tmp_path):
    d = new_campaign(campaign_path, tmp_path)
    write_legacy(d)
    run(campaign_path, "gm-clock", d, "doom", "--advance", "1")
    raw = open(os.path.join(d, ".gm", "state.json")).read()
    assert gm_screen.is_sealed(raw) and "twist" not in raw
    assert "clock 'doom': 2/4" in run(campaign_path, "gm-reveal", d, "doom").stdout
    assert "Old plaintext twist" in run(campaign_path, "gm-reveal", d, "twist").stdout


def test_gm_migrate_seals_every_plaintext_file_once(campaign_path, roll_path, tmp_path):
    d = new_campaign(campaign_path, tmp_path)
    write_legacy(d)
    p = run(campaign_path, "gm-migrate", d)
    assert p.returncode == 0 and "sealed 2 plaintext files" in p.stdout
    assert plaintext_hits(os.path.join(d, ".gm"), ["Old plaintext"]) == []
    assert "Old plaintext twist" in run(campaign_path, "gm-reveal", d, "twist").stdout
    assert "Old plaintext entry" in run(roll_path, "table", os.path.join(d, ".gm", "tables", "old.md")).stdout
    assert "nothing to seal" in run(campaign_path, "gm-migrate", d).stdout  # idempotent


def test_gm_migrate_without_a_screen_is_a_no_op(campaign_path, tmp_path):
    d = new_campaign(campaign_path, tmp_path)
    p = run(campaign_path, "gm-migrate", d)
    assert p.returncode == 0 and "nothing to seal" in p.stdout
    assert not os.path.exists(os.path.join(d, ".gm"))


def test_rewind_to_a_pre_sealing_checkpoint_comes_back_sealed(campaign_path, tmp_path):
    """A pre-0.6 checkpoint holds a plaintext .gm/; the rewind seals it within the same
    command, so the Bash diff of the rewind never shows the restored secrets."""
    d = new_campaign(campaign_path, tmp_path)
    write_legacy(d)
    run(campaign_path, "checkpoint", d, "--label", "legacy")
    target = git(d, "rev-parse", "HEAD").strip()
    run(campaign_path, "gm-seal", d, "later", "Later secret")
    run(campaign_path, "checkpoint", d, "--label", "later")
    p = run(campaign_path, "rewind", d, "--to", target)
    assert "rewound to" in p.stdout
    assert plaintext_hits(os.path.join(d, ".gm"), ["Old plaintext", "Later secret"]) == []
    assert "Old plaintext twist" in run(campaign_path, "gm-reveal", d, "twist").stdout
    assert "nothing sealed under 'later'" in run(campaign_path, "gm-reveal", d, "later").stdout
    assert git(d, "status", "--porcelain") == ""  # the sealed tree is what got committed


# ---- forge harvest --------------------------------------------------------

def test_open_harvest_stays_plaintext(forge_path, tmp_path):
    res = tmp_path / "res.md"
    res.write_text(RESERVOIR)
    table = tmp_path / "camp" / "tables" / "well-glimpse.md"
    p = run(forge_path, "harvest", str(res), str(table))
    assert p.returncode == 0 and "(sealed)" not in p.stdout
    assert SECRET_ENTRIES[0] in table.read_text()
    assert res.exists()  # no --consume: an open forge's reservoir is left alone


def test_sealed_harvest_warns_about_a_plaintext_reservoir_left_outside(forge_path, tmp_path):
    res = tmp_path / "camp" / "docs" / "generation" / "x.md"
    res.parent.mkdir(parents=True)
    res.write_text(RESERVOIR)
    table = tmp_path / "camp" / ".gm" / "tables" / "x.md"
    p = run(forge_path, "harvest", str(res), str(table))
    assert p.returncode == 0
    assert gm_screen.is_sealed(table.read_text())
    assert "outside the GM screen" in p.stderr
    assert SECRET_ENTRIES[0] not in p.stderr  # the warning names the file, never the pool


def test_consume_deletes_the_reservoir_only_after_a_good_harvest(forge_path, tmp_path):
    res = tmp_path / ".gm" / "forge" / "x.md"
    res.parent.mkdir(parents=True)
    res.write_text("# frame\n## Axes\n")  # no entries: the harvest fails
    table = tmp_path / ".gm" / "tables" / "x.md"
    p = run(forge_path, "harvest", "--consume", str(res), str(table))
    assert p.returncode != 0 and res.exists() and not table.exists()


def test_harvest_reads_a_sealed_reservoir(forge_path, roll_path, tmp_path):
    res = tmp_path / ".gm" / "forge" / "x.md"
    res.parent.mkdir(parents=True)
    res.write_text(gm_screen.seal(RESERVOIR))  # the Stop hook's sweep got to it first
    table = tmp_path / ".gm" / "tables" / "x.md"
    assert run(forge_path, "harvest", "--consume", str(res), str(table)).returncode == 0
    assert SECRET_ENTRIES[1] in run(roll_path, "table", str(table), "--n", "3").stdout


def test_no_doc_puts_a_secret_in_a_command(tmp_path):
    """Regression guard for #171's second channel: the docs once told the GM to write a
    sealed pool with a Bash heredoc and to seal an answer as a command argument."""
    plugin = os.path.join(os.path.dirname(__file__), "..")
    quoted_seal = re.compile(r"gm-seal\s+\S+\s+\S+\s+[\"'<]")  # gm-seal <dir> <id> "<text>"
    offenders = []
    for dirpath, dirs, files in os.walk(plugin):
        dirs[:] = [x for x in dirs if x not in ("tests", "__pycache__")]
        for name in files:
            if not name.endswith(".md"):
                continue
            p = os.path.join(dirpath, name)
            text = open(p, encoding="utf-8").read()
            if "Bash heredoc" in text or quoted_seal.search(text):
                offenders.append(os.path.relpath(p, plugin))
    assert offenders == []


def test_screen_subagent_is_shipped():
    agent = os.path.join(os.path.dirname(__file__), "..", "agents", "screen.md")
    head = open(agent, encoding="utf-8").read().split("---")[1]
    assert re.search(r"^name: screen$", head, re.M)
    for tool in ("Write", "Bash", "Skill"):
        assert tool in re.search(r"^tools: (.*)$", head, re.M).group(1)


def test_roll_reports_a_corrupt_sealed_table_cleanly(roll_path, tmp_path):
    t = tmp_path / "t.md"
    t.write_text(gm_screen.HEADER + "@@@\n")
    p = run(roll_path, "table", str(t))
    assert p.returncode != 0 and p.stderr.startswith("roll:") and "Traceback" not in p.stderr
