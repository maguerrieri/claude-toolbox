"""tools/datasworn-import and the starforged and ironsworn content it generates.

The generated tree itself is checked against the pinned upstream by CI
(`datasworn-import --check`, which fetches it). These tests cover what runs
offline: the converter's rules on a small synthetic Datasworn document, and
properties of the checked-in output (every table rolls, every table has golden
ranges, the procedures point at real files).
"""
import glob
import importlib.util
import json
import os
import subprocess
from importlib.machinery import SourceFileLoader

import pytest

HERE = os.path.dirname(__file__)
PLUGIN = os.path.abspath(os.path.join(HERE, ".."))
TOOL = os.path.join(PLUGIN, "tools", "datasworn-import")
ADAPTERS = os.path.join(PLUGIN, "adapters")
STARFORGED = os.path.join(ADAPTERS, "starforged")
IRONSWORN = os.path.join(ADAPTERS, "ironsworn")
FIXTURE_ROOT = os.path.join(HERE, "fixtures", "oracles")


def _load(name, path):
    loader = SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


imp = _load("datasworn_import", TOOL)
roll = _load("roll", os.path.join(PLUGIN, "bin", "roll"))
SF = imp.RULESETS["starforged"]
CLASSIC = imp.RULESETS["classic"]


# --- a minimal Datasworn document -------------------------------------------

def _row(lo, hi, text, **kw):
    return {"roll": {"min": lo, "max": hi}, "text": text, **kw}


def _table(ref, name, rows, dice="1d10", **kw):
    return {"_id": ref, "name": name, "type": "oracle_rollable", "oracle_type": "table_text",
            "dice": dice, "rows": rows, **kw}


def mini_doc():
    action = _table("oracle_rollable:starforged/core/action", "Action",
                    [_row(1, 5, "Seize"), _row(6, 10, "Guard")])
    klass = _table("oracle_rollable:starforged/planet/class", "Class", [
        _row(1, 4, "[Desert World](datasworn:oracle_collection:starforged/planet/desert)"),
        _row(5, 10, "Ice World", oracle_rolls=[{"oracle": "oracle_rollable:starforged/planet/ice/feature",
                                                "number_of_rolls": 2}]),
    ])
    feature = _table("oracle_rollable:starforged/planet/ice/feature", "Feature",
                     [_row(1, 10, "Frozen sea")])
    given = _table("oracle_rollable:starforged/character/name/given_name", "Given Name",
                   [_row(1, 6, "Akim"), _row(7, 10, "Alex")], oracle_type="column_text")
    family = _table("oracle_rollable:starforged/character/name/family_name", "Family Name",
                    [_row(1, 6, "Kuzmin"), _row(7, 10, "Durant")], oracle_type="column_text")
    price = _table("move.oracle_rollable:starforged/fate/pay_the_price.pay_the_price", "Pay the Price",
                   [_row(1, 10, "The current situation worsens.")])
    cause = _table("truth.option.oracle_rollable:starforged/cataclysm.0.cause", "Cause",
                   [_row(1, 10, "Dark matter decay")])
    return {
        "oracles": {
            "core": {"name": "Core Oracles", "contents": {"action": action}},
            "planet": {"name": "Planet Oracles", "contents": {"class": klass},
                       "collections": {"ice": {"name": "Ice World", "contents": {"feature": feature}}}},
            "character": {"name": "Character Oracles", "contents": {}, "collections": {
                "name": {"_id": "oracle_collection:starforged/character/name", "name": "Character Name",
                         "oracle_type": "table_shared_rolls", "summary": "Roll once for both.",
                         "contents": {"given_name": given, "family_name": family}}}},
        },
        "moves": {"fate": {"name": "Fate Moves", "contents": {"pay_the_price": {
            "_id": "move:starforged/fate/pay_the_price", "name": "Pay the Price", "roll_type": "no_roll",
            "text": "__When you suffer__, [Face Danger](datasworn:move:starforged/adventure/face_danger) "
                    "or roll:\n\n{{table>move.oracle_rollable:starforged/fate/pay_the_price.pay_the_price}}",
            "oracles": {"pay_the_price": price}}}}},
        "truths": {"cataclysm": {"_id": "truth:starforged/cataclysm", "name": "Cataclysm", "dice": "1d10",
                                 "your_character": "Are you a [Vestige](datasworn:asset:starforged/path/vestige)?",
                                 "options": [
                                     {"roll": {"min": 1, "max": 3}, "summary": "A plague.",
                                      "description": "It came.\n\n{{table>truth.option.oracle_rollable:starforged/cataclysm.0.cause}}",
                                      "quest_starter": "Find the last star.", "oracles": {"cause": cause}},
                                     {"roll": {"min": 4, "max": 10}, "summary": "A war.",
                                      "description": "We fled.", "quest_starter": "Face the foe."}]}},
        "assets": {"command_vehicle": {"name": "Command Vehicle Assets", "contents": {"starship": {
            "_id": "asset:starforged/command_vehicle/starship", "name": "Starship", "options": {},
            "controls": {"integrity": {"label": "integrity", "field_type": "condition_meter",
                                       "max": 5, "value": 5}},
            "abilities": [{"text": "Your ship.", "enabled": True}]}}},
                   "path": {"name": "Path Assets", "description": "Pick at least two.", "contents": {"ace": {
            "_id": "asset:starforged/path/ace", "name": "Ace", "options": {}, "controls": {},
            "abilities": [{"text": "When you [Face Danger](datasworn:move:starforged/adventure/face_danger), add +1.",
                           "enabled": True},
                          {"text": "Take +1 momentum.", "enabled": False}]}}}},
        "rules": {"stats": {"edge": {"description": "Quick."}},
                  "condition_meters": {"health": {"label": "health", "max": 5, "value": 5}},
                  "impacts": {"misfortunes": {"label": "misfortunes",
                                              "contents": {"wounded": {"label": "wounded"}}}},
                  "special_tracks": {"quests_legacy": {"label": "quests", "description": "Swear vows."}}},
    }


