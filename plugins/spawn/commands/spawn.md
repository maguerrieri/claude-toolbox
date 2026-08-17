---
description: Use when asked to kick off, background, or fan out arbitrary background work ("spawn a session to investigate X", "make an issue and /spawn it"), or when /spawn appears anywhere in the message (generic — no ticket semantics)
argument-hint: <task description>  [; <another task> ...]
---
Spawn background work for: **$ARGUMENTS**

Use the `spawn` skill. Parse "$ARGUMENTS" into one or more `(prompt, desc)` units (a single task is the common case; a `;`-separated list or "N agents to each do X" fans out), **select the backend** (the skill's step 3 — `$CLAUDE_CODE_REMOTE_SESSION_ID` set → cloud `create_session`, else local `claude --bg`) and read that backend file, spawn one session per unit named `<context> <desc>` (in parallel — all launches in a single message), report the table of spawned sessions with the backend's own inspect path, and hand back — don't block on them.

The backends differ in more than the command: the local one needs a **durable launch directory** (the repo's main checkout, never a disposable worktree) and careful shell quoting for prompts containing `$`, backticks, or `$(...)`; the cloud one has no launch directory and must pass the repo explicitly via `source_url`. Read the backend file rather than working from memory.

No ticket / issue / tracker semantics and **no safety cap** beyond whatever bounds the task text itself states — if you want a limit, include it in the task (e.g. `/spawn investigate the crash, read-only`).
