---
name: starforged
extends: ironsworn-core
dice: ["ironsworn-action", "1d100"]
tone: space-opera frontier
---

# Ironsworn: Starforged

The **Forge** is a perilous expanse of star systems beyond the settled regions of known space — a place of wonder, ruin, and brutal survival. You are an **Ironsworn**: a wanderer bound to your vows, making your way through the dark between stars aboard your ship, forging unlikely connections with those you meet, and fighting to leave your mark on a hostile galaxy.

This is high-stakes sci-fi with mythic weight. Technology is old, strange, and sometimes fails you. Faster-than-light travel exists but carries risk. Ancient precursor vaults hide secrets that may save or doom the Forge. Iron vows are not metaphors — breaking them costs something real.

## What this adapter provides

- **`oracles/`** — Starforged oracle tables for actions, themes, sector and planet generation, ships, factions, character names, and the Pay the Price table. Pair `action.md` + `theme.md` for an inspiration prompt.
- **`rules/moves.md`** — the core Starforged move list with triggers, stats, and outcomes.
- **`rules/assets.md`** — example assets (starships, modules, paths, companions).

## Resolution

All resolution uses the `ironsworn-core` action roll — see `ironsworn-core/adapter.md` for the full mechanic. In brief:

> `roll ironsworn-action --stat <value> --adds <N>`   # <value> is the numeric stat (e.g. `--stat 2` for edge 2)

Beat both challenge dice = **strong hit**. Beat one = **weak hit**. Beat neither = **miss**. Matching challenge dice = **match** (twist: fortune on a hit, deeper trouble on a miss).

Progress tracks, momentum, vows, and the health/spirit/supply/momentum sheet are all defined in `ironsworn-core`. This adapter extends them with Starforged-specific content only.

## Genre guidance

- **Your ship** is a character, not just equipment. It has its own integrity track (analogous to health). When your ship Withstands Damage, mark the track; if it reaches 0 the ship is crippled.
- **Connections** replace classic Ironsworn's bonds. You Make a Connection when you forge a relationship; Develop a Relationship as the fiction deepens it.
- **Expeditions** replace classic journeys. When you Undertake an Expedition you define waypoints, mark progress at each, and Finish the Expedition when you arrive.
- **Precursor vaults** are anomalous, alien ruins. Treat them as extreme-or-epic formidable challenges — enter carefully, question what you find.
- **The Forge is dangerous.** Fail forward (see `gm-craft.md`). A miss always moves time forward and changes the situation.

## When to roll oracles

Use the Starforged oracles when the fiction demands a detail you shouldn't decide alone: a planet you're approaching, an NPC's disposition, a complication aboard your ship. Pair `oracles/action.md` + `oracles/theme.md` for a two-word spark and interpret it into the fiction. Roll `oracles/pay-the-price.md` on a miss if nothing more specific fits.

## Safety

Open a campaign with **lines & veils**: what is off-limits entirely (lines), and what happens off-screen (veils). The Forge contains violence, loss, and despair — calibrate explicitly.
