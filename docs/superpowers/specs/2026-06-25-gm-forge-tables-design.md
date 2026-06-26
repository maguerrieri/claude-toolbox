# gm — General table system + deep-oracle forge

- **Issues:** foundation = TBD (PR 1); forge = #11 (PR 2)
- **Status:** Design (brainstormed 2026-06-25)
- **Ships as a 2-PR stack:** PR 1 (the general Markdown **table system**, incl. migrating the shipped oracles) → PR 2 (the **forge** + promote-seal, stacked on it).
- **Composes:** the dice CLI (`bin/roll`), campaign git + the GM screen (`bin/campaign gm-*`, `.gm/`), and the **`generate`** plugin (soft dependency, forge only).

## Problem

A solo GM mode-collapses. Asked for "five NPCs in the tavern" or "what weird thing grows here," an LLM produces near-duplicates of one archetype. The `generate` plugin beats this (frame → diverse lens-varied passes → axis-tagged reservoir), but the GM can't *use* it: nowhere to store a pool as a rollable table, no roll under Rule 0, no bridge from generate's divergent reservoir to the GM's occasional need to converge on one canonical secret.

There's also a latent incoherence: gm already has **oracles** (`adapters/*/oracles/*.json`, weighted ranges, `roll oracle --table`). A forge that invents its *own* parallel table concept would leave two "things you roll on" wearing different coats. So the foundation here is **one general table system**; the forge is just one way tables get populated.

## Decided (from brainstorming)

- **One general table system**, format = **Markdown** (migrate the shipped JSON oracles to it). The forge *adds to* it; tables can equally be hand-authored or adapter-shipped.
- **Both forge modes:** prep-time forge (default) + opt-in mid-play pull.
- **All three subsystems in v1**, shipped as a **foundation → forge** PR stack.
- **Soft coupling** to `generate` (forge only). Tables persist in the campaign; secret pools seal behind the GM screen.

## Non-goals

- Forge is a **breadth** tool, not a replacement for a bespoke set-piece (a crafted villain still beats a pool).
- **No** hard dependency on `generate` — the forge degrades to a GM-improvised list when it's absent; the table system itself never depends on generate.
- **Not** mid-beat by default — the forge is prep-weight; *pull* is an explicit, opt-in pause.
- **No** modification to `generate`'s core loop — we *harvest* its output and add a Promotion adapter; we don't fork it.

---

## Foundation — the table system (general, Markdown) — **PR 1**

One first-class concept: a **table** is a named, rollable list. Sources: **adapter-shipped** (the migrated oracles), **hand-authored** by the player, or **forged** (PR 2). Independent of `generate`.

### Format

A table is a markdown list; each entry is one list item:

```
# Yes / No        ← optional header / provenance; non-"- " lines are ignored by the roller
- [50] No
- [50] Yes
```

