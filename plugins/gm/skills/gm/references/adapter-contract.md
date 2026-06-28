# Adapter contract

An **adapter** teaches the gm core one game's *rules* — its dice, oracles, moves, and sheet — as **declarative data**. The core stays system-agnostic; an adapter holds no engine logic, only data and the prose rules the core follows.

## Folder

```
adapters/<name>/
  adapter.md          # manifest (front-matter) + resolution rules (prose)
  oracles/*.md        # oracle tables the core rolls on (see "Tables")
  rules/*             # optional: moves, assets, other content
  sheet-template.md   # the sheet schema (optional — a variant may inherit its base's via extends:)
```

## `adapter.md`

Front-matter:
```
---
name: generic
extends: ironsworn-core   # optional — inherit from a base adapter (see "Composition")
dice: ["1d100"]           # dice modes this system uses (bin/roll expressions / named modes)
tone: system-agnostic     # default genre/voice
sheet: sheet-template.md
visibility: player        # player | gm — see "Visibility (the GM screen)"
---
```
Body (prose the core follows):
- **Resolution rules** — when the fiction needs a mechanical answer, which oracle/roll applies and how its result maps to an outcome. Written as instructions, e.g. *"For a yes/no question, roll `oracles/yes-no.md`; on a 'Yes, and' grant a bonus, on a 'No, and' add a complication."*
- **Safety defaults** — lines & veils prompts, tone guardrails.

## Tables (`oracles/*.md`)

Oracle and inspiration tables are **Markdown files** (`roll table <path>` reads them; `roll oracle` is a deprecated alias). Adapters ship tables under `oracles/`; player campaigns keep hand-authored or forged tables in `tables/` (and sealed GM tables in `.gm/tables/`). All three share the same format.

**Entry format — the block rule:**

```markdown
- Result text that can span
  multiple indented lines up to
  the next top-level `- `.

- [3] A weighted entry (weight 3).
  Indented continuation is fine here too.

- Another entry (weight defaults to 1).
```

- An **entry** is a top-level `- ` bullet plus any immediately-indented continuation lines, up to (but not including) the next top-level `- `.
- `- [w]` sets the entry's **weight** (a positive integer; default `1` when the bracket is absent). The format is a plain top-level `- ` list (not inside ``` code fences); `[w]` must be a positive integer — a malformed or negative weight is treated as literal entry text, not a weight.
- **Count model:** `N = Σweights`. The roller assigns each entry a cumulative range of width `w` within `1..N`, then draws `roll 1..N` — gaps are impossible and coverage is automatic. No `die` field, no `max` arithmetic to maintain.

A meaning/inspiration oracle may be **split across tables read together** (e.g. `action.md` + `theme.md`) rather than packed into one file.

## Composition (`extends:`)

An adapter may `extends:` a base adapter (e.g. `ironsworn` and `starforged` both extend `ironsworn-core`). The core resolves the chain **parent → child**:
- **Manifest keys:** the child overrides the parent on collision (child wins).
- **Data files** (`oracles/`, `rules/`): unioned **by id / filename** — the child adds new entries and overrides any the parent defined under the same id.

A base adapter may be marked `abstract: true` in its front-matter (not playable on its own — a campaign must name a concrete variant that extends it); a variant supplies the genre data. The `generic` adapter uses no `extends`.

## Visibility (the GM screen)

`visibility:` declares where this system keeps **GM-mutable world-state** — progress/threat **clocks** and the **answers** behind open questions (a mystery's solution, an NPC's true agenda):

- `player` (**default**) — in the open. The core writes clocks to `clocks.md` and the rest as normal. Player-facing systems like **Ironsworn** and **Starforged** use this: their clocks, momentum, and vows are *meant* to sit in front of the player — there is no screen.
- `gm` — **behind the screen.** The core writes that state through the bundled `campaign gm-*` CLI into a `.gm/` sealed dir, **never the Write/Edit tools** — so in a solo session the write collapses to "Ran 1 shell command" in the transcript instead of rendering its content inline. It surfaces only when the fiction earns it (`campaign gm-reveal`). The **generic** "be my GM for any system" adapter uses this, because the point of a GM emulator is to be *surprised*.

The screen guards against *involuntarily* spoiling a solo player; deliberately expanding a collapsed call to read ahead is a wanted feature (dramatic irony), so `.gm/` is **not** encrypted. See `gm-craft.md` (felt, not shown) and `state-schema.md` (`.gm/`).

## The one hard rule

**No engine logic in an adapter.** An adapter is data + declarative resolution prose. The play loop, dice, and state handling live in the core — never copied into an adapter. (Personas, likewise, never change numbers — they're a separate, voice-only dimension.)
