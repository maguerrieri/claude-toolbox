# Codex surface: cloud

The selected target is a durable Codex cloud task. Launch only when the current
runtime exposes an exact native cloud task capability and all required project
or environment identity can be resolved without guessing. Preserve the unit
prompt and name, launch all units concurrently, and report the returned stable
task IDs plus the native cloud inspection controls.

The experimental `codex cloud exec` command requires an explicit environment ID
and does not by itself supply generic spawn with a safe target selection rule.
If the exact capability or environment identity is unavailable, report that the
selected `codex+cloud` pair cannot be launched and stop. Never fall back to
Codex desktop, Codex CLI, or Claude.