- `- entry` → weight 1. `- [w] entry` → weight `w` (positive int). Bare list = **uniform**; bracketed = **weighted**.
- Lines not starting with `- ` (headers, a forge frame's axes, prose) are ignored — so a table can carry provenance without confusing the roller.

### Roll

```
roll table <file> [--n K] [--seed S] [--json]
```

- `N = Σ weights`; roll `1..N` true-RNG (`secrets`); cumulative-map → the entry. Visible (Rule 0): `🎲 table 73/100 → <entry>`.
- `--n K` → K **distinct** draws; `--seed` deterministic; `--json` → `{"file","total","picks":[...]}`.
- All-weight-1 table = uniform draw (the forge case). `roll oracle` is kept as a **deprecated alias** of `roll table` so existing muscle memory / external refs don't break.
- Empty/missing file → clear error + non-zero exit (matches `roll`'s style).

**Why the count model:** gaps/overlaps — the bug class the JSON validator existed to catch — become **structurally impossible** (every integer `1..N` maps to exactly one entry). Coverage is automatic.

### Storage

- Adapter tables: `adapters/<name>/oracles/*.md` (migrated from `*.json`).
- Campaign tables: `<campaign>/tables/<type>.md` (player-facing) and `<campaign>/.gm/tables/<type>.md` (sealed — rides the GM screen; drawn via Bash so it stays collapsed in the transcript).

### Migrate the shipped oracles (JSON → MD)

Mechanical and **behavior-preserving**: each JSON row `{max, result}` → `- [max − prev_max] result` (e.g. `yes-no.json` → `- [50] No` / `- [50] Yes`; a 100-row d100 table → 100 entries). The multi-table meaning oracle (`action` + `theme`) stays two files, rolled together.

- Rewrite every `adapters/*/oracles/*.json` → `*.md`; update the `oracles/...` references in each `adapter.md` (and SKILL examples) to `.md` + `roll table`.
- **Validator** (`bin/validate-adapter`): the oracle checks (ascending/no-dup/full-coverage of the die) **retire**; replace with the MD-table lint — ≥1 `- ` entry, weights positive ints, referenced table files exist.

*Depends on:* `bin/roll`, the campaign dir. **Not** `generate`.

---

## Forge — build/expand a table via `generate` — **PR 2** (②)

Turns "I want a diverse pool of `<type>`" into a populated foundation table.

**Invocation** — a skill step + `/gm:forge <type> [--secret] [--n N]`:
1. Resolve the **frame**: a bundled *starter frame* if one exists, else the GM frames `<type>` on the fly per generate's `frame` mode.
2. Run the `generate` skill (frame → 3–4 lens-varied passes → axis-tagged reservoir).
3. **Harvest** the reservoir entries into a foundation table (`tables/<type>.md`, or `.gm/tables/<type>.md` with `--secret`) — as uniform `- ` entries, keeping the axis tags as trailing text.

**Modes.** *Prep forge* (default) at session zero / new region / `/gm:wrap`. *Pull* (escape hatch) mid-play, which **pauses** the table (~minutes of subagents) — explicit, not reflexive; the GM announces the pause.

**Soft coupling / graceful degradation.** If `generate` is present, use it; if absent, the forge degrades to a GM-improvised ~6–10 list into the same table file, surfaced to the player. The foundation still rolls either way.

**Starter frames** at `${CLAUDE_PLUGIN_ROOT}/forge/frames/<type>.md` (generate frame format): **npc, rumor, hook, location, faction, oddity**. Anything else framed on the fly.

**Reservoir reconciliation.** generate writes reservoirs to `docs/generation/<type>.md` relative to cwd; the forge runs it in a scratch cwd and harvests the new entries into the durable campaign table. The reservoir is scratch; the table is the versioned artifact.

*Depends on:* the foundation + `generate` (soft).

---

## Promote → seal — the convergent case — **PR 2** (③)

`generate` is judgment-OFF (divergent). When the GM needs **one** canonical answer (the villain, the secret behind the mystery), that convergence routes through generate's **Promotion adapter** seam, composed with the GM screen.

gm ships a Promotion adapter at `${CLAUDE_PLUGIN_ROOT}/forge/promotion/campaign.md` and points generate's `Promotion:` directive at that **path** when forging-to-converge. Per generate's op contract:
- **`OPEN(type, slot, rivals)`** — decide the contested canonical `slot` (the GM picks, or `roll table`s among `rivals`) and **seal** it: `campaign gm-seal <campaign> <slot> "<chosen entry>"` into `.gm/`. Return the seal ref.
- **`BACKLINK(ref)`** — note in the campaign (a `tables/<type>.md` cold-storage line) that `<slot>` sealed to `<ref>`, preserving the rejected rivals.

**Flow:** forge candidates → convergence request fires generate's promotion → the `campaign` adapter seals the winner behind the screen → reveal when the fiction earns it (`campaign gm-reveal`). Losers stay, reusable.

*Depends on:* generate's promotion seam + the GM screen + the foundation.

---

## Data flow

| Situation | Path |
|---|---|
| Roll on any table | `roll table <file>` — adapter oracle, hand-authored, or forged; all one verb |
| Prep variety | `/gm:forge <type>` (②) → `<campaign>/tables/` → `roll table` in play |
| Mid-play novelty | pull-forge (②, explicit pause) → `roll table` |
| Need a canon secret | forge candidates (②) → promote → seal (③) → reveal when earned |
| No `generate` | ② degrades to a GM-improvised list → the foundation still rolls |

## Components / files

**PR 1 — foundation:**
- `plugins/gm/bin/roll` — add `table` (weight-aware) + `oracle` alias; tests.
- `plugins/gm/adapters/*/oracles/*.md` — migrated from `*.json`; update `adapter.md` references.
- `plugins/gm/bin/validate-adapter` — retire oracle-coverage checks; add MD-table lint.
- `plugins/gm/skills/gm/references/{adapter-contract,state-schema}.md` + `SKILL.md` — table format, `roll table`, `tables/` + `.gm/tables/`.
- `plugins/gm/.claude-plugin/plugin.json` — **0.2.0 → 0.3.0**.
- Tests: `roll table` (weighted/uniform/`--n`/`--seed`/`--json`/errors); **migration parity** (each migrated oracle's distribution == the old JSON's); validator MD-table lint.

**PR 2 — forge (stacked):**
- `plugins/gm/forge/frames/{npc,rumor,hook,location,faction,oddity}.md`; `plugins/gm/forge/promotion/campaign.md`.
- `plugins/gm/commands/forge.md` (`/gm:forge`).
- `plugins/gm/skills/gm/SKILL.md` + a new `references/forge.md` — forge (prep/pull), soft-coupling/degradation, promote-to-seal.
- `plugins/gm/.claude-plugin/plugin.json` — **0.3.0 → 0.4.0**.
- Tests: forge harvest format; degraded path; promotion seal round-trip.

## Error handling / edge cases

- `roll table` on empty/missing → clear error, non-zero exit.
- Migration must be **provably behavior-preserving** — parity tests are the safety net for touching shipped, tested oracles.
- `generate` absent → forge degrades; surfaced to the player.
- Sealed tables drawn via Bash (stay behind the screen); the draw's stdout shows only the *drawn* entry.
- Reservoir is scratch; only the harvested table is versioned (`campaign checkpoint` commits `tables/` + `.gm/`).

## Testing strategy

- **Unit** (pytest): `roll table` modes/errors; migration parity; validator MD lint; forge harvest; promotion seal round-trip.
- **Smoke:** roll a migrated oracle; forge a tiny table (generate present) → `roll table`; degraded forge; promote → seal → `gm-reveal`.
- **CI:** existing gm-ci (pytest + validators) covers both PRs.

## Open questions for spec review

1. **Roll verb:** primary `roll table`, keep `roll oracle` as a deprecated alias — OK? (Or rename hard and update all refs only.)
2. **Entry granularity:** one `- ` line = one entry (optional trailing tag); multi-line entries deferred. OK?
3. **Command surface:** ship both `/gm:forge` and SKILL guidance (explicit + emergent). OK?
4. **Starter frames:** npc, rumor, hook, location, faction, oddity — add/cut any?
5. **Pull-mode guardrail:** GM may decide to pull-forge mid-play but must announce the pause (vs. requiring your explicit opt-in each time). OK?
