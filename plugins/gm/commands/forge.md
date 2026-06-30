---
description: Forge a rollable table from a generate reservoir — the deep oracle.
---

Build or refresh a rollable table for `<type>` (`$ARGUMENTS`), with optional `--secret`
(sealed behind the GM screen) and `--n N` (reservoir size, default 20). The campaign dir
is read from `<campaign>/campaign.md`.

1. **Resolve the frame.** Read `adapter` from `<campaign>/campaign.md`, then try in order:
   - `${CLAUDE_PLUGIN_ROOT}/adapters/<adapter>/frames/<type>.md` (adapter-specific)
   - `${CLAUDE_PLUGIN_ROOT}/adapters/generic/frames/<type>.md` (neutral baseline)
   - Frame `<type>` on the fly using the campaign's truths and tone from `<campaign>/campaign.md`

2. **Generate the reservoir** (if the `generate` plugin is available). Invoke the
   `generate` skill for `<type>` (count N) seeded with the resolved frame → it writes a
   reservoir to `<campaign>/docs/generation/<type>.md`.

3. **Harvest.** Run via Bash (not the Write tool — so a sealed table stays collapsed in
   the transcript):
   - Open: `forge harvest <campaign>/docs/generation/<type>.md <campaign>/tables/<type>.md`
   - Sealed (`--secret`): `forge harvest <campaign>/docs/generation/<type>.md <campaign>/.gm/tables/<type>.md`

   The table is now rollable:
   - `roll table <campaign>/tables/<type>.md`
   - `roll table <campaign>/.gm/tables/<type>.md` (sealed)

   Confirm the harvest line printed (e.g. `forge: harvested N entries -> <path>`).

4. **Degradation** (if `generate` is absent). Announce the reduced diversity. Improvise
   ~6–10 diverse entries into a scratch reservoir at `<campaign>/docs/generation/<type>.md`
   (Write tool — reservoir format: a `## Reservoir` heading, then one `- ` entry per line),
   then run `forge harvest` as in step 3 — the table is rollable immediately.
   Reforge with `generate` present when session pace allows.

Obey Rule 0 — once the table exists, rolls come from the die, not from thin air.
