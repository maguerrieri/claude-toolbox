# Adapter contract

An **adapter** teaches the gm core one game's *rules* — its dice, oracles, moves, and sheet — as **declarative data**. The core stays system-agnostic; an adapter holds no engine logic, only data and the prose rules the core follows.

## Folder

```
adapters/<name>/
  adapter.md          # manifest (front-matter) + resolution rules (prose)
  oracles/*.json      # oracle tables the core rolls on (see "Oracle tables")
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
---
```
Body (prose the core follows):
- **Resolution rules** — when the fiction needs a mechanical answer, which oracle/roll applies and how its result maps to an outcome. Written as instructions, e.g. *"For a yes/no question, roll `oracles/yes-no.json`; on a 'Yes, and' grant a bonus, on a 'No, and' add a complication."*
- **Safety defaults** — lines & veils prompts, tone guardrails.

## Oracle tables (`oracles/*.json`)

The exact shape `bin/roll oracle --table <path>` reads:
```json
{
  "die": "1d100",
  "rows": [
    { "max": 50, "result": "No" },
    { "max": 100, "result": "Yes" }
  ]
}
```
- `die` — a simple `NdX` dice expression (e.g. `1d100`, `2d6`); oracle dice don't take modifiers / keep-drop / exploding.
- `rows` — ascending by `max` with no duplicates, covering the die's full range (`min..max` — e.g. `1..100` for `1d100`). The first row whose `max ≥ roll` wins.

A meaning/inspiration oracle may be **split across tables read together** (e.g. `action.json` + `theme.json`) rather than packed into one file.

## Composition (`extends:`)

An adapter may `extends:` a base adapter (e.g. `ironsworn` and `starforged` both extend `ironsworn-core`). The core resolves the chain **parent → child**:
- **Manifest keys:** the child overrides the parent on collision (child wins).
- **Data files** (`oracles/`, `rules/`): unioned **by id / filename** — the child adds new entries and overrides any the parent defined under the same id.

A base adapter may be marked `abstract: true` in its front-matter (not playable on its own — a campaign must name a concrete variant that extends it); a variant supplies the genre data. The `generic` adapter uses no `extends`.

## The one hard rule

**No engine logic in an adapter.** An adapter is data + declarative resolution prose. The play loop, dice, and state handling live in the core — never copied into an adapter. (Personas, likewise, never change numbers — they're a separate, voice-only dimension.)
