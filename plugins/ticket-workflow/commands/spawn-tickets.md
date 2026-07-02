---
description: Use when asked to work issues/tickets in parallel or in the background ("get issues 3, 5, 8 moving while I'm out", "file an issue and /spawn-tickets it"), or when /spawn-tickets appears anywhere in the message
argument-hint: <issue-id> [<issue-id> ...] [briefing]
---
Spawn parallel work for: **$ARGUMENTS**

**Invoke the `ticket-workflow` skill now via the Skill tool** and run its **SPAWN** phase — do not read its `SKILL.md` directly. Parse "$ARGUMENTS" into issue IDs (plus any per-issue or shared briefing text), append the selected profile's `SPAWN_CAP` to each, and spawn one `claude --bg` session per issue running `/start-ticket` — from a durable launch directory (the repo's main checkout, never a disposable worktree; the skill's SPAWN Step 3 has the rule), named `"<repo> <issue-key>: <quick description>"` (repo name, issue key, then an under-5-word summary recognizable in the session list — spaces and special characters are fine). Report the table of spawned sessions and hand back — don't block on them.
