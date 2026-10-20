---
description: Push the gm campaign to its configured backup remote.
---

Run `campaign backup <saves-dir>` (`campaign` is `${CLAUDE_PLUGIN_ROOT}/scripts/campaign`, run by that full path) to push the campaign repo to its remote. If none is configured, tell the player to add one: `git -C <saves-dir> remote add origin <url>`.
