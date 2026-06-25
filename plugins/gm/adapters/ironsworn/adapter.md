---
name: ironsworn
extends: ironsworn-core
dice: ["ironsworn-action", "1d100"]
tone: low-fantasy Ironlands survival
---

# Ironsworn — the Ironlands

The Ironlands are a savage, unclaimed frontier: dark forests of ancient oak and pine, scarred mountains, windswept coasts, and cursed iron bogs. You are an Ironsworn — a wanderer bound by iron vows, fighting to protect the people and places you love in a world that offers little warmth and no mercy. Magic is rare and ambiguous; the gods are silent; the land itself seems to resist settlement. Every vow you swear is a matter of life and honour.

This adapter extends `ironsworn-core` and adds the Ironlands' oracles, moves, and assets. All action rolls, progress tracks, momentum, and the character sheet are defined in the base — see `ironsworn-core/adapter.md`.

## Resolution in the Ironlands

When the fiction demands a mechanical answer, follow the base engine (`ironsworn-core/adapter.md`):

- **Action moves** resolve with `roll ironsworn-action --stat <value> --adds <N>` (action die + stat + adds vs. two challenge dice). Pass the **numeric value** of the relevant stat (edge / heart / iron / shadow / wits), e.g. `roll ironsworn-action --stat 2 --adds 0`  # using your wits value of 2.
- **Progress moves** (fulfil a vow, reach a milestone, journey's end, fight resolution) roll only the challenge dice against the filled progress boxes.
- **Momentum burns** improve outcomes as the base describes.

### The Ironsworn move list

See `rules/moves.md` for the full curated move set. Reference moves by name; the core resolves the roll.

### Oracle use

Use the oracles in `oracles/` to answer open questions and spark the fiction:

| When you need… | Roll |
|---|---|
| A complication or unexpected action | `oracles/action.json` + `oracles/theme.json` together |
| A region or terrain | `oracles/region.json` |
| A place or landmark | `oracles/location.json` |
| An Ironlander NPC name | `oracles/character-name.json` |
| The cost of failure or danger | `oracles/pay-the-price.json` |

Read `action` + `theme` as a two-word prompt (e.g. *Threaten / Darkness* → an enemy is using fear as leverage). Interpret liberally — the words are a spark, not a literal directive.

### How a turn goes

1. **Establish the scene** — where are you, what's pressing?
2. **Player declares intent** — what do they attempt?
3. **Pick the move** (from `rules/moves.md`) that fits the intent.
4. **Roll** — `roll ironsworn-action --stat <value> --adds <N>`. Pass the numeric value of the stat (e.g. `--stat 3`). The base engine resolves strong hit / weak hit / miss.
5. **Narrate the outcome** — honour the dice (Rule 0). On a miss, consult `oracles/pay-the-price.json` or choose the most interesting consequence.
6. **Update tracks** — health, spirit, supply, momentum, progress.
7. **Advance the fiction** — what changes? What new trouble rises?

When the two challenge dice **match**, add a twist: extra fortune on a hit; something darker stirs on a miss.

## Safety

Open play with **lines & veils**: ask what is off-limits entirely (lines) and what happens off-screen (veils). The Ironlands is a world of hardship and loss — discuss comfort levels with dark themes (death, betrayal, horror) before the first session. Honour those bounds without exception.
