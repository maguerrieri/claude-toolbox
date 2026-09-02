# SPAWN-EPIC mini-phase (`/spawn-epic`)

Launch one background EPIC work item without running EPIC in the caller:

1. Parse optional launch-only `--harness codex|claude` and
   `--surface desktop|cli|cloud` overrides. Reject unknown, duplicate, or
   conflicting values before launch; remove the tokens from child arguments
   while preserving every other argument verbatim, including briefing,
   `--finish`, `--coordinate`, `--team`, and `--independent`.
2. Take the first remaining token as `<epic-id>`, determine `<repo>` from the
   target repository, and derive an under-five-word `<desc>` from the briefing
   (`epic run` when none exists). Build exactly one generic-spawn unit:

   - **name:** `<repo> <epic-id>: epic — <desc>`
   - **prompt:** `/start-epic <arguments without launch overrides>` followed
     by `Role: epic-coordinator`
   - **notify:** `requested`

   Add no `SPAWN_CAP`: the coordinator applies the complete selected-profile
   cap to each child, and an explicit `--finish` must reach it unchanged.
3. Invoke generic `spawn` and pass explicit harness/surface overrides as launch
   metadata, never prompt text. With no override it inherits the caller's
   harness and surface. Generic `spawn` alone selects the target, resolves the
   lazy notification request for that caller/target edge, creates the native
   task/session, owns isolation and launch directory, and reports stable
   identifiers plus inspect/open controls.
4. Return generic `spawn`'s report and hand back without blocking. Do not fetch
   the epic, enumerate children, run Step 0, launch natively, or implement any
   EPIC step in this mini-phase.