# --- the converter ------------------------------------------------------------

@pytest.mark.parametrize("ref,path", [
    ("oracle_rollable:starforged/core/action", "action.md"),
    ("oracle_rollable:starforged/planet/desert/settlements/terminus", "planet/desert/settlements/terminus.md"),
    ("oracle_rollable:starforged/campaign_launch/background_assets", "campaign-launch/background-assets.md"),
    ("move.oracle_rollable:starforged/fate/pay_the_price.pay_the_price", "pay-the-price.md"),
    ("move.oracle_rollable:starforged/suffer/endure_harm.endure_harm", "moves/endure-harm.md"),
    ("move.oracle_rollable:starforged/fate/ask_the_oracle.likely", "moves/ask-the-oracle/likely.md"),
    ("truth.option.oracle_rollable:starforged/cataclysm.0.sun_plague_cause", "truths/cataclysm/sun-plague-cause.md"),
    ("truth:starforged/cataclysm", "truths/cataclysm.md"),
])
def test_oracle_path(ref, path):
    assert imp.oracle_path(ref) == path


@pytest.mark.parametrize("ref,path", [
    ("oracle_rollable:classic/action_and_theme/action", "action.md"),
    ("oracle_rollable:classic/name/ironlander/a", "name/ironlander/a.md"),
    ("oracle_collection:classic/settlement/quick_name", "settlement/quick-name.md"),
    ("move.oracle_rollable:classic/fate/pay_the_price.pay_the_price", "pay-the-price.md"),
    ("truth:classic/old_world", "truths/old-world.md"),
])
def test_classic_oracle_path(ref, path):
    assert imp.oracle_path(ref) == path


def test_oracle_path_rejects_other_rulesets():
    with pytest.raises(ValueError):
        imp.oracle_path("oracle_rollable:sundered_isles/core/action")


def test_convert_links():
    text = ("[Action](datasworn:oracle_rollable:starforged/core/action), "
            "[Derelict](datasworn:oracle_collection:starforged/derelict), "
            "[Strike](datasworn:move:starforged/combat/strike), "
            "[Vestige](datasworn:asset:starforged/path/vestige)")
    assert imp.convert_links(text, SF) == ("Action (`oracles/action.md`), Derelict (`oracles/derelict/`), "
                                           "Strike, Vestige (path asset)")


