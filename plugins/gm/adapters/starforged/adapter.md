---
name: starforged
extends: ironsworn-core
dice: ["ironsworn-action", "1d100"]
tone: space-opera frontier
sheet: sheet-template.md
---

# Ironsworn: Starforged

The **Forge** is a perilous galaxy where your people fled a cataclysm and settled. You are an **Ironsworn**: a spacer bound to your vows, making your way through the dark between stars aboard your ship, forging connections with those you meet, and leaving your mark on a hostile galaxy.

## What this adapter provides

The full Starforged SRD content, generated from Datasworn (see `SOURCE.md`), plus the rulebook's campaign-launch procedures:

- **`rules/moves.md`** — every move (session, adventure, quest, connection, exploration, combat, suffer, recover, threshold, legacy, fate, scene challenge), with the tables they roll on.
- **`rules/assets.md`** — the asset index; the cards are in `rules/assets/<category>.md` (command vehicle, module, support vehicle, path, companion, deed).
- **`rules/truths.md`** — the 14 setting truths, each rollable as `oracles/truths/<truth>.md`.
- **`rules/encounters.md`** — the SRD's sample NPCs and foes: rank, features, drives, tactics, variants, quest starter. A foe's rank comes from here, never improvised.
- **`oracles/`** — every Starforged oracle table, nested by collection (`oracles/settlement/trouble.md`, `oracles/planet/desert/atmosphere.md`, …). **`rules/oracles.md`** indexes them all. The core oracles sit at the top: `oracles/action.md`, `oracles/theme.md`, `oracles/descriptor.md`, `oracles/focus.md`.
- **`rules/campaign-launch.md`**, **`rules/character-creation.md`**, **`rules/sector-creation.md`** — the rulebook's step-by-step campaign launch (truths, character, starting sector, inciting incident).
- **`sheet-template.md`** — the Starforged character sheet (stats, meters, impacts, legacy tracks).

## Resolution

All resolution uses the `ironsworn-core` engine — see `ironsworn-core/adapter.md`:

> `roll ironsworn-action --stat <value> --adds <N>`   # <value> is the numeric stat (e.g. `--stat 2` for edge 2)
>
> `roll ironsworn-progress --boxes <filled boxes>`     # progress moves, and Continue a Legacy

Each move in `rules/moves.md` names its roll and its stat; a move's outcome text is the whole rule. Don't restate or simplify it.

- **Ask the Oracle** (yes/no): pick the odds, then roll its table: `oracles/moves/ask-the-oracle/small-chance.md`, `oracles/moves/ask-the-oracle/unlikely.md`, `oracles/moves/ask-the-oracle/fifty-fifty.md`, `oracles/moves/ask-the-oracle/likely.md`, or `oracles/moves/ask-the-oracle/almost-certain.md`. On a match (both digits the same: 11, 22 … 99, or 100), envision an extreme result or twist.
- **A spark:** `oracles/action.md` + `oracles/theme.md` (a goal, situation or event), or `oracles/descriptor.md` + `oracles/focus.md` (a location, discovery or encounter), as each table's summary says.
- **Pay the Price:** `oracles/pay-the-price.md`, when no more specific consequence fits.
- **Harm** is the suffer moves: Endure Harm, Endure Stress, Withstand Damage, Companion Takes a Hit, Lose Momentum, Sacrifice Resources. Impacts are marked on the sheet.

## Genre guidance

- **Your ship** is the STARSHIP command vehicle asset (`rules/assets/command-vehicle.md`), with its own integrity meter. When it takes a hit, Withstand Damage.
- **Connections** are the people you meet: Make a Connection, Develop Your Relationship, Test Your Relationship, Forge a Bond.
- **Travel** follows a passage with Set a Course, or charts the unknown with Undertake an Expedition, Explore a Waypoint and Finish an Expedition.
- **Places** come from the oracles: settlements, planets, derelicts, precursor vaults, creatures, and location themes. Pick the collection in `rules/oracles.md`.
- **The Forge is dangerous.** Fail forward (see `gm-craft.md`). A miss always moves time forward and changes the situation.

## Safety

Use the session moves for safety: **Set a Flag** marks lines and veils (content to omit or keep off-screen) at any point, and **Change Your Fate** adjusts flagged content when it comes up (`rules/moves.md`, Session Moves). The Forge contains violence, loss and despair, so calibrate before play.
