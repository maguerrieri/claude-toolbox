---
description: Quick oracle pull (yes/no or meaning prompt) without a full session.
---

Use the `gm` skill to consult the active campaign's adapter oracle **without** running a full session. The adapter is the one `campaign.md` names (`adapter:`); read its `adapter.md` under `${CLAUDE_PLUGIN_ROOT}/adapters/<adapter>/`, resolving `extends:`, and roll the tables its rules name (adapter-contract: "The yes/no and spark rules").

- For a **yes/no** question (pass it as $ARGUMENTS): follow the adapter's **yes/no rule** (generic: roll `oracles/yes-no.md`; ironsworn and starforged: pick the odds, then roll that Ask the Oracle table). When the rule asks for odds, use the ones the player gave (e.g. `/gm:oracle likely: Is the station abandoned?`); otherwise choose them from what the fiction already makes likely, 50/50 when nothing tips it, and say which before you roll. Roll with `roll table <path>`, then interpret the result into a one- or two-sentence answer in the fiction, along with anything the rule says the roll itself means (a match is a twist). If no adapter in the chain states a yes/no rule, roll the generic adapter's `oracles/yes-no.md` and say so.
- For **inspiration**: follow the adapter's **spark rule**: roll its `oracles/action.md` + `oracles/theme.md` (starforged also pairs `oracles/descriptor.md` + `oracles/focus.md` for a place, discovery or encounter) and read the pair as a prompt. If the chain has no `action.md` + `theme.md`, roll the generic adapter's and say so.

Always show the roll. Obey Rule 0 — the answer comes from the die, not from thin air.
