---
description: Use when asked to work issues/tickets in parallel or in the background ("get issues 3, 5, 8 moving while I'm out", "file an issue and /spawn-tickets it"), or when /spawn-tickets appears anywhere in the message
argument-hint: '<issue-id> [<issue-id> ...] [briefing] [--harness codex|claude] [--surface desktop|cli|cloud]'
---
Spawn parallel work for: **$ARGUMENTS**

**Invoke the `ticket-workflow` skill now via the Skill tool** and run its **SPAWN** phase — do not read its `SKILL.md` directly. Parse "$ARGUMENTS" into issue IDs (plus any per-issue or shared briefing text) and optional `--harness codex|claude` and `--surface desktop|cli|cloud` launch overrides. Remove both flags from the child briefing, append the selected profile's complete `SPAWN_CAP` plus `Role: implementer`, and hand one named `/start-ticket` unit per issue to generic `spawn`. Generic `spawn` selects the harness-plus-surface pair and owns task/session creation, isolation, stable identifiers, and inspect/open controls. Report its table and hand back without blocking.
