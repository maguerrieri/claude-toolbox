"""Migration parity test for MD oracle tables.

These fixtures are the *golden reference* for migration parity, not live adapter data.
Each is the original JSON oracle as it existed before commit 485eed1 (migrated to MD).
A weight typo or row-ordering mistake in any live .md file will fail this test.
"""
import glob
import importlib.util
import json
import os

import pytest

HERE = os.path.dirname(__file__)
FIXTURES_DIR = os.path.abspath(os.path.join(HERE, "fixtures", "oracles"))
ADAPTERS_DIR = os.path.abspath(os.path.join(HERE, "..", "adapters"))
ROLL_PATH = os.path.abspath(os.path.join(HERE, "..", "bin", "roll"))


def _load_parse_table():
    from importlib.machinery import SourceFileLoader
    loader = SourceFileLoader("roll", ROLL_PATH)
    spec = importlib.util.spec_from_loader("roll", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod.parse_table


parse_table = _load_parse_table()


def _collect_params():
    params = []
    for json_path in sorted(glob.glob(os.path.join(FIXTURES_DIR, "*", "*.json"))):
        adapter = os.path.basename(os.path.dirname(json_path))
        name = os.path.splitext(os.path.basename(json_path))[0]
        md_path = os.path.join(ADAPTERS_DIR, adapter, "oracles", name + ".md")
        params.append(pytest.param(json_path, md_path, id=f"{adapter}/{name}"))
    return params


@pytest.mark.parametrize("json_path,md_path", _collect_params())
def test_oracle_parity(json_path, md_path):
    with open(json_path) as fh:
        fixture = json.load(fh)
    with open(md_path) as fh:
        md_text = fh.read()

    rows = fixture["rows"]
    die_max = rows[-1]["max"]

    # Build face→result from JSON: first row whose max >= face.
    json_map = {}
    for face in range(1, die_max + 1):
        for row in rows:
            if face <= row["max"]:
                json_map[face] = row["result"]
                break

    # Build face→result from the live MD via parse_table.
    entries = parse_table(md_text)
    total = sum(e["weight"] for e in entries)
    assert total == die_max, (
        f"{md_path}: MD total weight {total} != JSON die_max {die_max}"
    )
    md_map = {}
    acc = 0
    for e in entries:
        for face in range(acc + 1, acc + e["weight"] + 1):
            md_map[face] = e["entry"]
        acc += e["weight"]

    for face in range(1, die_max + 1):
        assert md_map.get(face) == json_map.get(face), (
            f"{md_path}: face {face}: MD gives {md_map.get(face)!r}, "
            f"JSON gives {json_map.get(face)!r}"
        )
