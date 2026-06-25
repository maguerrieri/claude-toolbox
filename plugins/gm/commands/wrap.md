---
description: End the current gm session — write the log + recap and persist state.
---

Run the `gm` skill's **wrap** flow for the active campaign (or the one at $ARGUMENTS):

append `log/NNNN-<title>.md` (zero-padded next index) with the session's key beats, end it with a forward **"Previously…"** recap for next time, persist any staged state deltas (threads, clocks, sheets, npcs, locations), and tell the player what's still open — hot threads and ticking clocks.
