---
description: Quick oracle pull (yes/no or meaning prompt) without a full session.
---

Use the `gm` skill to consult the active campaign's adapter oracle **without** running a full session. The adapter is the one `campaign.md` names (`adapter:`). Read its `adapter.md` under `${CLAUDE_PLUGIN_ROOT}/adapters/<adapter>/`, resolving `extends:`, and find its **yes/no rule** and **spark rule** (adapter-contract: "The yes/no and spark rules"). The adapter's rule is the authority: roll the tables it names with `roll table <path>`, choosing among them as it says.

- For a **yes/no** question (pass it as $ARGUMENTS): follow the yes/no rule. When it asks for odds (as the Ironsworn family's Ask the Oracle does), use the odds the player gave (e.g. `/gm:oracle likely: Is the station abandoned?`); otherwise choose them from what the fiction already makes likely, 50/50 when nothing tips it, and say which before you roll. When the rule has no odds but the player gave some (generic's single even table), roll it anyway, lean a borderline reading toward the player's odds, and say so. Interpret the result into a one- or two-sentence answer in the fiction, along with anything the rule says the roll itself means (a match is a twist).
- For **inspiration**: follow the spark rule. Roll the tables it names and read them together as a prompt; when it offers more than one pair, pick the one that fits what's asked.

If no adapter in the chain states the rule you need, roll the generic adapter's tables instead (`${CLAUDE_PLUGIN_ROOT}/adapters/generic/oracles/yes-no.md`, or its `action.md` + `theme.md`) and say so.

Always show the roll. Obey Rule 0 — the answer comes from the die, not from thin air.
