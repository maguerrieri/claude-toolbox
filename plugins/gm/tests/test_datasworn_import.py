"""tools/datasworn-import and the starforged and sundered-isles content it generates.

The generated tree itself is checked against the pinned upstream by CI
(`datasworn-import --check`, which fetches it). These tests cover what runs
offline: the converter's rules on small synthetic Datasworn documents (a ruleset,
and an expansion of it), and properties of the checked-in output (every table
rolls, every table has golden ranges, the procedures point at real files).
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
SUNDERED = os.path.join(ADAPTERS, "sundered-isles")
FIXTURES = os.path.join(HERE, "fixtures", "oracles", "starforged")
SI_FIXTURES = os.path.join(HERE, "fixtures", "oracles", "sundered-isles")


def _load(name, path):
    loader = SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


imp = _load("datasworn_import", TOOL)
roll = _load("roll", os.path.join(PLUGIN, "bin", "roll"))


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


def test_oracle_path_rejects_other_rulesets():
    with pytest.raises(ValueError):
        imp.oracle_path("oracle_rollable:classic/action")


def test_convert_links():
    text = ("[Action](datasworn:oracle_rollable:starforged/core/action), "
            "[Derelict](datasworn:oracle_collection:starforged/derelict), "
            "[Strike](datasworn:move:starforged/combat/strike), "
            "[Vestige](datasworn:asset:starforged/path/vestige)")
    assert imp.convert_links(text) == ("Action (`oracles/action.md`), Derelict (`oracles/derelict/`), "
                                       "Strike, Vestige (path asset)")


def test_convert_links_rejects_unknown_link_types():
    with pytest.raises(ValueError):
        imp.convert_links("[x](datasworn:npc:starforged/x)")


def test_convert_links_rejects_leftover_templates():
    # an embedded table outside rules_text/entry_text must fail, not leak into a table
    with pytest.raises(ValueError, match="template"):
        imp.convert_links("Roll: {{table>move.oracle_rollable:starforged/suffer/endure_harm.endure_harm}}")


def test_two_tables_on_one_path_fail():
    doc = mini_doc()
    # a rollable at the shared-roll collection's own path would overwrite its combined table
    doc["oracles"]["character"]["contents"]["name"] = _table(
        "oracle_rollable:starforged/character/name", "Name", [_row(1, 10, "Ash")])
    with pytest.raises(ValueError, match="character/name.md"):
        imp.generate(doc)


def test_fixture_max_is_upstream_not_the_weight_sum():
    files = imp.generate(mini_doc())
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
    files = imp.generate(mini_doc())
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


def test_write_owns_only_marked_files(tmp_path):
    root = str(tmp_path)
    files = imp.generate(mini_doc())
    imp.write(root, files)
    hand = tmp_path / "adapters" / "starforged" / "rules" / "character-creation.md"
    hand.write_text("# hand-written\n")
    stale = tmp_path / "adapters" / "starforged" / "oracles" / "gone.md"
    stale.write_text(imp.GENERATED + "\n- [1] old\n")

    empty = tmp_path / "adapters" / "starforged" / "frames"
    empty.mkdir()                   # a hand-made dir, still empty
    (tmp_path / "tests" / "fixtures" / "oracles" / "starforged" / ".DS_Store").write_bytes(b"\x00\x05\x16\x07\xff")

    imp.write(root, files)          # regenerating removes stale output, keeps hand-written files
    assert hand.read_text() == "# hand-written\n"
    assert not stale.exists()
    assert empty.is_dir()
    imp.check(root, files)          # in sync (and the .DS_Store isn't ours): returns quietly

    (tmp_path / "adapters" / "starforged" / "oracles" / "action.md").write_text(imp.GENERATED + "\n- [1] edited\n")
    with pytest.raises(SystemExit):
        imp.check(root, files)

    clash = dict(files)
    clash["adapters/starforged/rules/character-creation.md"] = imp.GENERATED + "\n"
    with pytest.raises(SystemExit, match="isn't generated"):
        imp.write(root, clash)


def test_load_rejects_an_unpinned_file(tmp_path):
    p = tmp_path / "starforged.json"
    p.write_text("{}")
    with pytest.raises(SystemExit, match="doesn't match the pin"):
        imp.load(str(p))
    with pytest.raises(SystemExit, match="doesn't match the pin of any package"):
        imp.load_all([str(p)])


# --- an expansion -------------------------------------------------------------

def mini_base():
    """mini_doc() with the collection and category ids an expansion refers to."""
    doc = mini_doc()
    for kind, section in [("oracle_collection", "oracles"), ("move_category", "moves"),
                          ("asset_collection", "assets")]:
        for key, node in doc[section].items():
            node["_id"] = f"{kind}:starforged/{key}"
    return doc


def mini_expansion():
    """An expansion of mini_base(): a table replaced at the same path and one at another
    path, a replaced collection (planet), a rewritten move, a cursed table pair, a new
    truth and a new card."""
    action = _table("oracle_rollable:sundered_isles/core/action", "Action", [_row(1, 10, "Plunder")],
                    replaces=["oracle_rollable:starforged/core/action"])
    given = _table("oracle_rollable:sundered_isles/character/name/given", "Given Name", [_row(1, 10, "Ana")],
                   replaces=["oracle_rollable:starforged/character/name/given_name"])
    look = _table("oracle_rollable:sundered_isles/ship/look", "Ship Look", [_row(1, 10, "Black sails")],
                  tags={"sundered_isles": {"cursed_by": "oracle_rollable:sundered_isles/ship/look_cursed"}})
    look_cursed = _table("oracle_rollable:sundered_isles/ship/look_cursed", "Cursed Ship Look",
                         [_row(1, 10, "Bone hull")], tags={"sundered_isles": {"curse_behavior": "replace_result"}})
    terrain = _table("oracle_rollable:sundered_isles/island/terrain", "Terrain", [_row(1, 10, "Jungle")])
    price = _table("move.oracle_rollable:sundered_isles/fate/pay_the_price.pay_the_price", "Pay the Price",
                   [_row(1, 10, "The tide turns against you.")])
    rank = {"roll": {"min": 1, "max": 10}, "text": "Kraken", "text2": "Epic", "text3": "It rises."}
    beasts = _table("oracle_rollable:sundered_isles/ship/beast", "Beast", [rank], oracle_type="table_text3",
                    column_labels={"text": "Name", "text2": "Rank", "text3": "Description"})
    flagship = {"_id": "asset:sundered_isles/command_vehicle/flagship", "name": "Flagship", "options": {},
                "controls": {"integrity": {"label": "integrity", "field_type": "condition_meter", "max": 5, "value": 5},
                             "supply": {"label": "supply (hold)", "field_type": "condition_meter", "max": 5, "value": 5}},
                "abilities": [{"text": "Name it from [Given](datasworn:oracle_rollable:sundered_isles/character/name/given).",
                               "enabled": True}]}
    return {
        "_id": "sundered_isles",
        "oracles": {
            "core": {"_id": "oracle_collection:sundered_isles/core", "name": "Core Oracles",
                     "replaces": ["oracle_collection:starforged/core"], "contents": {"action": action}},
            "character": {"_id": "oracle_collection:sundered_isles/character", "name": "Character Oracles",
                          "contents": {}, "collections": {"name": {
                              "_id": "oracle_collection:sundered_isles/character/name", "name": "Character Name",
                              "replaces": ["oracle_collection:starforged/character/name"],
                              "contents": {"given": given}}}},
            "ship": {"_id": "oracle_collection:sundered_isles/ship", "name": "Ship Oracles",
                     "contents": {"look": look, "look_cursed": look_cursed, "beast": beasts}},
            "island": {"_id": "oracle_collection:sundered_isles/island", "name": "Island Oracles",
                       "replaces": ["oracle_collection:starforged/planet"], "contents": {"terrain": terrain}},
        },
        "moves": {"fate": {"_id": "move_category:sundered_isles/fate", "name": "Fate Moves",
                           "enhances": ["move_category:starforged/fate"], "contents": {"pay_the_price": {
            "_id": "move:sundered_isles/fate/pay_the_price", "name": "Pay the Price", "roll_type": "no_roll",
            "replaces": ["move:starforged/fate/pay_the_price"],
            "text": "__When you suffer__, roll:\n\n{{table>move.oracle_rollable:sundered_isles/fate/pay_the_price.pay_the_price}}",
            "oracles": {"pay_the_price": price}}}}},
        "truths": {"sundering": {"_id": "truth:sundered_isles/sundering", "name": "Sundering", "dice": "1d10",
                                 "summary": "How did the isles break?",
                                 "factions": [{"text": "A tribe seeks the scattered."}],
                                 "options": [{"roll": {"min": 1, "max": 10}, "summary": "A war.",
                                              "description": "It ended.", "quest_starter": "Bring aid."}]}},
        "assets": {"command_vehicle": {"_id": "asset_collection:sundered_isles/command_vehicle",
                                       "name": "Command Vehicle Assets",
                                       "enhances": ["asset_collection:starforged/command_vehicle"],
                                       "contents": {"flagship": flagship}}},
        "rules": {},
    }


@pytest.fixture
def mini_pins(monkeypatch):
    """The real SHADOWS and ERRATA name tables the mini documents don't have."""
    monkeypatch.setitem(imp.SHADOWS, "sundered_isles", set())
    monkeypatch.setitem(imp.ERRATA, "sundered_isles", {})


