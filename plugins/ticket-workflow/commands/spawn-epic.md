---
description: Use when asked to run a whole epic hands-off in the background ("kick off the auth epic while I'm away"), or when /spawn-epic appears anywhere in the message
argument-hint: '<epic-id> [briefing] [--finish] [--coordinate | --team | --independent] [--harness codex|claude] [--surface desktop|cli|cloud]'
---
Spawn a background epic run for: **$ARGUMENTS**

Invoke the `ticket-workflow` skill now via the Skill tool and run its
authoritative **SPAWN-EPIC mini-phase (`/spawn-epic`)** with `$ARGUMENTS`. The
command is only a delegate: do not restate or implement parsing, unit
construction, notification metadata, launch selection, native creation, or
reporting here.