def test_convert_links_classic_kinds():
    text = ("[Havens](datasworn:atlas_entry:classic/ironlands/havens), "
            "[raiders](datasworn:npc:classic/ironlanders/raider), "
            "[horrors](datasworn:npc_collection:classic/horrors), "
            "[Old World](datasworn:truth:classic/old_world), "
            "[combat moves](datasworn:move_category:classic/combat), "
            "[Check Your Gear](datasworn:move:delve/delve/check_your_gear)")
    assert imp.convert_links(text, CLASSIC) == ("Havens, raiders, horrors, Old World, combat moves, "
                                                "Check Your Gear (Delve move)")
    assert imp.convert_links("[Sail](datasworn:move:sundered_isles/x/sail)", CLASSIC) == "Sail (Sundered Isles move)"


def test_convert_links_rejects_other_rulesets_tables():
    # a table in another ruleset lives in another adapter, so its path here would be wrong
    with pytest.raises(ValueError, match="another ruleset"):
        imp.convert_links("[Action](datasworn:oracle_rollable:starforged/core/action)", CLASSIC)


def test_convert_links_rejects_unknown_link_types():
    with pytest.raises(ValueError):
        imp.convert_links("[x](datasworn:delve_site:starforged/x)", SF)


def test_convert_links_rejects_leftover_templates():
    # an embedded table outside rules_text/entry_text must fail, not leak into a table
    with pytest.raises(ValueError, match="template"):
        imp.convert_links("Roll: {{table>move.oracle_rollable:starforged/suffer/endure_harm.endure_harm}}", SF)


def test_two_tables_on_one_path_fail():
    doc = mini_doc()
    # a rollable at the shared-roll collection's own path would overwrite its combined table
    doc["oracles"]["character"]["contents"]["name"] = _table(
        "oracle_rollable:starforged/character/name", "Name", [_row(1, 10, "Ash")])
    with pytest.raises(ValueError, match="character/name.md"):
        imp.generate(doc, SF)


def test_fixture_max_is_upstream_not_the_weight_sum():
    files = imp.generate(mini_doc(), SF)
    fx = json.loads(files["tests/fixtures/oracles/starforged/character/name/given-name.json"])
    assert [r["max"] for r in fx["rows"]] == [6, 10]


def test_rows_must_tile_the_die():
    with pytest.raises(ValueError, match="tile"):
        imp.checked_rows([_row(1, 4, "a"), _row(6, 10, "b")], "1d10", "t")
    with pytest.raises(ValueError, match="die is"):
        imp.checked_rows([_row(1, 9, "a")], "1d10", "t")
    # a null roll is a result this column can't produce: skipped, not a gap
    rows = imp.checked_rows([_row(1, 10, "a"), {"roll": None, "text": "b"}], "1d10", "t")
    assert [r["text"] for r in rows] == ["a"]


def test_generate_mini_doc():
    files = imp.generate(mini_doc(), SF)
    o = "adapters/starforged/oracles/"
    assert {o + p for p in ["action.md", "planet/class.md", "planet/ice/feature.md",
                            "character/name/given-name.md", "character/name/family-name.md",
                            "character/name.md", "pay-the-price.md", "truths/cataclysm.md",
                            "truths/cataclysm/cause.md"]} <= set(files)

    # weights reproduce the ranges, links become paths, rolls the text doesn't name follow it
    entries = roll.parse_table(files[o + "planet/class.md"])
    assert [(e["weight"], e["entry"]) for e in entries] == [
        (4, "Desert World (`oracles/planet/desert/`)"),
        (6, "Ice World\n→ Roll `oracles/planet/ice/feature.md` ×2"),
    ]
    # a shared-roll collection also reads all its columns off one roll
    names = roll.parse_table(files[o + "character/name.md"])
    assert [e["entry"] for e in names] == ["Given Name: Akim · Family Name: Kuzmin",
                                           "Given Name: Alex · Family Name: Durant"]
    # truth options roll at their ranges and point at their sub-tables
    truth = roll.parse_table(files[o + "truths/cataclysm.md"])
    assert [e["weight"] for e in truth] == [3, 7]
    assert "→ Roll `oracles/truths/cataclysm/cause.md`." in truth[0]["entry"]
    assert truth[0]["entry"].endswith("Quest starter: Find the last star.")

    # each table's golden fixture matches what roll table reads from it
    fx = json.loads(files["tests/fixtures/oracles/starforged/planet/class.json"])
    assert fx["die"] == "1d10" and [r["max"] for r in fx["rows"]] == [4, 10]
    assert [r["result"] for r in fx["rows"]] == [e["entry"] for e in entries]

    moves = files["adapters/starforged/rules/moves.md"]
    assert "Roll `oracles/pay-the-price.md` (1d10):" in moves
    assert "| 1–10 | The current situation worsens. |" in moves
    assert "Face Danger or roll" in moves and "datasworn:" not in moves
    assets = files["adapters/starforged/rules/assets/path.md"]
    assert "- [x] When you Face Danger, add +1." in assets and "- [ ] Take +1 momentum." in assets
    assert "`rules/assets/path.md`" in files["adapters/starforged/rules/assets.md"]
    assert "Vestige (path asset)" in files["adapters/starforged/rules/truths.md"]
    sheet = files["adapters/starforged/sheet-template.md"]
    assert "[ ] wounded" in sheet and "- STARSHIP integrity [▰▰▰▰▰] 5/5" in sheet
    for rel, text in files.items():
        if rel.endswith(".md"):
            assert text.startswith(imp.MARKER), rel


