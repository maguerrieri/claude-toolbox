---
description: Fan out parallel ticket work — one background /start-ticket session per issue (tracker/profile-aware)
argument-hint: <issue-id> [<issue-id> ...] [briefing]
---
Spawn parallel work for: **$ARGUMENTS**

**Invoke the `ticket-workflow` skill now via the Skill tool** and run its **SPAWN** phase — do not read its `SKILL.md` directly. Parse "$ARGUMENTS" into issue IDs (plus any per-issue or shared briefing text), append the selected profile's `SPAWN_CAP` to each, and spawn one `claude --bg` session per issue running `/start-ticket`, named `"<repo> <issue-key>: <quick description>"` (repo name, issue key, then an under-5-word summary recognizable in the session list — spaces and special characters are fine). Report the table of spawned sessions and hand back — don't block on them.
