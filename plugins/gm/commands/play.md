---
description: Start or continue a solo RPG session for a gm campaign.
---

Run the `gm` skill's **session-start** flow and enter the play loop for the campaign at $ARGUMENTS (a saves path); if none is given, use the most recently played campaign.

Load `campaign.md` → the named adapter (resolve any `extends:`) → the campaign state; give a short "Previously…" recap from the last log and the hot threads; then frame the first scene and ask **"What do you do?"**. Follow Rule 0: every roll through `bin/roll`, every value from the sheet or adapter data.
