---
name: sundered-isles
extends: starforged
dice: ["ironsworn-action", "1d100", "1d10"]
tone: age-of-sail archipelago adventure
sheet: sheet-template.md
---

# Ironsworn: Starforged — Sundered Isles

The **Sundered Isles** are an archipelago of untold islands scattered across perilous seas, under the twin moons Cinder and Wraith. You are **Ironsworn**: a seafarer bound to your vows and a rebel against the powers that would rule the isles, sailing a ship of your own (or hoping to), forging bonds among the islanders, and uncovering what the Sundering left behind.

*This file summarizes rules from the Sundered Isles Guidebook, with page references to the edition named in `SOURCE.md`. It is licensed CC BY-NC-SA 4.0 (see `SOURCE.md`).*

## What this adapter provides

Sundered Isles is an expansion of Starforged, so this adapter `extends: starforged` and carries only what the expansion adds or changes. The Sundered Isles content is generated from Datasworn (see `SOURCE.md`), plus the Guidebook's campaign-launch procedures:

- **`rules/moves.md`** — the whole move list: Starforged's moves, with the Sundered Isles versions of the eight it rewrites (Undertake an Expedition, Make a Discovery, Confront Chaos, Set a Course, Enter the Fray, Withstand Damage, Resupply, Repair) in their place.
- **`rules/assets.md`** — the asset index: the Sundered Isles cards (`rules/assets/sundered-isles/<category>.md`) and the Starforged cards, which still apply (`rules/assets/<category>.md`, from the starforged adapter).
- **`rules/truths.md`** — the 11 Sundered Isles truths, each rollable as `oracles/truths/<truth>.md`, with their suggested assets and factions.
- **`oracles/`** — every Sundered Isles oracle table, nested by collection (`oracles/island/landscape/terrain.md`, `oracles/seafaring/peril.md`, …). **`rules/oracles.md`** indexes every table in force: the Sundered Isles ones, then the Starforged ones the expansion keeps.
- **`rules/campaign-launch.md`**, **`rules/character-creation.md`**, **`rules/sector-creation.md`** — the Guidebook's launch exercises: realm, truths, factions, character, command, starting waters, first scene. They replace Starforged's.
- **`sheet-template.md`** — the character sheet, with your ship's integrity and hold.

### How it layers on Starforged

Files resolve along `extends:`, this adapter's first. A table only Starforged ships rolls from `${CLAUDE_PLUGIN_ROOT}/adapters/starforged/oracles/<path>`.

