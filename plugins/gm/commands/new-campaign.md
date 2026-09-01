---
description: Scaffold a new gm campaign (pick a system adapter + saves location) and create the starting character.
---

Use the `gm` skill to start a new campaign.

1. Ask the player for: the **setting / premise**; the **system adapter** (default `generic` — list `${CLAUDE_PLUGIN_ROOT}/adapters/` for options); and the **saves location** — a directory in *their* space (e.g. `~/rpg/<name>`), never inside the plugin.
2. Scaffold the campaign-state files there per the state schema (`${CLAUDE_PLUGIN_ROOT}/skills/gm/references/state-schema.md`): `campaign.md` (with `adapter:` set and `persona:` — see below), empty `npcs.md` / `threads.md` / `clocks.md` / `locations.md`, and a `log/` directory.
   - **Persona choice.** Offer the shipped voices (list `${CLAUDE_PLUGIN_ROOT}/personas/`) plus anything already on the player's search path (`<saves-dir>/personas/`, and each colon-separated entry of `$GM_PERSONA_PATH`); default `house`. Write a bare **name** when the persona is on that search path, or a **path** for a one-off location. If the player wants a voice of their own, scaffold it at `<saves-dir>/personas/<name>/persona.md` and write `persona: <name>` — it resolves campaign-first with no configuration, and gets versioned with the save. Out-of-tree personas should carry a **literal** email in `chronicle_identity` (the `${identity_domain}` placeholder only resolves for the plugin's own personas).
3. Establish a few **truths** about the world and run a **lines & veils** safety check.
4. Create the starting character in `characters/<name>.md` using the adapter's `sheet-template.md`.
5. **Version the saves:** run `campaign init <saves-dir> --author "<persona author>" --email "<persona email>"` (`${CLAUDE_PLUGIN_ROOT}/bin/campaign`) to start a dedicated git repo for the campaign — it defers automatically if the dir is already inside a repo (e.g. an Obsidian vault). Resolve author/email from the chosen persona's `chronicle_identity`, reading that persona through the same resolution rule as step 2 (path-valued as-is; bare name searched campaign → `$GM_PERSONA_PATH` → plugin).
6. Offer to begin play with `/gm:play`.

$ARGUMENTS may name the setting or the saves path.
