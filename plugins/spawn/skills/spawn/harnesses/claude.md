# Harness: Claude

The selected target is a Claude session. Harness and surface selection are
complete; route the selected surface directly:

- **cli** — read `../backends/local.md` now.
- **cloud** — read `../backends/cloud.md` now.
- **desktop** — Claude desktop has no established durable spawn adapter. Report
  that the selected `claude+desktop` pair is unavailable and stop.

Read exactly one backend and use it for launch, stable identifiers, reporting,
and inspection controls. Do not duplicate those mechanics here.

If the unit has `notify: requested`, resolve the spawner's current session
name/handle only when the caller and target are both **Claude CLI** (use
`ListAgents` when the current name is not already known), then
append `Notify: <spawner>` to the prompt. If that local identity cannot be
resolved, omit the directive and report the degrade-to-poll behavior. For a
cross-harness caller or a **cloud/desktop** surface, perform no identity lookup and
omit the directive: those callers and targets do not share Claude local's
messaging graph. `backends/cloud.md` documents the cloud boundary.

The selected surface describes where the Claude sibling will live, not the
subject of the task. A local cross-harness caller maps to Claude CLI, so Codex
desktop can deliberately launch `claude --bg`. An explicit Claude cloud target
must use the cloud adapter or fail; it never falls back to local CLI.
