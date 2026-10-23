"""The data /gm:oracle rolls (commands/oracle.md; adapter-contract: "The yes/no and
spark rules").

Every playable adapter states a yes/no rule along its extends: chain, every table
that rule names exists in the chain and rolls, and the chain has the action + theme
pair the spark rule rolls. Ironsworn's Ask the Oracle fixtures are checked against
the pinned Datasworn file when DATASWORN_CLASSIC_JSON points at a copy of it.
"""
import glob
import hashlib
import importlib.util
import json
import os
import re
import subprocess
from importlib.machinery import SourceFileLoader

import pytest

HERE = os.path.dirname(__file__)
ADAPTERS = os.path.abspath(os.path.join(HERE, "..", "adapters"))
FIXTURES = os.path.abspath(os.path.join(HERE, "fixtures", "oracles"))

_loader = SourceFileLoader("roll", os.path.abspath(os.path.join(HERE, "..", "bin", "roll")))
_roll = importlib.util.module_from_spec(importlib.util.spec_from_loader("roll", _loader))
_loader.exec_module(_roll)
parse_table = _roll.parse_table

# A top-level bullet whose bold label, or the parenthetical right after it, says yes/no:
# `- **Yes/No question.** …`, `- **Ask the Oracle** (yes/no): …`.
RULE_BULLET = re.compile(r"^- \*\*([^*\n]+)\*\*[ \t]*(\([^)\n]*\))?")
TABLE_REF = re.compile(r"oracles/([\w./-]+\.md)")
ASK_THE_ORACLE = ["almost-certain", "likely", "fifty-fifty", "unlikely", "small-chance"]
YES_PERCENT = {"almost-certain": 90, "likely": 75, "fifty-fifty": 50, "unlikely": 25, "small-chance": 10}

# The pin tools/datasworn-import uses for starforged, on the classic (Ironsworn) file.
CLASSIC_SHA256 = "7c669d602cf05576d74a966d3eac0657bc55ddbdab2829507362f00004ef52fc"


def _frontmatter(adapter_dir):
    text = open(os.path.join(adapter_dir, "adapter.md")).read()
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    fm = {}
    for line in (m.group(1).splitlines() if m else []):
        if ":" in line:
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip()
    return fm


def _chain(name):
    """The adapter's dir and its extends: ancestors, child first."""
    chain, d = [], os.path.join(ADAPTERS, name)
    while True:
        chain.append(d)
        parent = _frontmatter(d).get("extends")
        if not parent:
            return chain
        d = os.path.join(ADAPTERS, parent)


def _playable():
    return [os.path.basename(d) for d in sorted(glob.glob(os.path.join(ADAPTERS, "*")))
            if os.path.isfile(os.path.join(d, "adapter.md"))
            and _frontmatter(d).get("abstract") != "true"]


def _yes_no_rule(chain):
    """The nearest yes/no rule along the chain: the bullet plus its indented lines."""
    for d in chain:
        lines = open(os.path.join(d, "adapter.md")).read().splitlines()
        for i, line in enumerate(lines):
            m = RULE_BULLET.match(line)
            if m and "yes/no" in (m.group(1) + (m.group(2) or "")).lower():
                block = [line]
                for nxt in lines[i + 1:]:
                    if not nxt.startswith((" ", "\t")):
                        break
                    block.append(nxt)
                return "\n".join(block)
    return None


def _resolve(chain, ref):
    for d in chain:
        p = os.path.join(d, "oracles", ref)
        if os.path.isfile(p):
            return p
    return None


def _weights(table):
    """{entry text: weight} for a table, via bin/roll's own parser."""
    out = {}
    for e in parse_table(open(table).read()):
        out[e["entry"]] = out.get(e["entry"], 0) + e["weight"]
    return out


EXPECTED = {
    "generic": ["yes-no.md"],
    "ironsworn": [f"moves/ask-the-oracle/{o}.md" for o in ASK_THE_ORACLE],
    "starforged": [f"moves/ask-the-oracle/{o}.md" for o in ASK_THE_ORACLE],
}


def test_every_shipped_playable_adapter_is_covered():
    assert sorted(_playable()) == sorted(EXPECTED)


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_yes_no_rule_names_the_adapters_own_tables(name, roll_path):
    chain = _chain(name)
    rule = _yes_no_rule(chain)
    assert rule, f"{name}: no adapter in its extends: chain states a yes/no rule"
    refs = sorted(set(TABLE_REF.findall(rule)))
    assert refs == sorted(EXPECTED[name])
    for ref in refs:
        table = _resolve(chain, ref)
        assert table, f"{name}: yes/no rule names oracles/{ref}, which isn't in its chain"
        p = subprocess.run([roll_path, "table", table, "--seed", "1", "--json"],
                           capture_output=True, text=True)
        assert p.returncode == 0, p.stderr
        assert json.loads(p.stdout)["picks"][0].strip()


@pytest.mark.parametrize("name", ["ironsworn", "starforged"])
@pytest.mark.parametrize("odds", ASK_THE_ORACLE)
def test_ask_the_oracle_odds(name, odds):
    w = _weights(_resolve(_chain(name), f"moves/ask-the-oracle/{odds}.md"))
    assert w == {"Yes": YES_PERCENT[odds], "No": 100 - YES_PERCENT[odds]}


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_spark_pair_is_in_the_chain(name):
    chain = _chain(name)
    assert _resolve(chain, "action.md") and _resolve(chain, "theme.md")


@pytest.mark.skipif(not os.environ.get("DATASWORN_CLASSIC_JSON"),
                    reason="set DATASWORN_CLASSIC_JSON to a copy of the pinned classic.json")
def test_ironsworn_ask_the_oracle_matches_upstream():
    raw = open(os.environ["DATASWORN_CLASSIC_JSON"], "rb").read()
    assert hashlib.sha256(raw).hexdigest() == CLASSIC_SHA256, "not the pinned classic.json"
    move = json.loads(raw)["moves"]["fate"]["contents"]["ask_the_oracle"]
    for odds in ASK_THE_ORACLE:
        upstream = move["oracles"][odds.replace("-", "_")]
        with open(os.path.join(FIXTURES, "ironsworn", "moves", "ask-the-oracle", odds + ".json")) as fh:
            fixture = json.load(fh)
        assert fixture["id"] == upstream["_id"]
        assert fixture["die"] == upstream["dice"]
        assert fixture["rows"] == [{"max": r["roll"]["max"], "result": r["text"]}
                                   for r in upstream["rows"]]