def test_expansion_needs_its_ruleset():
    with pytest.raises(ValueError, match="base"):
        imp.generate(mini_expansion())
    with pytest.raises(ValueError, match="base"):
        imp.generate(mini_base(), mini_base())


def test_expansion_tables_replace_by_path(mini_pins):
    files = imp.generate(mini_expansion(), mini_base())
    o = "adapters/sundered-isles/oracles/"
    # a replacement wins at the replaced table's path, even when its own id maps elsewhere
    assert [e["entry"] for e in roll.parse_table(files[o + "action.md"])] == ["Plunder"]
    assert [e["entry"] for e in roll.parse_table(files[o + "character/name/given-name.md"])] == ["Ana"]
    assert o + "character/name/given.md" not in files
    # and links to it follow it there
    card = files["adapters/sundered-isles/rules/assets/sundered-isles/command-vehicle.md"]
    assert "Name it from Given (`oracles/character/name/given-name.md`)." in card
    # tables it doesn't replace stay the ruleset's: no file here
    assert o + "truths/cataclysm.md" not in files and o + "truths/cataclysm/cause.md" not in files
    # the fixture lands under the expansion's own name
    assert "tests/fixtures/oracles/sundered-isles/action.json" in files
    index = files["adapters/sundered-isles/rules/oracles.md"]
    assert "`oracles/character/name/given-name.md` — Given Name (in place of Starforged's Given Name)" in index


