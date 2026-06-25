---
description: Scaffold a new gm campaign (pick a system adapter + saves location) and create the starting character.
---

Use the `gm` skill to start a new campaign.

1. Ask the player for: the **setting / premise**; the **system adapter** (default `generic` — list `${CLAUDE_PLUGIN_ROOT}/adapters/` for options); and the **saves location** — a directory in *their* space (e.g. `~/rpg/<name>`), never inside the plugin.
2. Scaffold the campaign-state files there per the state schema (`${CLAUDE_PLUGIN_ROOT}/skills/gm/references/state-schema.md`): `campaign.md` (with `adapter:` set and `persona: house`), empty `npcs.md` / `threads.md` / `clocks.md` / `locations.md`, and a `log/` directory.
3. Establish a few **truths** about the world and run a **lines & veils** safety check.
4. Create the starting character in `characters/<name>.md` using the adapter's `sheet-template.md`.
5. **Version the saves:** run `campaign init <saves-dir> --author "<persona author>" --email "<persona email>"` (`${CLAUDE_PLUGIN_ROOT}/bin/campaign`) to start a dedicated git repo for the campaign — it defers automatically if the dir is already inside a repo (e.g. an Obsidian vault). Resolve author/email from the chosen persona's `chronicle_identity`.
6. Offer to begin play with `/gm:play`.

$ARGUMENTS may name the setting or the saves path.
