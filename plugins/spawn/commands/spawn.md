---
description: Use when asked to kick off, background, or fan out arbitrary background work ("spawn a session to investigate X", "make an issue and /spawn it"), or when /spawn appears anywhere in the message (generic — no ticket semantics)
argument-hint: '<task description> [; <another task> ...] [--harness codex|claude] [--surface desktop|cli|cloud]'
---
Spawn background work for: **$ARGUMENTS**

Use the `spawn` skill. Parse "$ARGUMENTS" into one or more `(prompt, desc)` units (a single task is the common case; a `;`-separated list or "N agents to each do X" fans out), plus optional `--harness codex|claude` and `--surface desktop|cli|cloud` launch overrides. Remove both flags from child prompts. **Select the harness and surface** using the skill's step 3, read exactly the matching adapter path, and spawn one task per unit named `<context> <desc>` in parallel. Report the selected pair, its stable task/session identifiers, and its own inspect/open controls, then hand back without blocking.

Harness/surface adapters differ in more than the command. Read the selected adapter rather than working from memory. Cross-harness local callers map to the target CLI; same-harness calls inherit the caller surface; explicit surface choices win. If the selected pair is unavailable, report its exact capability error and stop—never substitute another harness or surface.

No ticket / issue / tracker semantics and **no safety cap** beyond whatever bounds the task text itself states — if you want a limit, include it in the task (e.g. `/spawn investigate the crash, read-only`).