def test_a_replaced_collection_leaves_redirects(mini_pins):
    files = imp.generate(mini_expansion(), mini_base())
    o = "adapters/sundered-isles/oracles/"
    for path in ["planet/class.md", "planet/ice/feature.md"]:
        entries = roll.parse_table(files[o + path])
        assert [e["entry"] for e in entries] == ["Replaced in Sundered Isles: use Island Oracles (`oracles/island/`)."]
        assert files[o + path].startswith(imp.MARKER)
    # a replaced collection's other columns, and its combined shared-roll table, redirect too
    for path in ["character/name/family-name.md", "character/name.md"]:
        assert [e["entry"] for e in roll.parse_table(files[o + path])] == [
            "Replaced in Sundered Isles: use Character Name (`oracles/character/name/`)."]
    fx = json.loads(files["tests/fixtures/oracles/sundered-isles/planet/class.json"])
    assert fx["die"] is None and [r["max"] for r in fx["rows"]] == [1]
    # the replaced collection is left out of the ruleset part of the index
    index = files["adapters/sundered-isles/rules/oracles.md"]
    assert "planet/class.md" not in index and "`oracles/island/terrain.md` — Terrain" in index


def test_replacing_one_column_of_a_shared_roll_table_fails(mini_pins):
    exp = mini_expansion()
    del exp["oracles"]["character"]["collections"]["name"]["replaces"]
    with pytest.raises(ValueError, match="combined table would go stale"):
        imp.generate(exp, mini_base())


