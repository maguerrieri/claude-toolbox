---
description: Rewind a gm campaign to an earlier checkpoint (undo a bad turn).
---

Show recent checkpoints with `campaign log <saves-dir>` (`${CLAUDE_PLUGIN_ROOT}/bin/campaign`), let the player pick one, then `campaign rewind <saves-dir> --to <ref>`. The current state is checkpointed first, so the rewind is itself reversible. After rewinding, re-read the campaign state from disk before continuing. $ARGUMENTS may name a checkpoint.
