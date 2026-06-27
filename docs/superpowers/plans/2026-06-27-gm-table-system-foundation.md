# gm Table System (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "a table you roll on" one general Markdown concept — a weight-aware `roll table` over `- ` list files — and migrate the shipped JSON oracles onto it without changing any oracle's behavior.

**Architecture:** Extend the existing `bin/roll` CLI with a `table` subcommand that parses a markdown list (block rule: an entry is a top-level `- ` item plus its indented continuation; `- [w]` sets weight, default 1) and draws by the count model (`N = Σweights`, roll `1..N`, cumulative-map). Migrate each `adapters/*/oracles/*.json` (`{die:"1d100", rows:[{max,result}]}`) to `*.md` where each row becomes `- [max − prev_max] result` — identical distribution. Update the validator + docs + references to match. This is PR 1 of a 2-PR stack; the forge (PR 2) builds on it.

**Tech Stack:** Python 3 stdlib only (`secrets`, `argparse`, `re`); pytest via `uvx pytest`; the spec at `docs/superpowers/specs/2026-06-25-gm-forge-tables-design.md`.

## Global Constraints

- Python **standard library only** (no third-party imports in `bin/`).
- Production randomness uses `secrets`; `--seed` swaps in `random.Random` for tests only (existing `_make_rng` pattern).
- Every roll **prints its result** (Rule 0 / trust-through-visibility); `--json` emits a machine-readable object.
- Commit message format (repo CLAUDE.md): `[#11] (Claude Code + Opus 4.8) <scope>: <description>`.
- **Behavior-preserving migration:** a migrated table must reproduce the old JSON oracle's `face → result` mapping for every face. Parity is verified before any `.json` is deleted.
- Bump `plugins/gm/.claude-plugin/plugin.json` `version` **0.2.0 → 0.3.0** in this PR (installs are version-gated — repo CLAUDE.md → Releasing).
- Tests run from the plugin dir: `cd plugins/gm && uvx pytest tests -q`. The `roll`/`validate` paths come from `tests/conftest.py` fixtures (`roll_path`, `validate_path`).

---

### Task 1: `roll table` subcommand

**Files:**
- Modify: `plugins/gm/bin/roll` (add parse/roll/human helpers + `table` dispatch + `oracle` alias; update module docstring)
- Test: `plugins/gm/tests/test_roll.py` (append)

**Interfaces:**
- Produces: `parse_table(text: str) -> list[dict]` where each dict is `{"weight": int, "entry": str}` (entry = the `- ` line text after any `[w]`, joined with its indented continuation lines by `\n`). `roll_table(path: str, n: int = 1, seed: int | None = None) -> dict` returning `{"table": path, "total": int, "n": int, "rolls": list[int], "picks": list[str]}` (distinct draws, weighted, without replacement). `human_table(r: dict) -> str`. CLI: `roll table <file> [--n K] [--seed S] [--json]`; plus `roll oracle --table <file>` as a deprecated alias forwarding to `roll_table`.

- [ ] **Step 1: Write failing tests for `parse_table` + uniform draw**

Append to `plugins/gm/tests/test_roll.py`:

```python
import os
import subprocess


def _roll(roll_path, *args, **kw):
    return subprocess.run([roll_path, *args], capture_output=True, text=True, **kw)


def _table(tmp_path, body):
    p = tmp_path / "t.md"
    p.write_text(body)
    return str(p)


def test_table_uniform_pick_is_an_entry(roll_path, tmp_path):
    t = _table(tmp_path, "# Rumors\n- alpha\n- beta\n- gamma\n")
    r = _roll(roll_path, "table", t, "--seed", "1")
    assert r.returncode == 0
    assert any(w in r.stdout for w in ("alpha", "beta", "gamma"))
    assert "table" in r.stdout  # human header


def test_table_ignores_headers_and_blanks(roll_path, tmp_path):
    # only the two "- " items are entries; the header and blank line are not
    t = _table(tmp_path, "# H\n\n- one\n- two\n")
    out = _roll(roll_path, "table", t, "--json", "--seed", "1").stdout
    import json
    assert json.loads(out)["total"] == 2


def test_table_weighted_distribution(roll_path, tmp_path):
    # weight 3 vs 1 over a fixed seed sweep -> "common" dominates, "rare" still reachable
    t = _table(tmp_path, "- [3] common\n- [1] rare\n")
    picks = [json.loads(_roll(roll_path, "table", t, "--json", "--seed", str(s)).stdout)["picks"][0]
             for s in range(40)]
    assert picks.count("common") > picks.count("rare")
    assert "rare" in picks  # not unreachable
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd plugins/gm && uvx pytest tests/test_roll.py -k table -q`
Expected: FAIL (`table` is not a known subcommand → it's parsed as a dice expression and errors).

- [ ] **Step 3: Implement `parse_table` / `roll_table` / `human_table`**

In `plugins/gm/bin/roll`, add after `human_oracle` (and add `import os` is **not** needed):

```python
TABLE_ENTRY = re.compile(r"^- (?:\[(?P<w>\d+)\]\s*)?(?P<text>.*)$")


def parse_table(text):
    """Block rule: an entry is a top-level '- ' item plus its indented
    continuation lines, until the next top-level '- '. '- [w] ' sets weight."""
    entries = []
    for line in text.splitlines():
        m = TABLE_ENTRY.match(line)
        if m:                                   # top-level entry start
            entries.append({"weight": int(m["w"] or 1), "lines": [m["text"]]})
        elif entries and line[:1].isspace() and line.strip():
            entries[-1]["lines"].append(line.strip())   # indented continuation
        # else: header / blank / top-level prose -> ignored
    for e in entries:
        e["entry"] = "\n".join(e.pop("lines")).rstrip()
    return entries


def roll_table(path, n=1, seed=None):
    entries = parse_table(open(path).read())
    if not entries:
        raise ValueError(f"no entries in table: {path}")
    rng = _make_rng(seed)
    total, pool, rolls, picks = sum(e["weight"] for e in entries), list(entries), [], []
    for _ in range(min(n, len(entries))):
        t = sum(e["weight"] for e in pool)
        face = rng.randint(1, t) if rng is not None else 1 + secrets.randbelow(t)
        acc = 0
        for i, e in enumerate(pool):
            acc += e["weight"]
            if face <= acc:
                rolls.append(face); picks.append(e["entry"]); pool.pop(i)
                break
    return {"table": path, "total": total, "n": n, "rolls": rolls, "picks": picks}


def human_table(r):
    if len(r["picks"]) == 1:
        return f"\U0001F3B2 table {r['rolls'][0]}/{r['total']} -> {r['picks'][0]}"
    head = f"\U0001F3B2 table x{len(r['picks'])} of {r['total']}:"
    return "\n".join([head, *(f"  - {p}" for p in r["picks"])])
```

- [ ] **Step 4: Add the `table` subcommand + `oracle` alias dispatch**

Add a `_table_main` and wire dispatch. Add after `_oracle_main`:

```python
def _table_main(argv):
    ap = argparse.ArgumentParser(prog="roll table")
    ap.add_argument("file")
    ap.add_argument("--n", type=int, default=1)
    ap.add_argument("--seed", type=int)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    try:
        r = roll_table(a.file, n=a.n, seed=a.seed)
    except (OSError, ValueError) as e:
        sys.exit(f"roll: {e}")
    print(json.dumps(r) if a.json else human_table(r))
```

Replace `_oracle_main` body so `oracle` is a deprecated alias forwarding `--table` to the table roller:

```python
def _oracle_main(argv):
    ap = argparse.ArgumentParser(prog="roll oracle")
    ap.add_argument("--table", required=True)
    ap.add_argument("--seed", type=int)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    _table_main([a.table, *(["--seed", str(a.seed)] if a.seed is not None else []),
                 *(["--json"] if a.json else [])])
```

In `main()`, add the `table` branch before the `else`:

```python
    if argv[0] == "oracle":
        _oracle_main(argv[1:])
    elif argv[0] == "table":
        _table_main(argv[1:])
    elif argv[0] == "ironsworn-action":
```

Update the module docstring usage block: add `roll table <file> [--n N] [--seed N] [--json]` and mark `roll oracle --table <path>` as `(deprecated alias of table)`. Delete the now-unused `roll_oracle`/`human_oracle` functions (JSON readers) — the alias uses `roll_table`.

- [ ] **Step 5: Run the table tests — verify pass**

Run: `cd plugins/gm && uvx pytest tests/test_roll.py -k table -q`
Expected: PASS (3 tests).

- [ ] **Step 6: Add error + `--n` + block-rule + alias tests, verify pass**

Append:

```python
def test_table_n_draws_distinct(roll_path, tmp_path):
    t = _table(tmp_path, "- a\n- b\n- c\n")
    picks = json.loads(_roll(roll_path, "table", t, "--n", "3", "--json", "--seed", "2").stdout)["picks"]
    assert sorted(picks) == ["a", "b", "c"]          # distinct, all drawn


def test_table_multiline_entry_block(roll_path, tmp_path):
    t = _table(tmp_path, "- **Edda** — keeper.\n    Wants: company.\n- plain\n")
    # force the first entry: weight it heavily so seed lands there, then assert the block
    t2 = _table(tmp_path, "- [99] **Edda** — keeper.\n    Wants: company.\n- [1] plain\n")
    out = json.loads(_roll(roll_path, "table", t2, "--json", "--seed", "1").stdout)
    assert out["total"] == 100
    assert "Edda" in out["picks"][0] and "Wants: company." in out["picks"][0]


def test_table_missing_file_errors(roll_path, tmp_path):
    r = _roll(roll_path, "table", str(tmp_path / "nope.md"))
    assert r.returncode != 0 and "roll:" in r.stderr


def test_table_empty_errors(roll_path, tmp_path):
    r = _roll(roll_path, "table", _table(tmp_path, "# only a header\n"))
    assert r.returncode != 0 and "no entries" in r.stderr


def test_oracle_alias_forwards_to_table(roll_path, tmp_path):
    t = _table(tmp_path, "- [50] No\n- [50] Yes\n")
    r = _roll(roll_path, "oracle", "--table", t, "--seed", "1")
    assert r.returncode == 0 and ("No" in r.stdout or "Yes" in r.stdout)
```

Run: `cd plugins/gm && uvx pytest tests/test_roll.py -q`
Expected: PASS (all roll tests, old + new).

- [ ] **Step 7: Commit**

```bash
git add plugins/gm/bin/roll plugins/gm/tests/test_roll.py
git commit -m "[#11] (Claude Code + Opus 4.8) roll: add table subcommand (weighted MD lists) + oracle alias"
```

---

### Task 2: Migrate the shipped oracles JSON → MD (parity-verified)

**Files:**
- Create: `plugins/gm/adapters/{generic,ironsworn,starforged}/oracles/*.md` (18 files, from the `.json`)
- Delete: the 18 `plugins/gm/adapters/*/oracles/*.json`
- Modify: each `plugins/gm/adapters/*/adapter.md` (references `oracles/X.json` → `oracles/X.md`; `roll oracle --table …` → `roll table …`)

**Interfaces:**
- Consumes: `roll_table` / `parse_table` from Task 1 (parity check rolls the migrated tables).
- Produces: `oracles/*.md` tables where row `{max, result}` → `- [max − prev_max] result` (top-to-bottom). No code symbols.

- [ ] **Step 1: Write + run the conversion-with-parity script**

Create `plugins/gm/_migrate_oracles.py` (temporary, deleted in Step 4). It converts every oracle and **asserts** the MD reproduces the JSON's `face → result` for all faces before writing:

```python
import glob, json, os, re, sys
sys.path.insert(0, "bin"); import importlib.util
spec = importlib.util.spec_from_file_location("roll", "bin/roll")
roll = importlib.util.module_from_spec(spec); spec.loader.exec_module(roll)

def json_result(table, face):
    for row in table["rows"]:
        if face <= row["max"]:
            return row["result"]
    return table["rows"][-1]["result"]

for jpath in glob.glob("adapters/*/oracles/*.json"):
    table = json.load(open(jpath))
    die_max = int(table["die"].split("d")[1])
    assert die_max == 100, f"{jpath}: only 1d100 oracles expected, got {table['die']}"
    prev, lines = 0, []
    for row in table["rows"]:
        w = row["max"] - prev; prev = row["max"]
        assert w >= 1, f"{jpath}: non-ascending/zero-width row at {row}"
        lines.append(f"- [{w}] {row['result']}")
    assert prev == die_max, f"{jpath}: rows do not cover 1..{die_max}"
    md = "\n".join(lines) + "\n"
    mpath = jpath[:-5] + ".md"
    open(mpath, "w").write(md)
    # PARITY: cumulative map of the MD must equal the JSON for every face 1..100
    entries = roll.parse_table(md)
    acc, cum = 0, []
    for e in entries:
        acc += e["weight"]; cum.append((acc, e["entry"]))
    for face in range(1, die_max + 1):
        md_res = next(res for hi, res in cum if face <= hi)
        assert md_res == json_result(table, face), f"{jpath}: face {face} mismatch"
    print(f"ok {jpath} -> {mpath} ({len(entries)} entries)")
```

Run: `cd plugins/gm && python3 _migrate_oracles.py`
Expected: 18 `ok …` lines, no AssertionError. (If any oracle isn't `1d100` or has non-ascending rows, the script stops — fix that oracle's source, don't weaken the check.)

- [ ] **Step 2: Update each `adapter.md`'s oracle references**

For every `plugins/gm/adapters/*/adapter.md`, replace `oracles/<name>.json` → `oracles/<name>.md` and any `roll oracle --table <path>` → `roll table <path>`. Find them first:

Run: `cd plugins/gm && grep -rn "oracles/[A-Za-z0-9-]*\.json\|roll oracle" adapters/*/adapter.md`
Then edit each hit. (generic references `yes-no`, `action`, `theme`; ironsworn/starforged reference theirs in their resolution-rules prose.)

- [ ] **Step 3: Delete the JSON oracles + the migration script**

```bash
cd plugins/gm && rm adapters/*/oracles/*.json _migrate_oracles.py
```

- [ ] **Step 4: Verify a migrated oracle rolls + behaves**

Run: `cd plugins/gm && ./bin/roll table adapters/generic/oracles/yes-no.md --seed 1 && ./bin/roll table adapters/generic/oracles/yes-no.md --json --seed 1`
Expected: a `🎲 table N/100 -> …` line whose result is one of the six yes-no bands; the JSON shows `"total": 100`.

- [ ] **Step 5: Commit**

```bash
git add plugins/gm/adapters
git commit -m "[#11] (Claude Code + Opus 4.8) gm: migrate oracles JSON -> MD tables (behaviour-preserving)"
```

---

### Task 3: Update the adapter validator for MD tables

**Files:**
- Modify: `plugins/gm/bin/validate-adapter` (replace `validate_oracle` with `validate_table`; glob `oracles/*.md`; reference regex `.json` → `.md`)
- Test: `plugins/gm/tests/test_validate.py` (append)

**Interfaces:**
- Consumes: `parse_table` logic (re-implement the same `- [w]` parse inline — `validate-adapter` must stay import-free of `roll`, matching the current file's self-contained style).
- Produces: `validate_table(path) -> list[str]` (errors); integrated into `validate_adapter`.

- [ ] **Step 1: Write failing validator tests**

Append to `plugins/gm/tests/test_validate.py` (mirror its existing style — it builds adapter dirs in `tmp_path` and runs `validate_path`):

```python
def test_table_valid(validate_path, tmp_path):
    d = _adapter(tmp_path, "good", oracle_md="- [50] No\n- [50] Yes\n")  # helper per existing tests
    assert run(validate_path, d).returncode == 0


def test_table_zero_weight_fails(validate_path, tmp_path):
    d = _adapter(tmp_path, "bad", oracle_md="- [0] nope\n- ok\n")
    p = run(validate_path, d)
    assert p.returncode == 1 and "weight" in p.stdout


def test_table_empty_fails(validate_path, tmp_path):
    d = _adapter(tmp_path, "bad2", oracle_md="# header only\n")
    p = run(validate_path, d)
    assert p.returncode == 1 and "no entries" in p.stdout
```

(Adapt `_adapter`/`run` to the existing helpers in `test_validate.py`; add an `oracle_md` path that writes `oracles/x.md` and references it in the generated `adapter.md`.)

- [ ] **Step 2: Run — verify fail**

Run: `cd plugins/gm && uvx pytest tests/test_validate.py -k table -q`
Expected: FAIL (no `oracles/*.md` handling yet).

- [ ] **Step 3: Replace oracle validation with table validation**

In `plugins/gm/bin/validate-adapter`: delete `validate_oracle` and its `die_max`/`die_min`/`DIE` helpers (no longer needed), and add:

```python
TABLE_ENTRY = re.compile(r"^- (?:\[(\d+)\]\s*)?(.*)$")


def validate_table(path):
    errs, entries, weights = [], 0, []
    for i, line in enumerate(open(path).read().splitlines()):
        m = TABLE_ENTRY.match(line)
        if m:
            entries += 1
            w = int(m.group(1)) if m.group(1) else 1
            if w < 1:
                errs.append(f"{path}: entry {entries} has weight {w} (must be >= 1)")
    if entries == 0:
        errs.append(f"{path}: no entries (need at least one '- ' item)")
    return errs
```

In `validate_adapter`, change the oracle glob/loop from `"*.json"` to `"*.md"` and call `validate_table`; change the reference-existence regex from `oracles/([\w./-]+\.json)` to `oracles/([\w./-]+\.md)`.

- [ ] **Step 4: Run table tests + full validate suite — verify pass**

Run: `cd plugins/gm && uvx pytest tests/test_validate.py -q && python3 bin/validate-adapter --all adapters`
Expected: tests PASS; `OK 4 adapter(s) valid`.

- [ ] **Step 5: Commit**

```bash
git add plugins/gm/bin/validate-adapter plugins/gm/tests/test_validate.py
git commit -m "[#11] (Claude Code + Opus 4.8) validate-adapter: lint MD tables (retire JSON oracle coverage checks)"
```

---

### Task 4: Documentation

**Files:**
- Modify: `plugins/gm/skills/gm/references/adapter-contract.md` (the "Oracle tables (`oracles/*.json`)" section → the MD table format)
- Modify: `plugins/gm/skills/gm/references/state-schema.md` (add `tables/<type>.md` + `.gm/tables/<type>.md`)
- Modify: `plugins/gm/skills/gm/SKILL.md` + `plugins/gm/README.md` (roll examples: `roll oracle --table x.json` → `roll table x.md`)
- Modify: `plugins/gm/adapters/generic/adapter.md` etc. already done in Task 2; here just confirm no stale `oracle` references remain in docs.

- [ ] **Step 1: Rewrite the adapter-contract "Oracle tables" section**

Replace the `### Oracle tables (`oracles/*.json`)` subsection with a `### Tables (`oracles/*.md`)` subsection documenting: the block rule (entry = top-level `- ` + indented continuation), `- [w]` weights (default 1, count model → coverage automatic), `roll table <file>`, and that campaign/forge tables share the format. Keep the "split across tables read together" note for `action` + `theme`.

- [ ] **Step 2: Add tables to state-schema**

In `state-schema.md`'s Layout block add `tables/<type>.md` (player-facing rollable tables) and note `.gm/tables/<type>.md` for sealed ones (cross-reference the `.gm/` section). Add a one-paragraph `### tables/` entry: hand-authored or forged; `roll table` draws on them.

- [ ] **Step 3: Update roll examples in SKILL + README**

In `SKILL.md` (play-loop step 4 + the generic-adapter examples) and `README.md` (the Dice block), change `roll oracle --table <adapter>/oracles/yes-no.json` → `roll table <adapter>/oracles/yes-no.md`, and add a `roll table <campaign>/tables/<x>.md` example.

- [ ] **Step 4: Grep for stale references — verify clean**

Run: `cd plugins/gm && grep -rn "oracles/[A-Za-z0-9-]*\.json\|roll oracle" . --include=*.md`
Expected: no hits (or only a deliberate "deprecated alias" mention in adapter-contract).

- [ ] **Step 5: Commit**

```bash
git add plugins/gm/skills plugins/gm/README.md
git commit -m "[#11] (Claude Code + Opus 4.8) gm: docs for the MD table system (contract, state-schema, roll examples)"
```

---

### Task 5: Version bump + full CI

**Files:**
- Modify: `plugins/gm/.claude-plugin/plugin.json`

- [ ] **Step 1: Bump the version**

Change `"version": "0.2.0"` → `"version": "0.3.0"` in `plugins/gm/.claude-plugin/plugin.json`.

- [ ] **Step 2: Run the full gm CI locally — verify green**

Run:
```bash
cd plugins/gm && uvx pytest tests -q \
  && python3 bin/validate-adapter --all adapters \
  && python3 bin/validate-adapter --personas --all personas
```
Expected: all tests pass; `OK 4 adapter(s) valid`; `OK 4 persona(s) valid`.

- [ ] **Step 3: Commit**

```bash
git add plugins/gm/.claude-plugin/plugin.json
git commit -m "[#11] (Claude Code + Opus 4.8) gm: bump version 0.2.0 -> 0.3.0 (MD table system)"
```

---

## Self-Review

**Spec coverage:**
- Foundation Format (block rule, `- [w]`, count model) → Task 1. ✓
- `roll table` + `oracle` alias → Task 1. ✓
- Storage `tables/` + `.gm/tables/` → Task 4 (docs); the *roller* is path-agnostic (Task 1 reads any file), so no code needed for storage location. ✓
- Migrate oracles JSON→MD, behavior-preserving → Task 2 (parity assertion). ✓
- Validator: retire coverage, add MD lint → Task 3. ✓
- Docs (contract, state-schema, SKILL) → Task 4. ✓
- Version bump 0.2.0→0.3.0 → Task 5. ✓
- *Not* in this plan (PR 2 / forge): `forge/`, `/gm:forge`, promotion adapter, `references/forge.md`. Correct — foundation only.

**Placeholder scan:** Task 3 Step 1 references existing `test_validate.py` helpers (`_adapter`, `run`) the implementer must match — flagged inline as "adapt to existing helpers," not a blank TODO. All code steps contain real code.

**Type consistency:** `parse_table` returns `{"weight","entry"}` (Task 1) and the validator re-implements the same `- [w]` regex inline (Task 3, no shared import — matches `validate-adapter`'s self-contained style). `roll_table` return keys (`total`, `rolls`, `picks`) match `human_table` and the `--json` tests. Migration weight rule `max − prev_max` matches the count model in Task 1.