def mini_classic():
    src = {"license": imp.CC_BY_NC_SA}
    action = _table("oracle_rollable:classic/action_and_theme/action", "Action",
                    [_row(1, 10, "Scheme")], dice="1d10")
    region = _table("oracle_rollable:classic/place/region", "Region", [_row(1, 10, "Havens")])
    harm = _table("move.oracle_rollable:classic/suffer/endure_harm.endure_harm", "Endure Harm",
                  [_row(1, 10, "You are battered but still standing.")])
    return {
        "oracles": {"action_and_theme": {"name": "Action and Theme Oracles", "contents": {"action": action}},
                    "place": {"name": "Place Oracles", "contents": {"region": region}}},
        "moves": {"suffer": {"name": "Suffer Moves", "contents": {"endure_harm": {
            "_id": "move:classic/suffer/endure_harm", "name": "Endure Harm", "roll_type": "action_roll",
            "text": "Roll +iron.\n\n{{table>move.oracle_rollable:classic/suffer/endure_harm.endure_harm}}",
            "oracles": {"endure_harm": harm}}}},
                  "relationship": {"name": "Relationship Moves", "contents": {"write_your_epilogue": {
            "_id": "move:classic/relationship/write_your_epilogue", "name": "Write Your Epilogue",
            "roll_type": "special_track", "text": "When you retire..."}}}},
        "truths": {"iron": {"_id": "truth:classic/iron", "name": "Iron", "dice": "1d10", "_source": src,
                            "options": [{"roll": {"min": 1, "max": 5}, "description": "Black iron.",
                                         "quest_starter": "Find the caravan."},
                                        {"roll": {"min": 6, "max": 10}, "description": "Rare iron."}]},
                   # as upstream has it: the second option repeats the third's range (ERRATA)
                   "mysticism": {"_id": "truth:classic/mysticism", "name": "Mysticism", "dice": "1d100",
                                 "options": [{"roll": {"min": lo, "max": hi}, "description": d}
                                             for lo, hi, d in [(1, 33, "Lost."), (68, 100, "Rare."),
                                                               (68, 100, "Everywhere.")]]}},
        "assets": {"companion": {"name": "Companion Assets", "contents": {"hawk": {
            "_id": "asset:classic/companion/hawk", "name": "Hawk", "requirement": "It is aloft.",
            "options": {"name": {"label": "name", "field_type": "text"}},
            "controls": {"health": {"label": "health", "field_type": "condition_meter", "max": 3, "value": 3}},
            "abilities": [{"name": "Far-seeing", "text": "Add +1.", "enabled": False}]}}},
                   "combat_talent": {"name": "Combat Talent Assets", "contents": {"ironclad": {
            "_id": "asset:classic/combat_talent/ironclad", "name": "Ironclad", "options": {},
            "controls": {"equipped": {"label": "equipped", "field_type": "select_enhancement", "choices": {
                "light": {"label": "lightly armored"}, "war": {"label": "geared for war"}}}},
            "abilities": [{"text": "When you [Check Your Gear](datasworn:move:delve/delve/check_your_gear), "
                                   "add +1.", "enabled": True}]}}}},
        "npcs": {"beasts": {"name": "Beasts", "description": "Unknown in the [Old World](datasworn:truth:classic/old_world).",
                            "contents": {"wyvern": {
            "_id": "npc:classic/beasts/wyvern", "name": "Wyvern", "nature": "Beast", "rank": 4, "_source": src,
            "features": ["Huge wings"], "drives": ["Feed"], "tactics": ["Swoop down"],
            "description": "It hunts the [Havens](datasworn:atlas_entry:classic/ironlands/havens).",
            "quest_starter": "Tame one.", "your_truth": "Where do they die?"}}}},
        "atlas": {"ironlands": {"_id": "atlas_collection:classic/ironlands", "name": "The Ironlands",
                                "summary": "A rugged peninsula.", "contents": {"havens": {
            "_id": "atlas_entry:classic/ironlands/havens", "name": "Havens", "summary": "Forests and rivers.",
            "features": ["Walled settlements", "[Raiders](datasworn:npc:classic/ironlanders/raider)"],
            "description": "A fresh start.", "quest_starter": "Unseat the cruel leader.", "_source": src}}}},
        "rules": {"stats": {"iron": {"description": "Strength."}},
                  "condition_meters": {"supply": {"label": "supply", "max": 5, "value": 5, "shared": True}},
                  "impacts": {"banes": {"label": "banes", "contents": {"maimed": {"label": "maimed"}}}},
                  "special_tracks": {"bonds": {"label": "bonds", "description": "Forge a Bond."}}},
    }


