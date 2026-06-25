---
name: ironsworn-core
abstract: true
dice: ["ironsworn-action", "1d100", "1d10", "1d6"]
tone: forged mythic
sheet: sheet-template.md
visibility: player
---

# Ironsworn engine (base)

The shared engine for the Ironsworn family (`ironsworn`, `starforged`, …). It is **abstract** — never played on its own; a variant supplies the oracles, moves, assets, and genre. This base defines only the resolution mechanics they all share.

## The action roll

Most moves resolve with an **action roll**: `roll ironsworn-action --stat <value> --adds <N>` — pass the **numeric value** of your stat (e.g. `--stat 2`), not the stat's name. Your action die (1d6) plus the stat value plus any adds form the **action score** (capped at 10), compared against two **challenge dice** (2d10).

- **Strong hit** (score beats *both* challenge dice): you do it well — take the better outcome.
- **Weak hit** (beats *one*): you do it, but with a cost, complication, or partial result.
- **Miss** (beats *neither*): it goes wrong — the GM makes a move and you may pay a price (see `gm-craft.md`: fail forward).
- **Match** (the two challenge dice show the same number): a twist — extra fortune on a hit, deeper trouble on a miss.

## Progress moves

Vows, journeys, fights, and other extended efforts use a **progress track** (10 boxes). You mark progress by rank (troublesome → epic) as you advance:

| Rank | Boxes per milestone |
|---|---|
| Troublesome | 3 boxes |
| Dangerous | 2 boxes |
| Formidable | 1 box |
| Extreme | 2 ticks (½ box) |
| Epic | 1 tick (¼ box) |

To *resolve* a progress track, **roll the challenge dice only** — `roll ironsworn-progress --boxes <filled-boxes>` — and compare your filled boxes to each die: beat both = strong hit, one = weak hit, neither = miss.

## Momentum

You carry a **momentum** track (−6…+10). After a roll you may **burn momentum**: if your current momentum beats a challenge die your score didn't, swap your action score for momentum to improve the outcome, then reset momentum to its reset value. Negative momentum cancels an action die that equals it.

## Vows

You **swear iron vows** — formal commitments tracked as progress. Fulfilling a vow is a defining move; forsaking one carries weight in the fiction.

## Sheet

See `sheet-template.md`: five stats (**edge, heart, iron, shadow, wits**), the **health / spirit / supply** condition tracks, a **momentum** track, **bonds**, and your **vows** as progress tracks.

## For variant authors

A variant `extends: ironsworn-core` and adds `oracles/` (genre tables), `rules/` (the move list + assets), and overrides `tone`/`sheet` as needed. Do **not** restate these mechanics — reference them.
