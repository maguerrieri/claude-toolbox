# Chart Your Course

*Adapted from the* Sundered Isles Guidebook, *"Chart Your Course" (pp. 102–109) and "Faction Influence Grid" (p. 52), © 2024 Shawn Tomkin, licensed [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). Abridged and paraphrased for solo play with this adapter: the book's page references now point at this adapter's tables, and its worksheet and group-play notes are left out. This file is licensed CC BY-NC-SA 4.0 (see `SOURCE.md`).*

This is the adapter's starting-location exercise, in place of Starforged's starting sector: a **navigation chart** of your local waters, with a few islands, a seaside settlement, some notable places and a local connection (the book allows 30–45 minutes). The chart keeps early journeys to a manageable scope; you'll chart new waters as you go. Keep things moving and don't get stuck on details. Ignore or revise any result that contradicts the established facts.

- **The player may skip it** and discover the starting area in play, or start from a place they already have in mind.
- **Skyfaring realm:** the exercise works with a little reimagining. **Starfaring realm:** use Starforged's sector creation instead, `${CLAUDE_PLUGIN_ROOT}/adapters/starforged/rules/sector-creation.md`. Its tables resolve through this adapter, so its settlement location, first look and name tables are this adapter's; roll Starforged's from the starforged adapter.

Record what you make: islands, the settlement and notable places in `locations.md` (with where each lies on the chart), the connection in `npcs.md` and on the sheet, and the region, the faction influence and the area's name under `campaign.md`'s truths.

## 1. Choose your starting region (p. 103)

- **Myriads:** the principal isles, widely settled. Start here for busy trade routes between bustling ports, with an eye out for enemy sails.
- **Margins:** greater distances between islands and settlements. Start here for less-traveled waters and remote places.
- **Reaches:** the most scattered and isolated islands and people, the least familiar seas. Start here for stranger tides.

The region picks the file for the region-keyed tables below (`myriads`, `margins`, `reaches`).

## 2. Set faction influence (pp. 52, 103)

Look at the factions from the faction exercise (`rules/campaign-launch.md`). Which have a hand in these waters? Place each in a field of the influence grid at the rank that suits its role here and in the story, and leave several fields blank for factions yet to emerge:

| Field | Roll |
|---|---|
| Dominant | 1–30 |
| Established | 31–45 |
| Established | 46–60 |
| Subsisting | 61–70 |
| Subsisting | 71–80 |
| Subsisting | 81–90 |
| Diminished | 91–94 |
| Diminished | 95–98 |
| Unknown | 99–100 |

To find which faction controls a ship or settlement, or to answer an oracle question such as "who attacked the port?", roll `1d100` on the grid. On a blank field, take the closest-ranked faction, or introduce an independent group or a new faction. Over the campaign, lower a faction's rank after a major setback and raise it as it gains influence.

## 3. Reveal islands (p. 104)

Generate **four** islands in the Myriads, **three** in the Margins, or **two** in the Reaches: a footing, not the whole region. For each:

- **Landscape:** `oracles/island/landscape/size.md`, `oracles/island/landscape/terrain.md`, and `oracles/island/landscape/vitality/<region>.md`. These are the dominant characteristics; a large island varies.
- **Where it lies** on the chart: keep it small among wide seas, leaving room for the other islands and for discoveries. A large island can run off the chart's edge.
- **Neighbors:** `oracles/island/nearby-islands/<region>.md`. Islands of a pair or group are close enough to see from one another in fair weather, a short sail apart. Don't detail them now, and don't count them toward the total.
- **Name:** `oracles/island/name.md`.

## 4. Build a seaside settlement (p. 105)

A village, town or city to serve as the hub of the opening: an important place, a home port, or simply a destination. Settlements thin out and shrink beyond the Myriads.

- **Where:** pick an island and a spot on its shore.
- **How populous:** `oracles/settlement/size/<region>.md`.
- **Industries and activities:** `oracles/settlement/focus/waterside.md`.
- **Who's in control:** choose a faction from the influence grid that fits what you know of the place, or roll on the grid.
- **Name:** `oracles/settlement/name.md`.

If the character starts here or calls it home port, add more; otherwise wait until a visit:

- Ambiance and architecture: `oracles/settlement/aesthetics.md`.
- First glance: `oracles/settlement/first-look.md`.
- What else is known, or rumored: `oracles/settlement/details.md`.

## 5. Add notable locations (pp. 106–107)

Add **one to three** sea features or island landmarks: roll or choose on `oracles/getting-underway/chart-your-course/details.md` (cursed version: `oracles/getting-underway/chart-your-course/details-cursed.md`). Each comes with an open question to answer now or leave a mystery. Mark them on the chart, or keep their whereabouts vague and record them as rumors to follow up.

## 6. Add a local connection (p. 108)

An important person in the area: a patron with a shared purpose, who asks for or sponsors the character's first ventures, or a helpful acquaintance. A connection isn't a shipmate or a companion; their life only crosses the character's now and then.

- **Role:** their duty, expertise or background, broad enough to help often and specific enough to have flavor. It grants a bonus when they support a move.
- **Rank:** troublesome, dangerous, formidable, extreme or epic, by how hard and how central a bond with them should be.
- **Goal:** `oracles/character/goal.md`.
- **Name:** `oracles/character/name/given-name.md` and `oracles/character/name/family-name.md`.
- **Faction:** any link to a faction on the influence grid.
- **Where:** a settlement or place on the chart; if they're aboard a ship, where it sails.

Optionally, more: `oracles/character/first-look.md`, `oracles/character/trademark-accessories.md` or `oracles/character/trademark-weapons.md`, and `oracles/character/revealed-aspect.md` (Character Details). Add them to `npcs.md` and to the sheet's connections, with a progress track at their rank: the introduction counts as a strong hit on Make a Connection.

**Want more?** Repeat step 4 for another settlement or two, on the shore or inland. That leaves less to discover in play.

## 7. Name the area (p. 109)

Name these local seas, or roll `oracles/misc/local-seas.md` for a suggestion.

Next: set the scene (`rules/campaign-launch.md`).
