---
name: spawn
description: Use when asked to spawn, fan out, kick off, or background one or more sessions/agents to work on arbitrary tasks in parallel and hand back without blocking (e.g. "spawn a session to investigate X", "fan out 3 agents to each do Y", "kick this off in the background"). Generic background-session fan-out — not ticket-specific; for issue/ticket fan-out use the /spawn-tickets command (ticket-workflow skill).
---

# Spawn (background-session fan-out)

Fan out one or more **independent** background `claude --bg` sessions for arbitrary work, name them so they're recognizable in `claude agents`, report a table, and hand back **without blocking**. The mechanic is ticket-agnostic — it knows nothing about issues, trackers, or profiles. (`/spawn-tickets` is a specialization that builds `/start-ticket` prompts and then uses this mechanic.)

## When to use

- "Spawn a session to investigate this." — one background task, fire-and-forget.
- "Fan out 3 agents to each try X." — several independent tasks at once.
- Any time you want work to run in its own durable `claude --bg` session and keep your current session free.

**Not for:** work you must watch to completion or aggregate (that's babysitting — do it inline, or use the ticket-workflow EPIC phase). Issue/ticket fan-out → use the `/spawn-tickets` command (the `ticket-workflow` skill).

## No cap

Spawn adds **no** safety bound — each session does exactly what its prompt says. If you want a limit, write it into the task text, e.g. `/spawn investigate the crash, read-only, don't push or merge`. (The ticket-only `SPAWN_CAP` is applied by the ticket-workflow SPAWN phase *before* it hands a prompt here; it is not part of generic spawn.)

## Steps

### 1 — Parse into units

Split the request into one or more `(prompt, desc)` units:
- **One task** (the common case): the whole request is the prompt. `/spawn to investigate the flaky CI` → a single unit.
- **Several tasks:** an explicit list, or "spawn N agents to each do X" → N units.

`prompt` = the full instruction the background session acts on (verbatim — don't trim the caller's bounds). `desc` = an under-5-word summary for the session name.

### 2 — Pick a context label

A short prefix that makes the session findable in `claude agents`:
- In a repo / working dir → its basename (e.g. `misc`, `sonder`).
- Otherwise → a topic word from the task.

### 3 — Spawn in parallel

One Bash call per unit, **all in a single message** so they launch concurrently:

```bash
claude --bg --name "<context> <desc>" "<prompt>"
```

- `<desc>`: under 5 words, recognizable (e.g. `investigate flaky CI`). Spaces and special characters are fine — keep `--name`'s argument quoted.
- `<prompt>`: quote it so the shell can't mangle it. Plain prose in double quotes is fine (apostrophes are safe), but if the prompt contains `$`, backticks, or `$(...)`, double quotes will **expand** them and corrupt the spawned prompt. For those, feed the prompt through a single-quoted heredoc into a variable and pass the variable:
  ```bash
  read -r -d '' p <<'PROMPT'
  …prompt text, verbatim…
  PROMPT
  claude --bg --name "<context> <desc>" "$p"
  ```
- Add no cap; the prompt carries whatever bounds the caller wrote.
- `claude --bg` prints a **session handle** at spawn — record it per unit; it survives the user renaming the session and is how you inspect a stuck one later.

### 4 — Report and hand back

Print a table, then stop — **don't block on the sessions**:

| Session | Scope |
|---|---|
| `misc investigate flaky CI` | <one-line summary> |

Point at the inspect commands: `claude agents` (list), `claude attach "<name>"` (open), `claude logs "<name>"` (read-only). Quote names — they contain spaces.

## Spawn does NOT

- Babysit or poll the sessions — each runs on its own.
- Block on completion — spawn, report, hand back.
- Add any cap — bounds live in the prompt text.
- Know about issues / tickets / trackers / profiles — that's the `/spawn-tickets` command (the `ticket-workflow` skill).
