import os
import re
import subprocess

EXAMPLES = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "examples"))


def run(campaign_path, *args):
    return subprocess.run([campaign_path, *args], capture_output=True, text=True)


def write(root, rel, text):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)


def campaign(root, premise, truths, character=None, extra=None):
    body = "---\nadapter: generic\npersona: house\nsaves: %s\n---\n\n# Test\n\n" % root
    body += "## Premise\n%s\n\n## Truths\n" % premise
    body += "".join("- %s\n" % t for t in truths)
    body += "\n## Tone & safety\nWhatever the player said. **Lines:** none stated. **Veils:** none stated.\n"
    write(root, "campaign.md", body)
    if character:
        write(root, "characters/pc.md", character)
    for rel, text in (extra or {}).items():
        write(root, rel, text)


def examples(root, names="Brindle, Osk, Pell"):
    """A one-campaign examples dir: 'Brindle' town, 'Osk' the heroine, one distinctive truth."""
    ex = os.path.join(root, "examples")
    write(ex, "brindle/campaign.md",
          "---\nadapter: generic\nnames: %s\n---\n\n# Brindle\n\n## Premise\n"
          "The town of Brindle guards the salt road where three caravans have gone missing.\n\n"
          "## Truths\n- The salt road was paved by giants and no one has repaired it since.\n"
          "- Brindle's bells ring on their own at midnight.\n\n"
          "## Tone & safety\nLight adventure with a sting in the tail. "
          "**Lines:** harm to animals and children. **Veils:** none at all here.\n" % names)
    write(ex, "brindle/characters/osk.md",
          "# Osk\n\n- **Concept:** A courier who knows the salt road, like her mother Pell before her.\n")
    return ex


FRESH_PREMISE = "A drowned city resurfaces each spring tide, and the tax collectors row out first."
FRESH_TRUTHS = ["The tide tables are a state secret.", "Every guild owns one bell and rings it at dawn."]


# --- names ---

def test_fresh_campaign_passes(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS,
             "# Ilse Varga\n\n- **Concept:** A diver who owes the harbormaster a favor.\n")
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 0, p.stdout + p.stderr
    assert "no names or prose shared" in p.stdout
    assert "brindle" in p.stdout                    # says what it compared against


def test_declared_name_fails(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS, "# Osk Calloway\n\n- **Concept:** A diver.\n")
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 1
    assert '"Osk"' in p.stdout and "brindle" in p.stdout


def test_possessive_name_counts(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, "Up past Brindle's last milestone, the snow never melts.", ["Wolves speak."])
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 1
    assert '"Brindle"' in p.stdout


def test_names_match_whole_words_case_sensitively(campaign_path, tmp_path):
    # "Oskar" isn't "Osk", and the lowercase saves path "brindle-2" isn't the town.
    ex = examples(str(tmp_path))
    d = str(tmp_path / "brindle-2")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS, "# Oskar\n\n- **Concept:** A diver.\n")
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 0


def test_undeclared_words_are_not_names(campaign_path, tmp_path):
    # Only the declared names count: sheet labels, section headings and common words don't.
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, "Three moons. The light never fails. Light is cheap here.", FRESH_TRUTHS,
             "# Ilse\n\n- **Concept:** A diver.\n- **Notes / Inventory:** a knife\n")
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 0


def test_allow_keeps_a_player_chosen_name(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, "Osk and Pell run the ferry.", FRESH_TRUTHS)
    p = run(campaign_path, "example-overlap", d, "--examples", ex, "--allow", "Osk")
    assert p.returncode == 1
    assert '"Pell"' in p.stdout and '"Osk"' not in p.stdout
    p = run(campaign_path, "example-overlap", d, "--examples", ex, "--allow", "Osk", "--allow", "Pell")
    assert p.returncode == 0, p.stdout


# --- prose ---

def test_near_copy_truth_fails_without_printing_the_example(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, ["The old road was paved by giants and no one has repaired it since."])
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 1
    assert "paved by giants" in p.stdout            # the campaign's own line, named
    assert "salt road" not in p.stdout              # the example's text never printed


def test_copied_prose_is_caught_under_any_heading_or_bullet(campaign_path, tmp_path):
    # The prose check doesn't depend on a "## Truths" heading or "- " bullets.
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS)
    with open(os.path.join(d, "campaign.md"), "a") as f:
        f.write("\n### World truths\n* The old road was paved by giants and no one has repaired it since.\n")
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 1


def test_copied_premise_fails(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, "The town of Harrow guards the salt road where three caravans have gone missing.",
             FRESH_TRUTHS)
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 1
    assert "Harrow" in p.stdout


