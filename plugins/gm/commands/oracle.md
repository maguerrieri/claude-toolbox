---
description: Quick oracle pull (yes/no or meaning prompt) without a full session.
---

Use the `gm` skill to consult the active campaign's adapter oracle **without** running a full session.

- For a **yes/no** question (pass it as $ARGUMENTS): `roll oracle --table <adapter>/oracles/yes-no.json`, then interpret the band into a one- or two-sentence answer in the fiction.
- For **inspiration**: roll the adapter's action + theme tables and read the pair as a prompt.

Always show the roll. Obey Rule 0 — the answer comes from the die, not from thin air.