def test_generate_mini_classic():
    files = imp.generate(mini_classic(), CLASSIC)
    a = "adapters/ironsworn/"
    assert {a + p for p in ["oracles/action.md", "oracles/moves/endure-harm.md", "oracles/truths/iron.md",
                            "rules/moves.md", "rules/truths.md", "rules/foes.md", "rules/regions.md",
                            "rules/assets/companion.md", "sheet-template.md"]} <= set(files)
    assert "tests/fixtures/oracles/ironsworn/truths/iron.json" in files
    # truth options with no summary: a range heading, then the truth and its quest starter
    truths = files[a + "rules/truths.md"]
    assert "### 1–5\n\nBlack iron.\n\n*Quest starter:* Find the caravan." in truths
    truth = roll.parse_table(files[a + "oracles/truths/iron.md"])
    assert [(e["weight"], e["entry"]) for e in truth] == [(5, "Black iron.\nQuest starter: Find the caravan."),
                                                         (5, "Rare iron.")]
    mysticism = roll.parse_table(files[a + "oracles/truths/mysticism.md"])
    assert [(e["weight"], e["entry"]) for e in mysticism] == [(33, "Lost."), (34, "Rare."), (33, "Everywhere.")]
    moves = files[a + "rules/moves.md"]
    assert "# Ironsworn Moves" in moves and "| 1–10 | You are battered but still standing. |" in moves
    assert "*Roll:* progress roll on your bonds track" in moves
    cards = files[a + "rules/assets/companion.md"]
    assert "- [ ] **Far-seeing:** Add +1." in cards and "*Track:* health meter: starts at 3, max 3" in cards
    talent = files[a + "rules/assets/combat-talent.md"]
    assert "*Choose:* equipped: lightly armored / geared for war" in talent
    assert "Check Your Gear (Delve move), add +1." in talent
    foes = files[a + "rules/foes.md"]
    assert "*Nature:* Beast · *Rank:* extreme" in foes and "*Features:* Huge wings." in foes
    assert "Unknown in the Old World." in foes and "It hunts the Havens." in foes
    assert "*Your truth:* Where do they die?" in foes
    regions = files[a + "rules/regions.md"]
    assert "## Havens" in regions and "*Features:* Walled settlements; Raiders." in regions
    sheet = files[a + "sheet-template.md"]
    assert "- Supply   [▰▰▰▰▰] 5/5  (shared with your allies)" in sheet
    assert "- *banes:* [ ] maimed" in sheet and "**Bonds** (a progress track" in sheet
    for rel, text in files.items():
        assert "datasworn:" not in text, rel