def test_hard_wrapped_prose_is_rejoined_but_headings_are_not(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, "The town of Harrow guards the salt road\nwhere three caravans have gone missing.",
             FRESH_TRUTHS)
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 1
    assert '"The town of Harrow guards' in p.stdout      # the heading above isn't glued on


def test_example_sentence_inside_a_longer_one_fails(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE,
             ["Everyone knows the story: the salt road was paved by giants and no one has "
              "repaired it since, though the guild of wheelwrights keeps petitioning the council."])
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 1


def test_unrelated_prose_passes(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, ["The harbor chain was forged from a single anchor."])
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 0


def test_safety_lines_are_the_players_and_not_checked(campaign_path, tmp_path):
    # Lines & veils are the player's own words; matching a demo's is not a copy.
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS)
    with open(os.path.join(d, "campaign.md"), "a") as f:
        f.write("**Lines:** harm to animals and children. **Veils:** none at all here.\n")
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 0


def test_names_in_the_players_safety_lines_are_not_flagged(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS)
    with open(os.path.join(d, "campaign.md"), "a") as f:
        f.write("Grim war — **Lines:** nothing like Osk's ending. **Veils:** Pell\n")
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 0, p.stdout


def test_combined_lines_and_veils_labels_are_safety_too(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    with open(os.path.join(ex, "brindle", "campaign.md")) as f:
        text = f.read().replace("Light adventure with a sting in the tail. **Lines:** harm to animals and "
                                "children. **Veils:** none at all here.",
                                "Light adventure — **Lines & veils** (the player's words): harm to animals "
                                "and children, and none at all here")
    with open(os.path.join(ex, "brindle", "campaign.md"), "w") as f:
        f.write(text)
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS)
    with open(os.path.join(d, "campaign.md"), "a") as f:
        f.write("Grim war — Lines and veils (as told): harm to animals and children, and none at all here, Osk\n")
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 0, p.stdout


def test_a_safety_list_runs_to_the_end_of_its_line(campaign_path, tmp_path):
    # Players list lines & veils with semicolons and periods; the whole list is theirs.
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS)
    with open(os.path.join(d, "campaign.md"), "a") as f:
        f.write("Grim war. **Lines:** harm to animals; anything like Osk's ending. Pell. "
                "**Veils:** the salt road was paved by giants and no one has repaired it since\n")
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 0, p.stdout


def _safety(tmp_path, block):
    """Run the check on a fresh campaign whose tone & safety section ends with `block`."""
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS)
    with open(os.path.join(d, "campaign.md"), "a") as f:
        f.write(block)
    return ex, d


def test_a_list_under_a_bare_label_is_the_players(campaign_path, tmp_path):
    ex, d = _safety(tmp_path, "\n**Lines:**\n- harm to animals\n- anything like Osk's ending\n"
                              "**Veils:**\n  * Pell\n")
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 0, p.stdout


def test_a_list_nested_under_a_label_is_the_players(campaign_path, tmp_path):
    ex, d = _safety(tmp_path, "- **Lines & veils** (their words): see below\n"
                              "    - **Lines:** none\n    - Osk's ending, off-screen\n")
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 0, p.stdout


def test_a_wrapped_label_paragraph_is_the_players(campaign_path, tmp_path):
    ex, d = _safety(tmp_path, "**Lines:** harm to animals, and anything\nlike Osk's ending.\n")
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 0, p.stdout


def test_a_lines_and_veils_section_is_the_players(campaign_path, tmp_path):
    ex, d = _safety(tmp_path, "\n### Lines & veils\n\nNothing like Osk's ending.\n\nNo Pell either.\n")
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 0, p.stdout


def test_sections_and_siblings_after_the_safety_lines_are_checked(campaign_path, tmp_path):
    # A sibling bullet after a label, and a heading after a safety section, are prose again.
    ex, d = _safety(tmp_path, "- **Lines:** none\n- **Tone:** haunted by Osk\n")
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 1
    ex, d = _safety(tmp_path / "b", "\n## Lines & veils\n\nNone.\n\n## Notes\n\nPell waits.\n")
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 1


def test_lines_in_ordinary_prose_is_not_a_label(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, ["The ley lines converge here: under Osk's tower."])
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 1


def test_prose_merely_starting_with_lines_or_veils_is_still_checked(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS, extra={"locations.md": "# Places\n\n## Veils of Osk\n"})
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 1


