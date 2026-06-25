# gm Engine MVP (Milestone 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `gm` plugin's Engine MVP — a bundled dice CLI, the agnostic core skill, the `generic` (Mythic-style) adapter, and the four minimal commands — so a player can run a solo session end-to-end with true dice and durable markdown state.

**Architecture:** A stdlib-Python dice CLI (`bin/roll`) does the one thing an LLM can't (true RNG). The `skills/gm` core holds the play loop, Rule 0 ("never improvise numbers"), the campaign-state convention, and the adapter contract. A `generic` adapter supplies a yes/no + meaning-table oracle as declarative data. Four slash commands (`/gm:new-campaign`, `/gm:play`, `/gm:wrap`, `/gm:oracle`) are thin entry points into the skill. Campaign saves live in the user's own directory, never in the plugin.

**Tech Stack:** Python 3 standard library only (`secrets`, `argparse`, `json`, `re`) — zero third-party runtime deps; `pytest` for `bin/roll` tests; Markdown for the skill/commands/adapter prose; JSON for oracle-table data.

## Global Constraints

[Every task's requirements implicitly include these — copied from the spec.]

- **Rule 0 — never improvise numbers.** Every die goes through `bin/roll`; every stat/rule/oracle value comes from the sheet or adapter data.
- **Dice CLI:** stdlib-Python only, `secrets` for production RNG; `bin/roll` carries a shebang (`#!/usr/bin/env python3`) + executable bit; `--seed` injects determinism in tests only.
- **No-prompt guarantee:** `bin/roll` is allowlisted so play never triggers a permission prompt — and the allowlist string must match the *exact* invocation form (bare `roll` on PATH).
- **State lives in the user's space.** The plugin scaffolds and ships *example* campaigns; it never stores a real save under `plugins/gm/`.
- **Adapters are declarative data.** No engine logic in an adapter — only a manifest, oracle/rules data, and a sheet schema.
- **Public repo hygiene.** No personal names, local paths, or secrets in any committed file.
- **Disk is truth; rolls are visible.** State files are authoritative; every roll prints its dice + math.

---

## File Structure (created this milestone, all under `plugins/gm/`)

- `.claude-plugin/plugin.json` — plugin manifest (name, version, description) + the `bin/roll` permission allowlist.
- `bin/roll` — the dice CLI (executable, shebang). One responsibility: parse a dice expression / oracle request, roll with `secrets`, print human + `--json`.
- `tests/test_roll.py` — pytest coverage for `bin/roll` (grammar, modes, distribution, seed determinism).
- `tests/conftest.py` — locates `bin/roll` for the tests.
- `skills/gm/SKILL.md` — the core: session lifecycle + play loop + Rule 0 + how to load an adapter/state + how to call `bin/roll`.
- `skills/gm/references/state-schema.md` — the campaign-state markdown convention.
- `skills/gm/references/adapter-contract.md` — what an adapter folder provides + the `extends:` merge rule (forward-looking; generic uses no `extends`).
- `skills/gm/references/gm-craft.md` — system-agnostic narrative technique (fail-forward, cost, NPC motivation).
- `adapters/generic/adapter.md` — manifest: dice modes used, resolution rules, sheet schema pointer, tone/safety defaults.
- `adapters/generic/oracles/yes-no.json` — Mythic-style yes/no oracle (with likelihood).
- `adapters/generic/oracles/action-theme.json` — meaning-table oracle (action + theme word pairs).
- `adapters/generic/sheet-template.md` — the generic character-sheet schema/blank.
- `commands/new-campaign.md`, `commands/play.md`, `commands/wrap.md`, `commands/oracle.md` — slash-command entry points.
- `README.md` — short MVP usage (expanded in M5).

---

## Task 1: Plugin scaffold + test harness

**Files:**
- Create: `plugins/gm/.claude-plugin/plugin.json`
- Create: `plugins/gm/tests/conftest.py`
- Create: `plugins/gm/bin/roll` (empty stub with shebang, for now)

**Interfaces:**
- Produces: a loadable plugin manifest; `conftest.py` exposes a `roll_cmd` fixture returning the absolute path to `bin/roll` so tests are location-independent.

- [ ] **Step 1:** Create `.claude-plugin/plugin.json`:

```json
{
  "name": "gm",
  "version": "0.1.0",
  "description": "System-agnostic, persona-driven solo RPG game master.",
  "permissions": { "allow": ["Bash(roll:*)"] }
}
```
(If the manifest schema rejects `permissions`, move the allowlist to the plugin's bundled settings during Task 11 — Task 11 verifies the no-prompt guarantee empirically either way.)

- [ ] **Step 2:** Create `bin/roll` as an executable stub:

```python
#!/usr/bin/env python3
import sys
if __name__ == "__main__":
    sys.exit("roll: not implemented")
```
Then `chmod +x plugins/gm/bin/roll`.

- [ ] **Step 3:** Create `tests/conftest.py`:

```python
import os, pytest
@pytest.fixture
def roll_path():
    here = os.path.dirname(__file__)
    return os.path.abspath(os.path.join(here, "..", "bin", "roll"))
```

- [ ] **Step 4:** Verify the stub runs: `python3 plugins/gm/bin/roll` → exits non-zero with "not implemented". Verify exec bit: `test -x plugins/gm/bin/roll`.

- [ ] **Step 5:** Commit: `[#5] (Claude Code + Opus 4.8) gm: scaffold plugin manifest + roll stub + test harness`

---

## Task 2: `bin/roll` — standard dice notation (`NdX±M`)

**Files:**
- Modify: `plugins/gm/bin/roll`
- Test: `plugins/gm/tests/test_roll.py`

**Interfaces:**
- Produces: `roll "<expr>"` prints a human line and exits 0; `--seed N` makes output deterministic; `--json` prints `{"expr","rolls","kept","modifier","total"}`. Expression grammar this task: `NdX` (N optional → 1), optional `+M`/`-M`.

- [ ] **Step 1: Write failing tests** (`tests/test_roll.py`):

```python
import json, subprocess

def run(roll_path, *args):
    p = subprocess.run([roll_path, *args], capture_output=True, text=True)
    return p

def test_basic_total_in_range(roll_path):
    p = run(roll_path, "2d6", "--json")
    assert p.returncode == 0
    out = json.loads(p.stdout)
    assert len(out["rolls"]) == 2
    assert 2 <= out["total"] <= 12

def test_modifier_applied(roll_path):
    out = json.loads(run(roll_path, "1d1+5", "--json").stdout)  # d1 always 1
    assert out["total"] == 6
    assert out["modifier"] == 5

def test_seed_is_deterministic(roll_path):
    a = run(roll_path, "3d20", "--seed", "42").stdout
    b = run(roll_path, "3d20", "--seed", "42").stdout
    assert a == b and a.strip() != ""

def test_human_output_shows_dice(roll_path):
    out = run(roll_path, "2d6", "--seed", "1").stdout
    assert "2d6" in out and "=" in out
```

- [ ] **Step 2: Run, verify they fail** — `pytest plugins/gm/tests/test_roll.py -v` → FAIL ("not implemented" / exit 1).

- [ ] **Step 3: Implement** `bin/roll` (replace stub):

```python
#!/usr/bin/env python3
"""gm dice CLI — true-RNG roller. Stdlib only."""
import argparse, json, re, secrets, sys

def _rng(seed):
    import random
    return random.Random(seed) if seed is not None else None

def _die(sides, rng):
    return rng.randint(1, sides) if rng else 1 + secrets.randbelow(sides)

EXPR = re.compile(r"^(?P<n>\d*)d(?P<x>\d+)(?P<mod>[+-]\d+)?$")

def roll_expr(expr, seed=None):
    m = EXPR.match(expr.replace(" ", ""))
    if not m:
        raise ValueError(f"bad dice expression: {expr!r}")
    n = int(m["n"] or 1); x = int(m["x"]); mod = int(m["mod"] or 0)
    rng = _rng(seed)
    rolls = [_die(x, rng) for _ in range(n)]
    return {"expr": expr, "rolls": rolls, "kept": rolls, "modifier": mod,
            "total": sum(rolls) + mod}

def human(r):
    return f"\U0001F3B2 {r['expr']} -> {r['rolls']}" + \
           (f" {r['modifier']:+d}" if r["modifier"] else "") + f" = {r['total']}"

def main(argv=None):
    ap = argparse.ArgumentParser(prog="roll")
    ap.add_argument("expr")
    ap.add_argument("--seed", type=int)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    try:
        r = roll_expr(a.expr, a.seed)
    except ValueError as e:
        sys.exit(str(e))
    print(json.dumps(r) if a.json else human(r))

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run, verify pass** — `pytest plugins/gm/tests/test_roll.py -v` → all PASS.

- [ ] **Step 5: Commit:** `[#5] (Claude Code + Opus 4.8) roll: standard dice notation NdX±M (#5)`

---

## Task 3: `bin/roll` — keep/drop, advantage/disadvantage, exploding

**Files:** Modify `plugins/gm/bin/roll`; Test `plugins/gm/tests/test_roll.py`

**Interfaces:**
- Produces: grammar extends to `khM`/`klM` (keep highest/lowest M, applied before modifier), trailing `!` (exploding: a die showing max rolls again and adds, capped at 100 iterations); `--adv`/`--dis` convenience = `2dX` keep-high-1 / keep-low-1.

- [ ] **Step 1: Failing tests** (append):

```python
def test_keep_highest(roll_path):
    out = json.loads(run(roll_path, "4d1kh3", "--json").stdout)  # all 1s
    assert out["kept"] == [1, 1, 1] and out["total"] == 3

def test_advantage_keeps_one_of_two(roll_path):
    out = json.loads(run(roll_path, "1d20", "--adv", "--json").stdout)
    assert len(out["rolls"]) == 2 and len(out["kept"]) == 1

def test_exploding_d1_terminates(roll_path):
    # d1 always max; explosion must cap, not loop forever
    out = json.loads(run(roll_path, "1d1!", "--json", "--seed", "1").stdout)
    assert out["total"] >= 1  # returns, doesn't hang
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** — extend `EXPR` to `^(?P<n>\d*)d(?P<x>\d+)(?P<kd>k[hl]\d+)?(?P<exp>!)?(?P<mod>[+-]\d+)?$`; in `roll_expr` apply exploding (re-roll while die == x, cap 100), then keep/drop (`kh`/`kl` sort + slice into `kept`), then total = sum(kept)+mod. Add `--adv`/`--dis` in `main` that rewrite a bare `NdX` to `2dXkh1`/`2dXkl1` before parsing. Show full revised functions.

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit:** `[#5] (Claude Code + Opus 4.8) roll: keep/drop, advantage, exploding`

---

## Task 4: `bin/roll oracle` — table lookup

**Files:** Modify `plugins/gm/bin/roll`; Create `plugins/gm/tests/fixtures/oracle.json`; Test `tests/test_roll.py`

**Interfaces:**
- Consumes: an oracle JSON file `{"die":"1dN","rows":[{"max":int,"result":str},...]}` (rows ascending by `max`, covering 1..N).
- Produces: `roll oracle --table <path> [--seed N] [--json]` rolls the table's die, finds the first row with `roll <= max`, prints the result; `--json` → `{"table","roll","result"}`.

- [ ] **Step 1:** Create fixture `tests/fixtures/oracle.json`: `{"die":"1d6","rows":[{"max":3,"result":"No"},{"max":6,"result":"Yes"}]}`.

- [ ] **Step 2: Failing tests:**

```python
def test_oracle_lookup_low(roll_path, tmp_path):
    out = json.loads(run(roll_path, "oracle", "--table", "plugins/gm/tests/fixtures/oracle.json", "--seed", "0", "--json").stdout)
    assert out["result"] in ("No", "Yes") and 1 <= out["roll"] <= 6

def test_oracle_boundaries(roll_path):
    # exhaustively: every face maps to a row
    seen = set()
    for s in range(0, 60):
        out = json.loads(run(roll_path, "oracle", "--table", "plugins/gm/tests/fixtures/oracle.json", "--seed", str(s), "--json").stdout)
        seen.add(out["result"])
    assert seen == {"No", "Yes"}
```

- [ ] **Step 3: Implement** — add an `oracle` subcommand path in `main` (detect `argv[0]=="oracle"`), load+parse JSON, roll `die` via `roll_expr`, select row, print. Show the code.

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit:** `[#5] (Claude Code + Opus 4.8) roll: oracle table lookup`

---

## Task 5: `references/state-schema.md` — campaign-state convention

**Files:** Create `plugins/gm/skills/gm/references/state-schema.md`

**Interfaces:**
- Produces: the documented file/folder layout the core reads/writes in a campaign dir. Later tasks (SKILL.md, commands) reference these exact filenames.

- [ ] **Step 1:** Author the doc. It MUST specify, with a concrete example of each: `campaign.md` (premise, truths, tone, `adapter:` field, saves metadata), `characters/<name>.md` (per adapter sheet schema), `npcs.md`, `threads.md`, `clocks.md`, `locations.md`, `log/NNNN-<title>.md` (session journal + a forward "Previously…" recap). State the rules: disk is truth; the core re-reads at session start + decision points; deltas written at wrap.
- [ ] **Step 2: Verify** the filenames here exactly match those used in SKILL.md (Task 9) and the commands (Task 10) — keep a single source of truth.
- [ ] **Step 3: Commit:** `[#5] (Claude Code + Opus 4.8) gm: campaign-state schema reference`

---

## Task 6: `references/adapter-contract.md` — adapter spec

**Files:** Create `plugins/gm/skills/gm/references/adapter-contract.md`

- [ ] **Step 1:** Author the contract: an adapter is a folder `adapters/<name>/` with `adapter.md` (front-matter: `name`, optional `extends`, `dice` modes, `tone`; body: **resolution rules** the core follows, `sheet` pointer, safety defaults), `oracles/` (the JSON table format from Task 4), `rules/` (optional), `sheet-template.md`. Specify the `extends:` merge precisely (resolve parent→child, child wins on key collisions, data files union by id) even though `generic` uses no `extends` — M2 relies on this being written now. State the hard rule: **no engine logic in an adapter.**
- [ ] **Step 2: Verify** the oracle JSON shape documented here is byte-for-byte the shape `bin/roll oracle` parses (Task 4).
- [ ] **Step 3: Commit:** `[#5] (Claude Code + Opus 4.8) gm: adapter contract reference`

---

## Task 7: `references/gm-craft.md` — narrative technique

**Files:** Create `plugins/gm/skills/gm/references/gm-craft.md`

- [ ] **Step 1:** Author concise, system-agnostic guidance: fail-forward (a miss moves the story, never dead-ends), succeed-at-a-cost (weak hits carry a price), NPC motivation (every NPC wants something), scene framing, pacing, and player-as-referee (the state file wins). No system-specific terms.
- [ ] **Step 2: Commit:** `[#5] (Claude Code + Opus 4.8) gm: GM-craft reference`

---

## Task 8: `adapters/generic/` — the Mythic-style oracle adapter

**Files:** Create `adapters/generic/adapter.md`, `adapters/generic/oracles/yes-no.json`, `adapters/generic/oracles/action-theme.json`, `adapters/generic/sheet-template.md`

**Interfaces:**
- Consumes: the oracle JSON shape (Task 4/6); the adapter manifest shape (Task 6).
- Produces: a fully-loadable adapter the core can run with no `extends`.

- [ ] **Step 1:** Author `oracles/yes-no.json` as a `1d100` table with likelihood-aware rows ("No, and…/No/No, but…/Yes, but…/Yes/Yes, and…" bands) in the Task-4 schema.
- [ ] **Step 2:** Author `oracles/action-theme.json` — two `1d100` tables (or one file per the schema) of evocative action verbs and theme nouns for meaning prompts.
- [ ] **Step 3:** Author `sheet-template.md` — a minimal generic sheet (name, concept, a few freeform stats, notes).
- [ ] **Step 4:** Author `adapter.md` — front-matter `name: generic`, `dice: ["1d100"]`, `tone: system-agnostic`; body: resolution rules ("when the fiction asks a yes/no question, roll the yes-no oracle; for inspiration, roll action-theme; the player brings any system's mechanics"), `sheet: sheet-template.md`, default safety tools (lines/veils prompt).
- [ ] **Step 5: Verify** `python3 -c "import json,glob; [json.load(open(f)) for f in glob.glob('plugins/gm/adapters/generic/oracles/*.json')]"` succeeds, and `bin/roll oracle --table plugins/gm/adapters/generic/oracles/yes-no.json --seed 3` prints a band.
- [ ] **Step 6: Commit:** `[#5] (Claude Code + Opus 4.8) gm: generic Mythic-style oracle adapter`

---

## Task 9: `skills/gm/SKILL.md` — the core engine

**Files:** Create `plugins/gm/skills/gm/SKILL.md`

**Interfaces:**
- Consumes: the three reference docs, the adapter contract, `bin/roll`.
- Produces: the operating instructions the commands invoke.

- [ ] **Step 1:** Author the SKILL.md front-matter (`name: gm`, a `description` that triggers on solo-RPG/GM/"run a campaign" intents) and body covering, concretely: (a) **session start** — read `campaign.md`, load the named adapter (resolve `extends` per the contract; generic has none), read state, produce a "Previously…" recap; (b) **the play loop** — frame scene → "what do you do?" → decide if a roll is needed → consult the adapter's resolution rules → call `bin/roll` (show the exact command form, e.g. `roll oracle --table <adapter>/oracles/yes-no.json`) → apply outcome + GM-craft → write state deltas; (c) **Rule 0** verbatim and load-bearing; (d) **wrap** — write the session log + recap, persist deltas. Point to the reference docs rather than restating them.
- [ ] **Step 2: Verify** every filename/command in SKILL.md matches `state-schema.md`, `adapter-contract.md`, and the real `bin/roll` invocation (grep for mismatches).
- [ ] **Step 3: Commit:** `[#5] (Claude Code + Opus 4.8) gm: core SKILL.md (play loop + Rule 0)`

---

## Task 10: `commands/` — the four slash commands

**Files:** Create `commands/new-campaign.md`, `commands/play.md`, `commands/wrap.md`, `commands/oracle.md`

- [ ] **Step 1:** `new-campaign.md` — instruct: ask for setting/system + adapter (default `generic`) + saves location; scaffold the state files (Task 5 schema) in the user's chosen dir; generate truths + a starting character via the adapter's sheet template. (Git init is M4 — note it as a no-op placeholder here.)
- [ ] **Step 2:** `play.md` — load the gm skill, run session-start + the loop for the campaign at the given/most-recent saves path.
- [ ] **Step 3:** `wrap.md` — run the wrap flow (log + recap + persist).
- [ ] **Step 4:** `oracle.md` — a quick one-off: `roll oracle` on the active adapter's yes-no (or a named table) and narrate, without a full session.
- [ ] **Step 5: Verify** each command references only files/commands that exist after Tasks 1–9.
- [ ] **Step 6: Commit:** `[#5] (Claude Code + Opus 4.8) gm: new-campaign/play/wrap/oracle commands`

---

## Task 11: End-to-end smoke + no-prompt verification

**Files:** Create `plugins/gm/README.md`; Create `plugins/gm/examples/embervale/` (a tiny example campaign in the Task-5 schema)

**Interfaces:**
- Produces: proof the MVP is playable and `bin/roll` never prompts.

- [ ] **Step 1:** Author a tiny example campaign under `examples/embervale/` (campaign.md with `adapter: generic`, one character, one open thread, one clock) as a smoke fixture.
- [ ] **Step 2: Dice smoke:** from the repo root run `plugins/gm/bin/roll 2d6+1` and `plugins/gm/bin/roll oracle --table plugins/gm/adapters/generic/oracles/yes-no.json` — both print visible dice/results, exit 0.
- [ ] **Step 3: No-prompt check:** confirm the allowlist form. With the plugin enabled, the play loop calls bare `roll …` (PATH); verify the allowlist string (`Bash(roll:*)` or the resolved bundled path) matches that exact form so no permission prompt fires. If the manifest can't carry the allowlist, document the one-line settings entry in README and confirm empirically.
- [ ] **Step 4: Full pytest:** `pytest plugins/gm/tests/ -v` → all green.
- [ ] **Step 5:** Author `README.md` — install, `/gm:new-campaign`, `/gm:play`, the dice CLI, and the allowlist note.
- [ ] **Step 6: Commit:** `[#5] (Claude Code + Opus 4.8) gm: example campaign + README + e2e smoke`

---

## Milestone exit criteria

- `pytest plugins/gm/tests/` green (dice grammar, modes, oracle, seed determinism).
- A player can `/gm:new-campaign` (generic) → `/gm:play` a beat that triggers a real `bin/roll` → `/gm:wrap`, with state written to their chosen dir and **no permission prompt** on the roll.
- No engine logic in the adapter; no improvised numbers in the loop (Rule 0); state lives in the user's space.
- Then: plan **M2 (Ironsworn family)** against these concrete interfaces (`bin/roll` modes, the adapter contract + `extends:`, the oracle JSON shape).
