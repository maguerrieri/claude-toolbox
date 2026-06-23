---
description: Fan out one or more background sessions to work on arbitrary tasks in parallel, then hand back (generic — no ticket semantics)
argument-hint: <task description>  [; <another task> ...]
---
Spawn background work for: **$ARGUMENTS**

Use the `spawn` skill. Parse "$ARGUMENTS" into one or more `(prompt, desc)` units (a single task is the common case; a `;`-separated list or "N agents to each do X" fans out), spawn one `claude --bg --name "<context> <desc>" "<prompt>"` session per unit (in parallel — one Bash call each in a single message), report the table of spawned sessions, and hand back — don't block on them.

If a prompt contains shell metacharacters (`$`, backticks, `$(...)`), don't interpolate it raw into double quotes — the shell would expand and corrupt it. Pass it via a single-quoted heredoc into a variable instead (see the skill's step 3).

No ticket / issue / tracker semantics and **no safety cap** beyond whatever bounds the task text itself states — if you want a limit, include it in the task (e.g. `/spawn investigate the crash, read-only`).
