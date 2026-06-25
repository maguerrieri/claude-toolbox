---
description: Save a manual checkpoint of the current gm campaign (a restorable git commit).
---

Run `campaign checkpoint <saves-dir> --label "<text>"` (`${CLAUDE_PLUGIN_ROOT}/bin/campaign`) for the active campaign to snapshot its current state as a restorable save. Use a short label naming the moment (e.g. "before the cursed door"). $ARGUMENTS may supply the label. (No-op if the saves are deferred to the player's own git repo.)
