"""tools/datasworn-import and the starforged content it generates.

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
FIXTURES = os.path.join(HERE, "fixtures", "oracles", "starforged")


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
        "assets": {"path": {"name": "Path Assets", "description": "Pick at least two.", "contents": {"ace": {
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
    assert "[ ] wounded" in files["adapters/starforged/sheet-template.md"]
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

    imp.write(root, files)          # regenerating removes stale output, keeps hand-written files
    assert hand.read_text() == "# hand-written\n"
    assert not stale.exists()
    imp.check(root, files)          # in sync: returns quietly

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


@pytest.mark.skipif(not os.environ.get("DATASWORN_STARFORGED_JSON"),
                    reason="set DATASWORN_STARFORGED_JSON to a copy of the pinned file (CI runs --check online)")
def test_checked_in_tree_matches_upstream():
    p = subprocess.run([TOOL, "--check", "--json", os.environ["DATASWORN_STARFORGED_JSON"]],
                       capture_output=True, text=True)
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
