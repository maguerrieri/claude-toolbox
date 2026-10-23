"""The data /gm:oracle rolls (commands/oracle.md; adapter-contract: "The yes/no and
spark rules").

Every playable adapter states a yes/no rule and a spark rule along its extends:
chain, and every table each rule names is in the chain and rolls. Ironsworn's Ask the
Oracle fixtures are checked against the pinned Datasworn file when
DATASWORN_CLASSIC_JSON points at a copy of it (CI downloads one).
"""
import glob
import hashlib
import importlib.util
import json
import os
import re
from importlib.machinery import SourceFileLoader

import pytest

HERE = os.path.dirname(__file__)
PLUGIN = os.path.abspath(os.path.join(HERE, ".."))
ADAPTERS = os.path.join(PLUGIN, "adapters")
FIXTURES = os.path.join(HERE, "fixtures", "oracles")
CI = os.path.abspath(os.path.join(PLUGIN, "..", "..", ".github", "workflows", "gm-ci.yml"))


def _load(name, path):
    loader = SourceFileLoader(name, os.path.join(PLUGIN, path))
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
    loader.exec_module(mod)
    return mod


roll = _load("roll", "bin/roll")
validate = _load("validate_adapter", "bin/validate-adapter")
importer = _load("datasworn_import", "tools/datasworn-import")

# A top-level bullet's bold label plus the parenthetical right after it, if any:
# `- **Yes/No question.** …`, `- **Ask the Oracle** (yes/no): …`.
RULE_BULLET = re.compile(r"^- \*\*([^*\n]+)\*\*[ \t]*(\([^)\n]*\))?")
ASK_THE_ORACLE = ["almost-certain", "likely", "fifty-fifty", "unlikely", "small-chance"]

# classic.json at the importer's pin (UPSTREAM_REF; test_classic_pin_follows_the_importer).
CLASSIC_SHA256 = "7c669d602cf05576d74a966d3eac0657bc55ddbdab2829507362f00004ef52fc"


def _read(path):
    with open(path) as fh:
        return fh.read()


def _frontmatter(adapter_dir):
    fm, _ = validate.parse_frontmatter(os.path.join(adapter_dir, "adapter.md"))
    return fm or {}


def _chain(name):
    chain, errs = validate.extends_chain(os.path.join(ADAPTERS, name), ADAPTERS)
    assert not errs, errs
    return chain


def _playable():
    return [os.path.basename(d) for d in sorted(glob.glob(os.path.join(ADAPTERS, "*")))
            if os.path.isfile(os.path.join(d, "adapter.md"))
            and _frontmatter(d).get("abstract") != "true"]


def _rule(chain, words):
    """The nearest bullet along the chain whose label names one of `words`, with its
    continuation: indented lines, blank lines between them included."""
    for d in chain:
        lines = _read(os.path.join(d, "adapter.md")).splitlines()
        for i, line in enumerate(lines):
            m = RULE_BULLET.match(line)
            if m and any(w in (m.group(1) + (m.group(2) or "")).lower() for w in words):
                block = [line]
                for nxt in lines[i + 1:]:
                    if nxt.strip() and not nxt.startswith((" ", "\t")):
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


YES_NO = {
    "generic": ["yes-no.md"],
    "ironsworn": [f"moves/ask-the-oracle/{o}.md" for o in ASK_THE_ORACLE],
    "starforged": [f"moves/ask-the-oracle/{o}.md" for o in ASK_THE_ORACLE],
}
SPARK = {
    "generic": ["action.md", "theme.md"],
    "ironsworn": ["action.md", "theme.md"],
    "starforged": ["action.md", "descriptor.md", "focus.md", "theme.md"],
}
RULES = [("yes/no", ("yes/no",), YES_NO), ("spark", ("spark", "inspiration"), SPARK)]


def test_every_shipped_playable_adapter_is_covered():
    assert sorted(_playable()) == sorted(YES_NO) == sorted(SPARK)


@pytest.mark.parametrize("kind,words,expected", RULES, ids=[r[0] for r in RULES])
@pytest.mark.parametrize("name", sorted(YES_NO))
def test_rule_names_the_adapters_own_tables(name, kind, words, expected):
    chain = _chain(name)
    rule = _rule(chain, words)
    assert rule, f"{name}: no adapter in its extends: chain states a {kind} rule"
    refs = sorted(set(validate.ORACLE_REF.findall(rule)))
    assert refs == sorted(expected[name])
    for ref in refs:
        table = _resolve(chain, ref)
        assert table, f"{name}: its {kind} rule names oracles/{ref}, which isn't in its chain"
        assert roll.roll_table(table, seed=1)["picks"][0].strip()


def test_rule_continuation_spans_blank_lines(tmp_path):
    (tmp_path / "adapter.md").write_text(
        "---\nname: x\n---\n\n- **Ask the Oracle** (yes/no): pick the odds.\n\n"
        "  - `oracles/a.md`\n  - `oracles/b.md`\n\nNext paragraph `oracles/c.md`.\n")
    rule = _rule([str(tmp_path)], ("yes/no",))
    assert validate.ORACLE_REF.findall(rule) == ["a.md", "b.md"]


def test_classic_pin_follows_the_importer():
    # Ironsworn's tables share the importer's Datasworn pin; moving it moves this one too.
    assert f"/{importer.UPSTREAM_REF}/datasworn/classic/classic.json" in _read(CI)
    source = _read(os.path.join(ADAPTERS, "ironsworn", "SOURCE.md"))
    assert importer.UPSTREAM_REF in source and importer.UPSTREAM_TAG in source
    assert CLASSIC_SHA256 in source


@pytest.mark.skipif(not os.environ.get("DATASWORN_CLASSIC_JSON"),
                    reason="set DATASWORN_CLASSIC_JSON to a copy of the pinned classic.json (CI does)")
def test_ironsworn_ask_the_oracle_matches_upstream():
    with open(os.environ["DATASWORN_CLASSIC_JSON"], "rb") as fh:
        raw = fh.read()
    assert hashlib.sha256(raw).hexdigest() == CLASSIC_SHA256, "not the pinned classic.json"
    oracles = json.loads(raw)["moves"]["fate"]["contents"]["ask_the_oracle"]["oracles"]
    assert sorted(oracles) == sorted(o.replace("-", "_") for o in ASK_THE_ORACLE)
    for odds in ASK_THE_ORACLE:
        upstream = oracles[odds.replace("-", "_")]
        fixture = json.loads(_read(os.path.join(FIXTURES, "ironsworn", "moves", "ask-the-oracle",
                                                odds + ".json")))
        assert fixture["id"] == upstream["_id"]
        assert fixture["die"] == upstream["dice"]
        assert fixture["rows"] == [{"max": r["roll"]["max"], "result": r["text"]}
                                   for r in upstream["rows"]]