def test_safety_labels_split_a_line_even_without_a_period(campaign_path, tmp_path):
    # Tone and safety often share a line with no sentence end before the label; the
    # player's lines & veils must still stay out of the comparison, on both sides.
    ex = examples(str(tmp_path))
    with open(os.path.join(ex, "brindle", "campaign.md")) as f:
        text = f.read().replace("Light adventure with a sting in the tail. **Lines:**",
                                "Light adventure — **Lines:**")
    with open(os.path.join(ex, "brindle", "campaign.md"), "w") as f:
        f.write(text)
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS)
    with open(os.path.join(d, "campaign.md"), "a") as f:
        f.write("Grim war — **Lines:** harm to animals and children, **Veils:** none at all here\n")
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 0, p.stdout


# --- scope ---

def test_only_campaign_content_is_scanned(campaign_path, tmp_path):
    # Raw play, sealed state, forged tables and generate reservoirs aren't the campaign's content.
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS, extra={
        "log/raw/2026-01-01-abcdef12.md": "### Player\n\nCan I be called Osk?\n",
        ".gm/tables/hook.md": "- Osk returns.\n",
        "tables/hook.md": "- Pell sells a map.\n",
        "docs/generation/hook.md": "## Reservoir\n- Brindle burns.\n",
    })
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 0


def test_npcs_and_session_logs_are_scanned(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS, extra={"npcs.md": "# NPCs\n\n- **Pell** — a ferrywoman.\n"})
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 1
    d2 = str(tmp_path / "camp2")
    campaign(d2, FRESH_PREMISE, FRESH_TRUTHS, extra={"log/0000-prologue.md": "Osk arrives.\n"})
    assert run(campaign_path, "example-overlap", d2, "--examples", ex).returncode == 1


def test_an_example_checked_against_itself_is_skipped(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    p = run(campaign_path, "example-overlap", os.path.join(ex, "brindle"), "--examples", ex)
    assert p.returncode == 0, p.stdout


def test_missing_examples_dir_is_an_error(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS)
    p = run(campaign_path, "example-overlap", d, "--examples", str(tmp_path / "nope"))
    assert p.returncode not in (0, 1)
    assert "examples" in p.stderr


def test_missing_campaign_dir_errors(campaign_path, tmp_path):
    p = run(campaign_path, "example-overlap", str(tmp_path / "nope"))
    assert p.returncode not in (0, 1)
    assert "campaign.md" in p.stderr


# --- the bundled examples ---

def _front_matter_names(example_dir):
    with open(os.path.join(example_dir, "campaign.md")) as f:
        m = re.search(r"^names:\s*(.+)$", f.read().split("\n---", 1)[0], re.M)
    return [n.strip() for n in m.group(1).split(",")] if m else []


def test_every_bundled_example_declares_names_it_uses():
    # The check is only as good as the declared list: keep it present and not stale.
    dirs = [os.path.join(EXAMPLES, n) for n in os.listdir(EXAMPLES)
            if os.path.isfile(os.path.join(EXAMPLES, n, "campaign.md"))]
    assert dirs
    for d in dirs:
        names = _front_matter_names(d)
        assert names, f"{d}: campaign.md front-matter has no names:"
        text = ""
        for root, _, files in os.walk(d):
            for f in files:
                if f.endswith(".md"):
                    with open(os.path.join(root, f)) as fh:
                        text += re.sub(r"^---\n.*?\n---\n", "", fh.read(), flags=re.S)
        for n in names:
            assert re.search(r"\b%s\b" % re.escape(n), text), f"{d}: declared name {n} is never used"


def test_bundled_embervale_names_are_caught(campaign_path, tmp_path):
    # The #174 regression: a "new" campaign whose protagonist is embervale's Wren, set in Embervale.
    d = str(tmp_path / "camp")
    campaign(d, "The hamlet of Embervale guards the pass.", ["The waystations keep their own calendar."],
             "# Wren Calloway\n\n- **Concept:** A courier.\n")
    p = run(campaign_path, "example-overlap", d)       # default: the plugin's own examples/
    assert p.returncode == 1
    assert '"Wren"' in p.stdout and '"Embervale"' in p.stdout and "embervale" in p.stdout


def test_default_examples_dir_is_the_plugins_own(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    tpl = os.path.join(os.path.dirname(EXAMPLES), "adapters", "generic", "sheet-template.md")
    with open(tpl) as f:
        sheet = f.read().replace("{{name}}", "Ilse Varga")
    campaign(d, FRESH_PREMISE, FRESH_TRUTHS, sheet)
    p = run(campaign_path, "example-overlap", d)
    assert p.returncode == 0, p.stdout + p.stderr
    assert "embervale" in p.stdout
