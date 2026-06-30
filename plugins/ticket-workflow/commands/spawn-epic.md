---
description: Run a whole epic in a new background session — spawns one `claude --bg` running /start-epic, reports the handle, hands back
argument-hint: <epic-id> [briefing] [--finish] [--coordinate | --team | --independent]
---
Spawn a background epic run for: **$ARGUMENTS**

Thin launcher over `/start-epic`: spawn ONE background session that runs the full EPIC cycle, then hand back immediately. Don't run any EPIC step yourself — no fetching the epic, no enumerating children, no Step 0; the spawned session does all of it.

1. Take the first token of "$ARGUMENTS" as the epic ID (used only for the session name). Pass the **full** "$ARGUMENTS" through to the child **verbatim** — briefing and flags (`--finish`, `--coordinate`, `--team`, `--independent`) are parsed by the `/start-epic` orchestrator, not here. Do **not** append a `SPAWN_CAP`: the epic orchestrator caps each child itself, and an explicit `--finish` must reach it intact.
2. Determine `<repo>` for the session name — basename of the repo the work targets (the current repo unless the briefing names another).
3. Spawn it. Feed the prompt through a single-quoted heredoc into a variable so the arguments can't be mangled by the shell — plain double-quoting would **expand** any `$`, backticks, or `$(...)` in `$ARGUMENTS` and corrupt the prompt (the same mitigation `/spawn` documents):

```bash
read -r -d '' p <<'PROMPT'
/start-epic $ARGUMENTS
PROMPT
claude --bg --name "<repo> <epic-id>: epic — <quick description>" "$p"
```

`<quick description>`: an under-5-word summary of the epic, recognizable in the session list. The `epic —` marker distinguishes this orchestrator session from the `<epic-id-lower>-<id-lower>` child sessions it will spawn.

4. Report the session name and the handles — `claude agents` to list, `claude attach "<name>"` to open, `claude logs "<name>"` read-only (quote the name; it contains spaces) — and hand back without blocking.
