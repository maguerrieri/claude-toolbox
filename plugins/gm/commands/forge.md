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

2. **Sealed (`--secret`): hand the whole forge to the `gm:screen` subagent** and skip the
   steps below. Its prompt is shown to the player, so pass only the task (`Sealed forge`),
   the campaign dir, the type, N, and the frame's path (or, for an on-the-fly frame, its
   axes: they shape the pool without being in it). Never draft entries yourself, not even
   a fallback pool: every tool call you make is in the player's transcript, and Claude Code
   shows a diff of any file a Bash command writes. The subagent drafts the pool under
   `<campaign>/.gm/forge/`, harvests it into the sealed `<campaign>/.gm/tables/<type>.md`,
   deletes the draft, and replies `sealed <n> entries → .gm/tables/<type>.md`. Nothing lands
   in `docs/generation/`. Relay that line; `roll table <campaign>/.gm/tables/<type>.md`
   draws from it, and prints what it draws, so roll it when the fiction earns the reveal.

3. **Generate the reservoir** (open forge, `generate` plugin available). From the
   `<campaign>` directory (cwd), invoke the `generate` skill for `<type>` (count N) seeded
   with the resolved frame. `generate` writes to `docs/generation/<type>.md` relative to
   cwd, so running it from `<campaign>` lands the reservoir at
   `<campaign>/docs/generation/<type>.md`.

4. **Harvest.** `forge harvest <campaign>/docs/generation/<type>.md <campaign>/tables/<type>.md`.
   Confirm the harvest line printed (`forge: harvested N entries -> <path>`); the table is
   now rollable with `roll table <campaign>/tables/<type>.md`.

5. **Degradation** (open forge, `generate` absent). Announce the reduced diversity.
   Improvise ~6–10 diverse entries into a scratch reservoir at
   `<campaign>/docs/generation/<type>.md` with the Write tool (a `## Reservoir` heading,
   then one `- ` entry per line), then harvest as in step 4. Reforge with `generate`
   present when session pace allows.

Obey Rule 0 — once the table exists, rolls come from the die, not from thin air.
