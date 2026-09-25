---
description: End the current gm session — write the log + recap and persist state.
---

Run the `gm` skill's **wrap** flow for the active campaign (or the one at $ARGUMENTS):

1. **Read the raw play log.** `campaign unwrapped <saves-dir>` (`${CLAUDE_PLUGIN_ROOT}/bin/campaign`) lists each stretch of `log/raw/` that no session log summarizes yet, as `<file>:<first line>-<last line>` — read those lines. Build the session log from them rather than from memory: they survive compaction and resume, and they include any earlier session that was never wrapped. (It lists nothing when autosave wasn't on; then fall back to the conversation.)
2. Append `log/NNNN-<title>.md` (zero-padded next index) with the key beats, and end it with a forward **"Previously…"** recap for next time.
3. Persist any staged state deltas (threads, clocks, sheets, npcs, locations), and tell the player what's still open — hot threads and ticking clocks.
4. **Mark the raw log wrapped:** `campaign mark-wrapped <saves-dir> log/NNNN-<title>.md`, so the next wrap starts after this one. (The marker goes in right away, so the checkpoint below carries it; this session's raw log is marked again once this wrap turn is saved, so the wrap turn itself isn't left over as unwrapped play.)
5. **Checkpoint the campaign**: `campaign checkpoint <saves-dir> --label "<session title>"` so the session becomes a restorable save (a no-op if saves are deferred to the player's own git).
