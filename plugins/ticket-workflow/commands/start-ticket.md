---
description: Start work on an issue — worktree → implement → tests → PR → review → CI green (tracker-agnostic)
argument-hint: <issue-id> [briefing | "setup only" | "stop before push"]
---
Start work on issue: **$ARGUMENTS**

**Invoke the `ticket-workflow` skill now via the Skill tool** and run its **START** phase — do not read its `SKILL.md` directly. Treat the first token of "$ARGUMENTS" as the issue ID and the rest as briefing and/or opt-out signals ("setup only", "stop before push").

First do the skill's **Step 0** to select the tracker + profile (project memory → repo `CLAUDE.md` → infer/default), then follow the full START cycle and its completion criteria. Don't hand back until every completion box is checked unless an opt-out applies.