def test_classic_licenses_are_checked():
    doc = mini_classic()
    doc["npcs"]["beasts"]["contents"]["wyvern"]["_source"] = {"license": imp.CC_BY}
    with pytest.raises(ValueError, match="npcs"):
        imp.generate(doc, CLASSIC)
    # untagged content (like the sheet's rules) falls under the file's own license
    doc = mini_classic()
    doc["license"] = imp.CC_BY_NC_SA
    with pytest.raises(ValueError, match="classic oracles: licensed"):
        imp.generate(doc, CLASSIC)


@pytest.mark.parametrize("adapter", ["starforged", "ironsworn"])
def test_sheet_points_at_the_momentum_step(adapter):
    # the generated sheet names a step of the hand-written procedure, which --check can't see
    import re
    sheet = open(os.path.join(ADAPTERS, adapter, "sheet-template.md")).read()
    step = re.search(r"`rules/character-creation\.md`, step (\d+)", sheet).group(1)
    proc = open(os.path.join(ADAPTERS, adapter, "rules", "character-creation.md")).read()
    section = re.search(rf"^## {step}\. .*?(?=^## |\Z)", proc, re.M | re.S).group(0)
    assert "momentum" in section.lower()


def test_errata_fix_the_value_they_name():
    data = {"truths": {"mysticism": {"options": [{}, {"roll": {"min": 68, "max": 100}}]}}}
    fixed = imp.apply_errata(data, CLASSIC)
    assert fixed["truths"]["mysticism"]["options"][1]["roll"] == {"min": 34, "max": 67}
    assert data["truths"]["mysticism"]["options"][1]["roll"] == {"min": 68, "max": 100}   # a copy
    data["truths"]["mysticism"]["options"][1]["roll"] = {"min": 34, "max": 67}            # fixed upstream
    with pytest.raises(ValueError, match="drop the erratum"):
        imp.apply_errata(data, CLASSIC)
    with pytest.raises(ValueError, match="no such value"):
        imp.apply_errata({"truths": {}}, CLASSIC)


def test_generated_text_never_leaks_a_datasworn_link():
    doc = mini_classic()
    doc["npcs"]["beasts"]["contents"]["wyvern"]["nature"] = "[Beast](datasworn:npc_collection:classic/beasts)"
    with pytest.raises(ValueError, match="unconverted"):
        imp.generate(doc, CLASSIC)


def test_write_owns_only_marked_files(tmp_path):
    root = str(tmp_path)
    files = imp.generate(mini_doc(), SF)
    imp.write(root, files, SF)
    hand = tmp_path / "adapters" / "starforged" / "rules" / "character-creation.md"
    hand.write_text("# hand-written\n")
    stale = tmp_path / "adapters" / "starforged" / "oracles" / "gone.md"
    stale.write_text(imp.GENERATED + "\n- [1] old\n")

    empty = tmp_path / "adapters" / "starforged" / "frames"
    empty.mkdir()                   # a hand-made dir, still empty
    (tmp_path / "tests" / "fixtures" / "oracles" / "starforged" / ".DS_Store").write_bytes(b"\x00\x05\x16\x07\xff")

    imp.write(root, files, SF)      # regenerating removes stale output, keeps hand-written files
    assert hand.read_text() == "# hand-written\n"
    assert not stale.exists()
    assert empty.is_dir()
    assert imp.check(root, files, SF) == []    # in sync (and the .DS_Store isn't ours)

    (tmp_path / "adapters" / "starforged" / "oracles" / "action.md").write_text(imp.GENERATED + "\n- [1] edited\n")
    assert imp.check(root, files, SF) == ["differs   adapters/starforged/oracles/action.md"]

    clash = dict(files)
    clash["adapters/starforged/rules/character-creation.md"] = imp.GENERATED + "\n"
    with pytest.raises(SystemExit, match="isn't generated"):
        imp.write(root, clash, SF)


