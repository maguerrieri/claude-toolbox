---
name: ironsworn-core
abstract: true
dice: ["ironsworn-action", "1d100", "1d10", "1d6"]
tone: forged mythic
sheet: sheet-template.md
visibility: player
---

# Ironsworn engine (base)

The shared engine for the Ironsworn family (`ironsworn`, `starforged`, …). It is **abstract** — never played on its own; a variant supplies the oracles, moves, assets, and genre. This base defines only the resolution mechanics they all share, as both rulebooks give them: page numbers below are *Ironsworn* (classic) and *Starforged*.

## The action roll

Most moves resolve with an **action roll**: `roll ironsworn-action --stat <value> --adds <N>` — pass the **numeric value** of your stat (e.g. `--stat 2`), not the stat's name. Your action die (1d6) plus the stat value plus any adds form the **action score** (capped at 10), compared against two **challenge dice** (2d10). The score must beat a die, not equal it: ties go to the challenge dice (classic pp. 8–9; Starforged pp. 32–33).

- **Strong hit** (score beats *both* challenge dice): you do it well — take the better outcome.
- **Weak hit** (beats *one*): you do it, but with a cost, complication, or partial result.
- **Miss** (beats *neither*): it goes wrong — the GM makes a move and you may pay a price (see `gm-craft.md`: fail forward).
- **Match** (the two challenge dice show the same number): a prompt for a twist, unless the move or an asset gives a match its own result. On a strong hit, make it a turn in the story or a new opportunity; on a miss, a heightened danger or complication, things getting worse in an unexpected way (classic pp. 9–10; Starforged p. 34).

## Progress moves

Vows, journeys, fights, and other extended efforts use a **progress track** (10 boxes). You mark progress by rank (troublesome → epic) as you advance:

| Rank | Boxes per milestone |
|---|---|
| Troublesome | 3 boxes |
| Dangerous | 2 boxes |
| Formidable | 1 box |
| Extreme | 2 ticks (½ box) |
| Epic | 1 tick (¼ box) |

To *resolve* a progress track, **roll the challenge dice only** — `roll ironsworn-progress --boxes <filled-boxes>` — and compare your fully filled boxes (a partly ticked box doesn't count) to each die: beat both = strong hit, one = weak hit, neither = miss. Momentum is ignored on a progress roll: you can't burn it, and negative momentum doesn't cancel anything (classic pp. 14–18; Starforged pp. 40–43).

## Momentum

You carry a **momentum** track (−6…+10). After an action roll you may **burn momentum** when it's positive: if your current momentum beats a challenge die your score didn't, use your momentum in place of your action score to improve the outcome (classic phrases this as cancelling each challenge die below your momentum: the same result), then reset momentum to its reset value. When momentum is negative and your action die shows the same number (−3 and a 3), the action die is cancelled: your score is just your stat plus adds (classic pp. 11–13; Starforged pp. 35–38).

## Vows

You **swear iron vows** — formal commitments tracked as progress. Fulfilling a vow is a defining move; forsaking one carries weight in the fiction.

## Sheet

See `sheet-template.md`: five stats (**edge, heart, iron, shadow, wits**), the **health / spirit / supply** condition meters, a **momentum** track, and your **vows** as progress tracks. It's the part both games share; `ironsworn` and `starforged` each ship a full sheet of their own (debilities and bonds, or impacts and legacy tracks), and a variant without one inherits this.

## For variant authors

A variant `extends: ironsworn-core` and adds `oracles/` (genre tables), `rules/` (the move list + assets), and overrides `tone`/`sheet` as needed. Do **not** restate these mechanics — reference them.
