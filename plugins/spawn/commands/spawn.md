---
description: Use when asked to kick off, background, or fan out arbitrary background work ("spawn a session to investigate X", "make an issue and /spawn it"), or when /spawn appears anywhere in the message (generic — no ticket semantics)
argument-hint: '<task description> [; <another task> ...] [--harness codex|claude]'
---
Spawn background work for: **$ARGUMENTS**

Use the `spawn` skill. Parse "$ARGUMENTS" into one or more `(prompt, desc)` units (a single task is the common case; a `;`-separated list or "N agents to each do X" fans out), plus an optional `--harness codex|claude` launch override. Remove that flag from child prompts. **Select the harness** using the skill's step 3 (explicit override, otherwise inherit the active harness), read exactly that harness adapter, and spawn one task per unit named `<context> <desc>` in parallel. Report the selected harness, its stable task/session identifiers, and its own inspect/open controls, then hand back without blocking.

Harness adapters differ in more than the command: Codex creates native project/worktree tasks, while Claude performs its separate local/cloud backend selection from #57. Read the selected adapter rather than working from memory. If an explicitly selected harness is unavailable, report the capability error and stop; never substitute another harness.

No ticket / issue / tracker semantics and **no safety cap** beyond whatever bounds the task text itself states — if you want a limit, include it in the task (e.g. `/spawn investigate the crash, read-only`).
