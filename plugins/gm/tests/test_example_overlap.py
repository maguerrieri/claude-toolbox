import os
import subprocess

EXAMPLES = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "examples"))


def run(campaign_path, *args):
    return subprocess.run([campaign_path, *args], capture_output=True, text=True)


def write(root, rel, text):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)


def campaign(root, premise, truths, character=None):
    body = "---\nadapter: generic\npersona: house\nsaves: %s\n---\n\n# Test\n\n" % root
    body += "## Premise\n%s\n\n## Truths\n" % premise
    body += "".join("- %s\n" % t for t in truths)
    body += "\n## Tone & safety\nWhatever the player said. **Lines:** none stated. **Veils:** none stated.\n"
    write(root, "campaign.md", body)
    if character:
        write(root, "characters/pc.md", character)


def examples(root):
    """A one-campaign examples dir: 'Brindle' town, 'Osk' the heroine, one distinctive truth."""
    ex = os.path.join(root, "examples")
    write(ex, "brindle/campaign.md",
          "---\nadapter: generic\n---\n\n# Brindle\n\n## Premise\n"
          "The town of Brindle guards the salt road. Three caravans are late.\n\n"
          "## Truths\n- The salt road was paved by giants and no one has repaired it since.\n"
          "- Brindle's bells ring on their own at midnight.\n\n"
          "## Tone & safety\nLight adventure. **Lines:** none.\n")
    write(ex, "brindle/characters/osk.md",
          "# Osk\n\n- **Concept:** A courier who knows the salt road, like her mother Pell before her.\n")
    return ex


def test_fresh_campaign_passes(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, "A drowned city resurfaces each spring tide, and the tax collectors row out first.",
             ["The tide tables are a state secret.", "Every guild owns one bell and rings it at dawn."],
             "# Ilse Varga\n\n- **Concept:** A diver who owes the harbormaster a favor.\n")
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 0, p.stdout + p.stderr
    assert "no names or truths shared" in p.stdout


def test_shared_proper_name_fails(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, "A drowned city resurfaces each spring tide.", ["The tide tables are a state secret."],
             "# Osk Calloway\n\n- **Concept:** A diver.\n")
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


def test_sentence_initial_common_words_are_not_names(campaign_path, tmp_path):
    # "Three" and "Light" open sentences in the example, and "The" is everywhere;
    # none of them is a name, so reusing them is not an overlap.
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, "Three moons. The light never fails. Light is cheap here.",
             ["The tide tables are a state secret."])
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 0, p.stdout


def test_common_words_in_an_example_title_are_not_names(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    with open(os.path.join(ex, "brindle", "campaign.md")) as f:
        text = f.read().replace("# Brindle\n", "# The Road to Brindle\n")
    with open(os.path.join(ex, "brindle", "campaign.md"), "w") as f:
        f.write(text)
    d = str(tmp_path / "camp")
    campaign(d, "The tide turns. Road tolls double.", ["The tide tables are a state secret."])
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 0, p.stdout


def test_near_copy_truth_fails_without_printing_the_example(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, "A drowned city resurfaces each spring tide.",
             ["The old road was paved by giants and no one has repaired it since."])
    p = run(campaign_path, "example-overlap", d, "--examples", ex)
    assert p.returncode == 1
    assert "paved by giants" in p.stdout            # the campaign's own line, named
    assert "salt road" not in p.stdout              # the example's text never printed


def test_unrelated_truth_passes(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, "A drowned city resurfaces each spring tide.",
             ["The harbor chain was forged from a single anchor."])
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 0


def test_raw_log_and_gm_dir_are_not_scanned(campaign_path, tmp_path):
    # Play text and sealed state aren't scaffolded content; only the campaign files are checked.
    ex = examples(str(tmp_path))
    d = str(tmp_path / "camp")
    campaign(d, "A drowned city resurfaces each spring tide.", ["The tide tables are a state secret."])
    write(d, "log/raw/2026-01-01-abcdef12.md", "### Player\n\nCan I be called Osk?\n")
    write(d, ".gm/tables/hook.md", "- Osk returns.\n")
    assert run(campaign_path, "example-overlap", d, "--examples", ex).returncode == 0


def test_an_example_checked_against_itself_is_skipped(campaign_path, tmp_path):
    ex = examples(str(tmp_path))
    p = run(campaign_path, "example-overlap", os.path.join(ex, "brindle"), "--examples", ex)
    assert p.returncode == 0, p.stdout


def test_bundled_embervale_names_are_caught(campaign_path, tmp_path):
    # The #174 regression: a "new" campaign whose protagonist is embervale's Wren.
    d = str(tmp_path / "camp")
    campaign(d, "A courier town around the last sweet-water well for sixty miles.",
             ["The waystations keep their own calendar."],
             "# Wren Calloway\n\n- **Concept:** A courier.\n")
    p = run(campaign_path, "example-overlap", d)       # default: the plugin's own examples/
    assert p.returncode == 1
    assert '"Wren"' in p.stdout and "embervale" in p.stdout


def test_sheet_template_labels_are_not_names(campaign_path, tmp_path):
    # A sheet filled from the generic template shares its labels ("Notes / Inventory")
    # with embervale's sheet; format words are not names.
    d = str(tmp_path / "camp")
    tpl = os.path.join(os.path.dirname(EXAMPLES), "adapters", "generic", "sheet-template.md")
    with open(tpl) as f:
        sheet = f.read().replace("{{name}}", "Ilse Varga")
    campaign(d, "A drowned city resurfaces each spring tide.", ["The tide tables are a state secret."], sheet)
    p = run(campaign_path, "example-overlap", d)
    assert p.returncode == 0, p.stdout + p.stderr


def test_default_examples_dir_is_the_plugins_own(campaign_path, tmp_path):
    d = str(tmp_path / "camp")
    campaign(d, "A drowned city resurfaces each spring tide.", ["The tide tables are a state secret."])
    p = run(campaign_path, "example-overlap", d)
    assert p.returncode == 0, p.stdout + p.stderr
    assert os.path.isdir(os.path.join(EXAMPLES, "embervale"))


def test_missing_campaign_dir_errors(campaign_path, tmp_path):
    p = run(campaign_path, "example-overlap", str(tmp_path / "nope"))
    assert p.returncode != 0
    assert "campaign" in (p.stdout + p.stderr)
