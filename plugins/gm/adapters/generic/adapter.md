---
name: generic
dice: ["1d100", "1d20"]
tone: system-agnostic
sheet: sheet-template.md
---

# Generic oracle adapter

A Mythic-style, system-agnostic oracle. It supplies a yes/no oracle and a meaning oracle; **you bring whatever rules system you like** (or none). The core narrates; this adapter answers the open questions.

## Resolution rules

- **Yes/No question.** When the fiction poses a question the GM shouldn't simply decide — *Is the door guarded? Does the contact show?* — roll `oracles/yes-no.json` with `bin/roll oracle --table <adapter>/oracles/yes-no.json`.
  - *Yes, and…* — yes, plus an extra benefit.
  - *Yes, but…* — yes, with a cost or catch.
  - *No, but…* — no, with a small consolation.
  - *No, and…* — no, plus an added complication.
  Interpret the result into the fiction, then keep the scene moving (see `gm-craft.md`: fail forward).
- **Inspiration / meaning prompt.** When you need a spark — a complication, an NPC's angle, what's behind a door — roll `oracles/action.json` and `oracles/theme.json` and read the two words together (e.g. *Seize / Secret* → someone is trying to take something hidden).
- **Mechanics.** This adapter enforces no system. If the player runs a ruleset, they call its rolls via `bin/roll` (e.g. `roll 1d20+3`); the oracle answers everything the rules don't.

## Likelihood

The yes/no table is even odds. When the fiction makes an outcome clearly likely or unlikely, lean your interpretation toward it — or just decide. The oracle is for genuine uncertainty, not every question.

## Safety

Open a campaign with **lines & veils**: ask what's off-limits entirely (lines) and what happens off-screen (veils). Honor them without exception.