def test_an_unreplaced_shared_path_fails_unless_shadowed(mini_pins, monkeypatch):
    exp = mini_expansion()
    exp["truths"]["cataclysm"] = {"_id": "truth:sundered_isles/cataclysm", "name": "Cataclysm", "dice": "1d10",
                                  "options": [{"roll": {"min": 1, "max": 10}, "summary": "Ash.", "description": "Ash."}]}
    with pytest.raises(ValueError, match="SHADOWS"):
        imp.generate(exp, mini_base())
    monkeypatch.setitem(imp.SHADOWS, "sundered_isles", {"truths/cataclysm.md"})
    files = imp.generate(exp, mini_base())
    assert "Ash." in files["adapters/sundered-isles/oracles/truths/cataclysm.md"]
    # a listed shadow that no longer collides is stale
    monkeypatch.setitem(imp.SHADOWS, "sundered_isles", {"truths/cataclysm.md", "truths/gone.md"})
    with pytest.raises(ValueError, match="no table shares"):
        imp.generate(exp, mini_base())


def test_replaces_must_name_a_ruleset_id(mini_pins):
    exp = mini_expansion()
    exp["oracles"]["ship"]["contents"]["look"]["replaces"] = ["oracle_rollable:starforged/ship/look"]
    with pytest.raises(ValueError, match="doesn't have"):
        imp.generate(exp, mini_base())


def test_expansion_moves_are_merged_in_place(mini_pins):
    files = imp.generate(mini_expansion(), mini_base())
    moves = files["adapters/sundered-isles/rules/moves.md"]
    assert moves.count("### Pay the Price") == 1
    assert "*Sundered Isles version.* *Roll:* no roll" in moves
    assert "| 1–10 | The tide turns against you. |" in moves and "current situation worsens" not in moves
    assert "with the Sundered Isles versions of the 1 it replaces in their place" in moves
    assert "adapters/starforged/oracles/<path>" in moves      # the extends: note


def test_cursed_die_notes(mini_pins):
    files = imp.generate(mini_expansion(), mini_base())
    o = "adapters/sundered-isles/oracles/"
    assert "Cursed die: on a 10, read the same roll on `oracles/ship/look-cursed.md` instead." in files[o + "ship/look.md"]
    assert "The cursed version of `oracles/ship/look.md`." in files[o + "ship/look-cursed.md"]
    index = files["adapters/sundered-isles/rules/oracles.md"]
    assert "`oracles/ship/look.md` — Ship Look · cursed: `oracles/ship/look-cursed.md`" in index


def test_three_column_rows_label_each_column(mini_pins):
    files = imp.generate(mini_expansion(), mini_base())
    entries = roll.parse_table(files["adapters/sundered-isles/oracles/ship/beast.md"])
    assert entries[0]["entry"] == "Name: Kraken\nRank: Epic\nDescription: It rises."


def test_expansion_truths_assets_and_sheet(mini_pins):
    files = imp.generate(mini_expansion(), mini_base())
    a = "adapters/sundered-isles/"
    truths = files[a + "rules/truths.md"]
    assert "The 1 setting truths of the Sundered Isles" in truths
    assert "*How did the isles break?*" in truths and "- A tribe seeks the scattered." in truths
    index = files[a + "rules/assets.md"]
    assert "- Sundered Isles (`rules/assets/sundered-isles/command-vehicle.md`): Flagship." in index
    assert "- Starforged (`rules/assets/command-vehicle.md`): Starship." in index
    assert "- Starforged (`rules/assets/path.md`): Ace." in index        # a ruleset-only category
    assert a + "rules/assets/command-vehicle.md" not in files           # the ruleset's cards aren't copied
    sheet = files[a + "sheet-template.md"]
    assert "**Moniker:**" in sheet and "[ ] wounded" in sheet           # the ruleset's impacts
    # the ship tracks are alternatives, one line each
    assert "  - FLAGSHIP integrity [▰▰▰▰▰] 5/5 · supply (hold) [▰▰▰▰▰] 5/5" in sheet
    assert "  - SAILING SHIP integrity" in sheet
    # the ruleset's legacy-track text names its own setting, so it's left out
    assert "- Quests      [▱▱▱▱▱▱▱▱▱▱] 0/10\n" in sheet and "Swear vows" not in sheet
    for rel, text in files.items():
        if rel.endswith(".md"):
            assert text.startswith(imp.MARKER), rel


