---
name: generic
dice: ["1d100", "1d20"]
tone: system-agnostic
sheet: sheet-template.md
visibility: gm
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

## When to roll vs. decide

Roll the yes/no oracle when **all three** hold: (1) the outcome is genuinely uncertain, (2) a "no" or a complication would be *interesting*, and (3) the character has no decisive advantage that makes the answer a foregone conclusion. If a capable character attempts a low-stakes, well-suited task, just narrate success — don't roll. But once you *do* roll, abide by the result (Rule 0). The dice are for the moments that matter.

The table is even odds; on a borderline band, lean your reading toward whatever the fiction already makes likely.

## Safety

Open a campaign with **lines & veils**: ask what's off-limits entirely (lines) and what happens off-screen (veils). Honor them without exception.

## Behind the screen

This adapter is "be my GM for any system," so GM-side world-state defaults **behind the screen** (`visibility: gm`): hidden **clocks** (a menace advancing) and the **answers** behind questions you'd rather not see coming are written via `campaign gm-*` into `.gm/`, not the open files — so the write collapses to "Ran 1 shell command" in the transcript instead of spoiling you, and surfaces only when the fiction earns it (`campaign gm-reveal`). Nothing is encrypted: the values are plain files under `.gm/` you can read anytime — peeking is your call (playing toward a secret your character doesn't know is half the fun).