def test_load_rejects_an_unpinned_file(tmp_path):
    p = tmp_path / "starforged.json"
    p.write_text("{}")
    with pytest.raises(SystemExit, match="doesn't match the pin"):
        imp.load(str(p), SF)


def test_json_needs_a_ruleset():
    p = subprocess.run([TOOL, "--check", "--json", "x.json"], capture_output=True, text=True)
    assert p.returncode == 2 and "--json needs --ruleset" in p.stderr


@pytest.mark.parametrize("ruleset", sorted(imp.RULESETS))
def test_checked_in_tree_matches_upstream(ruleset):
    env = f"DATASWORN_{ruleset.upper()}_JSON"
    if not os.environ.get(env):
        pytest.skip(f"set {env} to a copy of the pinned file (CI runs --check online)")
    p = subprocess.run([TOOL, "--check", "--ruleset", ruleset, "--json", os.environ[env]],
                       capture_output=True, text=True)
    assert p.returncode == 0, p.stdout + p.stderr


# --- the checked-in output ----------------------------------------------------

def _tables(adapter_dir):
    return sorted(glob.glob(os.path.join(adapter_dir, "oracles", "**", "*.md"), recursive=True))


@pytest.mark.parametrize("adapter", ["starforged", "ironsworn"])
def test_every_generated_table_has_golden_ranges(adapter):
    adapter_dir, fixtures = os.path.join(ADAPTERS, adapter), os.path.join(FIXTURE_ROOT, adapter)
    tables = {os.path.relpath(p, os.path.join(adapter_dir, "oracles"))[:-3] for p in _tables(adapter_dir)}
    fixtures = {os.path.relpath(p, fixtures)[:-5]
                for p in glob.glob(os.path.join(fixtures, "**", "*.json"), recursive=True)}
    assert tables == fixtures


def test_starforged_ships_the_full_set():
    # counts from the pinned upstream: 267 tables + 2 shared-roll tables + 14 truths
    assert len(_tables(STARFORGED)) == 283
    assert len(glob.glob(os.path.join(STARFORGED, "oracles", "truths", "*.md"))) == 14
    moves = open(os.path.join(STARFORGED, "rules", "moves.md")).read()
    assert moves.count("\n### ") == 56
    cards = "".join(open(p).read() for p in glob.glob(os.path.join(STARFORGED, "rules", "assets", "*.md")))
    assert cards.count("\n## ") == 87


def test_ironsworn_ships_the_full_set():
    # counts from the pinned upstream: 30 tables + 8 move tables + 2 shared-roll tables + 11 truths
    assert len(_tables(IRONSWORN)) == 51
    assert len(glob.glob(os.path.join(IRONSWORN, "oracles", "truths", "*.md"))) == 11
    rules = os.path.join(IRONSWORN, "rules")
    assert open(os.path.join(rules, "moves.md")).read().count("\n### ") == 35
    cards = "".join(open(p).read() for p in glob.glob(os.path.join(rules, "assets", "*.md")))
    assert cards.count("\n## ") == 78
    assert open(os.path.join(rules, "foes.md")).read().count("\n### ") == 29
    assert open(os.path.join(rules, "regions.md")).read().count("\n## ") == 9
    # every file in the adapter is generated, apart from the hand-written ones SOURCE.md names
    hand = {"adapter.md", "SOURCE.md", "rules/campaign-launch.md", "rules/character-creation.md"}
    for p in glob.glob(os.path.join(IRONSWORN, "**", "*.md"), recursive=True):
        rel = os.path.relpath(p, IRONSWORN)
        if rel not in hand and not rel.startswith("frames/"):
            assert open(p).read().startswith(imp.MARKER), rel


@pytest.mark.parametrize("table", [p for d in sorted(glob.glob(os.path.join(ADAPTERS, "*")))
                                   for p in _tables(d)],
                         ids=lambda p: os.path.relpath(p, ADAPTERS))
def test_every_table_rolls(table):
    r = roll.roll_table(table, seed=7)
    assert r["n"] == 1 and r["picks"][0].strip()


def test_roll_table_cli_reads_a_nested_table(roll_path):
    p = subprocess.run([roll_path, "table", os.path.join(STARFORGED, "oracles", "planet", "class.md"),
                        "--seed", "3", "--json"], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout)["total"] == 100