def test_new_expansion_moves_are_added_and_counted_apart(mini_pins):
    exp = mini_expansion()
    exp["moves"]["fate"]["contents"]["hoist_the_colors"] = {
        "_id": "move:sundered_isles/fate/hoist_the_colors", "name": "Hoist the Colors",
        "roll_type": "action_roll", "text": "__When you raise your flag__, roll +heart."}
    moves = imp.generate(exp, mini_base())["adapters/sundered-isles/rules/moves.md"]
    assert "versions of the 1 it replaces in their place" in moves and "and 1 new Sundered Isles moves" in moves
    fate = moves[moves.index("## Fate Moves"):]
    assert fate.index("### Pay the Price") < fate.index("### Hoist the Colors")
    assert "*Sundered Isles move.* *Roll:* action roll" in fate


def test_two_expansion_categories_can_enhance_one(mini_pins):
    exp = mini_expansion()
    exp["assets"]["boats"] = {"_id": "asset_collection:sundered_isles/boats", "name": "Boat Assets",
                              "enhances": ["asset_collection:starforged/command_vehicle"],
                              "contents": {"sloop": {"_id": "asset:sundered_isles/boats/sloop", "name": "Sloop",
                                                     "options": {}, "controls": {},
                                                     "abilities": [{"text": "Fast.", "enabled": True}]}}}
    index = imp.generate(exp, mini_base())["adapters/sundered-isles/rules/assets.md"]
    assert "(`rules/assets/sundered-isles/command-vehicle.md`): Flagship." in index
    assert "(`rules/assets/sundered-isles/boats.md`): Sloop." in index


def test_a_table_cant_take_two_paths(mini_pins):
    exp = mini_expansion()
    exp["oracles"]["character"]["collections"]["name"]["contents"]["given"]["replaces"].append(
        "oracle_rollable:starforged/character/name/family_name")
    with pytest.raises(ValueError, match="two paths"):
        imp.generate(exp, mini_base())


def test_a_shadowed_column_makes_its_combined_table_stale(mini_pins, monkeypatch):
    exp = mini_expansion()
    name = exp["oracles"]["character"]["collections"]["name"]
    del name["replaces"]
    given = name["contents"]["given"]
    del given["replaces"]
    given["_id"] = "oracle_rollable:sundered_isles/character/name/given_name"
    monkeypatch.setitem(imp.SHADOWS, "sundered_isles", {"character/name/given-name.md"})
    with pytest.raises(ValueError, match="combined table would go stale"):
        imp.generate(exp, mini_base())


def test_errata_restore_rows_and_fail_once_fixed(monkeypatch):
    monkeypatch.setitem(imp.SHADOWS, "sundered_isles", set())
    exp = mini_expansion()
    exp["oracles"]["island"]["contents"]["terrain"]["rows"] = [_row(1, 6, "Jungle")]
    monkeypatch.setitem(imp.ERRATA, "sundered_isles",
                        {"oracle_rollable:sundered_isles/island/terrain": [(7, 10, "Scrub")]})
    files = imp.generate(exp, mini_base())
    entries = roll.parse_table(files["adapters/sundered-isles/oracles/island/terrain.md"])
    assert [(e["weight"], e["entry"]) for e in entries] == [(6, "Jungle"), (4, "Scrub")]
    assert len(exp["oracles"]["island"]["contents"]["terrain"]["rows"]) == 1    # the input isn't changed
    with pytest.raises(ValueError, match="no longer applies"):
        imp.generate(mini_expansion(), mini_base())                             # upstream "fixed" it


