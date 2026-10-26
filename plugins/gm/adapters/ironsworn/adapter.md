---
name: ironsworn
extends: ironsworn-core
dice: ["ironsworn-action", "1d100"]
tone: low-fantasy Ironlands survival
sheet: sheet-template.md
---

# Ironsworn — the Ironlands

The **Ironlands** are a harsh peninsula in the northern ocean, settled two generations ago by people a cataclysm drove from the Old World. You are **Ironsworn**: bound by iron vows, facing long winters, perilous journeys and the dangers of a land that resists its settlers.

## What this adapter provides

The full Ironsworn SRD content, generated from Datasworn (see `SOURCE.md`), with the rulebook's world and foes:

- **`rules/moves.md`** — every move (adventure, relationship, combat, suffer, quest, fate), with the tables they roll on.
- **`rules/assets.md`** — the asset index; the cards are in `rules/assets/<category>.md` (combat talent, companion, path, ritual).
- **`oracles/`** — every Ironsworn oracle table, nested by collection (`oracles/place/region.md`, `oracles/settlement/trouble.md`, `oracles/name/ironlander/a.md`, …). **`rules/oracles.md`** indexes them all. The core oracles sit at the top: `oracles/action.md`, `oracles/theme.md`.
- **`rules/truths.md`** — the 11 world truths, each rollable as `oracles/truths/<truth>.md`.
- **`rules/regions.md`** — the nine regions of the Ironlands.
- **`rules/encounters.md`** — the rulebook's NPCs and foes: rank, features, drives, tactics, quest starter. A foe's rank comes from here, never improvised.
- **`sheet-template.md`** — the Ironsworn character sheet (stats, meters, debilities, bonds).

## Resolution

All resolution uses the `ironsworn-core` engine — see `ironsworn-core/adapter.md`:

> `roll ironsworn-action --stat <value> --adds <N>`   # <value> is the numeric stat (e.g. `--stat 2` for wits 2)
>
> `roll ironsworn-progress --boxes <filled boxes>`     # progress moves, and Write Your Epilogue on the bonds track

Each move in `rules/moves.md` names its roll and its stat; a move's outcome text is the whole rule. Don't restate or simplify it.

- **Ask the Oracle** (yes/no): pick the odds, then roll its table: `oracles/moves/ask-the-oracle/small-chance.md`, `oracles/moves/ask-the-oracle/unlikely.md`, `oracles/moves/ask-the-oracle/fifty-fifty.md`, `oracles/moves/ask-the-oracle/likely.md`, or `oracles/moves/ask-the-oracle/almost-certain.md`.
- **A spark:** `oracles/action.md` + `oracles/theme.md`, read together as a prompt.
- **Pay the Price:** `oracles/moves/pay-the-price.md`, when no more specific consequence fits.
- **Harm you inflict.** A hit with Strike or Clash inflicts 2 harm with a deadly weapon (sword, axe, spear, bow) and 1 harm unarmed or with an improvised or simple weapon (shield, club, staff, rock), unless the move or an asset says otherwise (Rulebook p. 19). Each harm marks progress on the foe's track by its rank, as Enter the Fray lists.
- **Harm and stress you take** are the suffer moves: Endure Harm, Endure Stress, Companion Endure Harm, Face Death, Face Desolation, Out of Supply, Face a Setback. A foe inflicts harm equal to its rank. Debilities are marked on the sheet.

## Genre guidance

- **Journeys** are Undertake a Journey and Reach Your Destination. Rank a journey by distance (Rulebook p. 111): a moderate distance within one region is troublesome; a long one, or rough terrain, dangerous; region to region formidable; across several regions extreme; from one end of the Ironlands to the other, or to another land, epic.
- **Bonds** are the people and communities you're tied to: Forge a Bond, Test Your Bond, Sojourn, and Write Your Epilogue when you retire.
- **Places** come from `rules/regions.md` and the place and settlement oracles (`rules/oracles.md`).
- **Foes** are in `rules/encounters.md`. For a foe's rank when none fits, roll `oracles/turning-point/challenge-rank.md`; for what a foe does next, `oracles/turning-point/combat-action.md`. When a ritual fails, `oracles/turning-point/mystic-backlash.md` offers a backlash (Rulebook p. 44). `oracles/turning-point/major-plot-twist.md` turns a story.
- **The Ironlands are unforgiving.** Fail forward (see `gm-craft.md`). A miss always changes the situation.

## Safety

Open play with **lines & veils**: ask what is off-limits entirely (lines) and what happens off-screen (veils). The Ironlands is a world of hardship and loss — discuss comfort levels with dark themes (death, betrayal, horror) before the first session. Honour those bounds without exception. Your truths set how much of the supernatural is in play (Mysticism, Firstborn, Beasts, Horrors in `rules/truths.md`).
