---
description: Use when asked to run a whole epic hands-off in the background ("kick off the auth epic while I'm away"), or when /spawn-epic appears anywhere in the message
argument-hint: '<epic-id> [briefing] [--finish] [--coordinate | --team | --independent] [--harness codex|claude] [--surface desktop|cli|cloud]'
---
Spawn a background epic run for: **$ARGUMENTS**

Thin launcher over `/start-epic`: build ONE named unit for generic `spawn`, then
hand back immediately. Don't run any EPIC step yourself — no fetching the epic,
enumerating children, or Step 0; the spawned task/session does all of it.

1. Parse optional launch-only `--harness codex|claude` and
   `--surface desktop|cli|cloud` overrides. Remove those tokens from the child
   arguments; reject an unknown value or conflicting overrides before
   launching. Preserve every remaining argument verbatim,
   including briefing and EPIC flags (`--finish`, `--coordinate`, `--team`,
   `--independent`).
2. Take the first remaining token as `<epic-id>`. Determine `<repo>` from the
   target repository and derive an under-five-word `<desc>` from the briefing
   (use `epic run` when no briefing supplies one). Build exactly this generic
   spawn unit:

   - **name:** `<repo> <epic-id>: epic — <desc>`
   - **prompt:**

     ```text
     /start-epic <arguments without the harness override>
     Role: epic-coordinator
     ```

   Do not append a `SPAWN_CAP`: the epic coordinator applies the selected
   profile's complete cap to each child, and an explicit `--finish` must reach
   the coordinator intact.
3. **Invoke the generic `spawn` skill via the Skill tool** and delegate the
   unit to it. Pass explicit harness or surface overrides, if present, as launch
   metadata; never place them in the child prompt. With no override, generic
   `spawn` inherits the active harness and surface. It alone owns harness and
   surface selection, native task/session creation, isolation, launch
   directory, stable identifiers, and launch reporting.
4. Return generic `spawn`'s table and selected-harness inspect/open guidance,
   including the stable identifier it reports, then hand back without blocking.