def test_oracle_path_of_an_asset_table():
    assert imp.oracle_path("asset.ability.oracle_rollable:sundered_isles/companion/parrot.0.parrot_wisdom") \
        == "assets/parrot/parrot-wisdom.md"


@pytest.mark.skipif(not (os.environ.get("DATASWORN_STARFORGED_JSON") and os.environ.get("DATASWORN_SUNDERED_ISLES_JSON")),
                    reason="set DATASWORN_STARFORGED_JSON and DATASWORN_SUNDERED_ISLES_JSON to copies of "
                           "the pinned files (CI runs --check online)")
def test_checked_in_tree_matches_upstream():
    p = subprocess.run([TOOL, "--check", "--json", os.environ["DATASWORN_STARFORGED_JSON"],
                        os.environ["DATASWORN_SUNDERED_ISLES_JSON"]], capture_output=True, text=True)
    assert p.returncode == 0, p.stdout + p.stderr


# --- the checked-in output ----------------------------------------------------

def _tables(adapter_dir):
    return sorted(glob.glob(os.path.join(adapter_dir, "oracles", "**", "*.md"), recursive=True))


def test_every_starforged_table_has_golden_ranges():
    tables = {os.path.relpath(p, os.path.join(STARFORGED, "oracles"))[:-3] for p in _tables(STARFORGED)}
    fixtures = {os.path.relpath(p, FIXTURES)[:-5]
                for p in glob.glob(os.path.join(FIXTURES, "**", "*.json"), recursive=True)}
    assert tables == fixtures


def test_starforged_ships_the_full_set():
    # counts from the pinned upstream: 267 tables + 2 shared-roll tables + 14 truths
    assert len(_tables(STARFORGED)) == 283
    assert len(glob.glob(os.path.join(STARFORGED, "oracles", "truths", "*.md"))) == 14
    moves = open(os.path.join(STARFORGED, "rules", "moves.md")).read()
    assert moves.count("\n### ") == 56
    cards = "".join(open(p).read() for p in glob.glob(os.path.join(STARFORGED, "rules", "assets", "*.md")))
    assert cards.count("\n## ") == 87


def test_every_sundered_isles_table_has_golden_ranges():
    tables = {os.path.relpath(p, os.path.join(SUNDERED, "oracles"))[:-3] for p in _tables(SUNDERED)}
    fixtures = {os.path.relpath(p, SI_FIXTURES)[:-5]
                for p in glob.glob(os.path.join(SI_FIXTURES, "**", "*.json"), recursive=True)}
    assert tables == fixtures


def test_sundered_isles_ships_the_full_set():
    # counts from the pinned upstream: 265 oracle tables, 3 move tables, 1 asset table,
    # 12 shared-roll tables and 11 truths, plus 14 redirects for replaced Starforged tables
    tables = _tables(SUNDERED)
    redirects = [p for p in tables if "\n# Replaced: " in open(p).read()]
    assert (len(tables), len(redirects)) == (306, 14)
    assert len(glob.glob(os.path.join(SUNDERED, "oracles", "truths", "*.md"))) == 11
    moves = open(os.path.join(SUNDERED, "rules", "moves.md")).read()
    assert moves.count("\n### ") == 56 and moves.count("*Sundered Isles version.*") == 8
    cards = "".join(open(p).read() for p in glob.glob(os.path.join(SUNDERED, "rules", "assets", "sundered-isles", "*.md")))
    assert cards.count("\n## ") == 60
    # the erratum: Highlands landmarks run the full d100
    highlands = roll.parse_table(open(os.path.join(SUNDERED, "oracles", "overland", "region-landmarks", "highlands.md")).read())
    assert sum(e["weight"] for e in highlands) == 100 and highlands[-1]["entry"] == "Winding footpath"


def test_sundered_isles_extends_starforged():
    manifest = open(os.path.join(SUNDERED, "adapter.md")).read()
    assert "\nextends: starforged\n" in manifest
    # every launch file new-campaign looks for is its own, so none of Starforged's leaks in
    for f in ["campaign-launch.md", "truths.md", "character-creation.md", "sector-creation.md"]:
        assert os.path.isfile(os.path.join(SUNDERED, "rules", f)), f


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