- Where Sundered Isles **replaces** a Starforged table, its table sits at the Starforged table's path, so every reference to the old table reaches the new one. That's why the Sundered Isles Character Roles table is `oracles/character/role.md` and Moniker is `oracles/character/name/callsign.md`; `rules/oracles.md` notes each one.
- A replaced Starforged table with no Sundered Isles counterpart (Starforged's faction tables, its combined Character Name table) is a one-line redirect here: rolling it names the replacement.
- Sundered Isles' Settlement Location, First Look and Name tables take the paths of Starforged's same-named tables. For a starfaring campaign that wants Starforged's, roll them from the starforged adapter.

## Resolution

All resolution uses the `ironsworn-core` engine, as in Starforged (see `ironsworn-core/adapter.md`):

> `roll ironsworn-action --stat <value> --adds <N>`   # <value> is the numeric stat (e.g. `--stat 2` for edge 2)
>
> `roll ironsworn-progress --boxes <filled boxes>`     # progress moves, and Continue a Legacy

Each move in `rules/moves.md` names its roll and its stat; a move's outcome text is the whole rule. Don't restate or simplify it.

- **Ask the Oracle** (yes/no): pick the odds and roll its table, `oracles/moves/ask-the-oracle/<odds>.md` (`small-chance`, `unlikely`, `fifty-fifty`, `likely`, `almost-certain`).
- **A spark:** the Sundered Isles core oracles, `oracles/action.md` + `oracles/theme.md`, or `oracles/descriptor.md` + `oracles/focus.md`.
- **Pay the Price:** `oracles/moves/pay-the-price.md`, when no more specific consequence fits.
- **Regions.** The isles divide into the Myriads (widely settled), the Margins (scattered) and the Reaches (remote and strange) (p. 8). Tables keyed by region have one file per region (`oracles/settlement/size/margins.md`): roll the one for where you are. In another realm, read them as inhabited, frontier and remote (p. 112).
- **Multiple rolls.** A result of "Roll twice" means roll twice more and combine; if that brings another "Roll twice", reroll it (p. 112).

### The cursed die

The cursed die is an optional d10, rolled alongside the oracle dice when you consult a table that has a cursed version (p. 114). Use it when your truths let curses, the supernatural or strange technologies into the isles, or once the story has woken them; ignore it in a grounded setting.

- `roll 1d10` with the table's roll. On a **10**, the answer is cursed: each such table's file says what to do, which is usually to read the same roll on its cursed table (`oracles/ship/first-look.md` → `oracles/ship/first-look-cursed.md`). `rules/oracles.md` lists the cursed table next to each table that has one.
- To tune the odds to the situation, trigger on 9–10 or 8–10, add one or two more cursed dice (a 10 on any of them curses the answer), or use a d4, d6, d8, d12 or d20 as the cursed die and curse on its highest face (p. 115).
- With tables that have no cursed version, such as Action and Theme, or with Ask the Oracle, a cursed result can give the answer a dreadful or uncanny twist (p. 115).
- When a curse is obviously the interesting answer, skip the cursed die and go straight to the cursed table. Once a place or encounter is set as mundane, leave the cursed die out of its details (p. 115).

## Genre guidance

- **Your ship.** You may begin with a SAILING SHIP (an incidental vehicle, not a character asset), the FLAGSHIP command vehicle, or no command at all (`rules/character-creation.md`, step 7). A ship's integrity takes damage through Withstand Damage and is mended with Repair. For the nature of a hard hit, roll `oracles/misc/ship-damage.md` (p. 16).
- **Two kinds of supply** (pp. 26–27). *Hold supply* (the ship's stores: food and water, powder and shot, timber and sailcloth) and *equipped supply* (what you and your allies carry: the sheet's supply meter) each run 0–5. A move that touches supply uses whichever the fiction calls for, never both at once: hold supply for shipwide actions, equipped supply for your own. If either falls to 0, mark unprepared; if both do, mark a second unprepared. Losing your ship loses its hold supply too. The Sundered Isles Resupply lets you gear up from the ship's stores.
- **The crew** is a whole, not a roster: envision its makeup (`rules/character-creation.md`, step 7) and give a crewmember a name when they matter. Connections are not crewmates unless you take the COHORT deed (p. 24).
- **Factions** drive the isles: empires, societies, organizations, the cursed (`oracles/adventures/factions/`, `oracles/faction/`). Their influence in your waters sets who controls a settlement and whose sails are on the horizon (`rules/sector-creation.md`, step 2).
- **Places** come from the oracles: islands, overland regions, settlements, ships, shipwrecks, caves, ruins, treasure and weather. Pick the collection in `rules/oracles.md`.
- **The isles are perilous.** Fail forward (see `gm-craft.md`). A miss always moves time forward and changes the situation.

## Safety

Use the session moves: **Set a Flag** marks lines and veils (content to omit or approach mindfully) at any point, and **Change Your Fate** adjusts flagged content when it comes up (`rules/moves.md`, Session Moves). The Guidebook also asks you to build the isles mindfully (p. 66): prioritize diversity; don't depict any people of the isles as monolithic, primitive or exotic; treat imperial powers as the enemy, never something your character serves; and don't assume slavery exists in the setting. If it does, flag it, and never trivialize or romanticize it.
