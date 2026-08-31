# Harness Routing Behavioral Scenarios

Use these scenarios as fresh-context pressure tests for the installed `spawn`
and `ticket-workflow` skills. Evaluators inspect the relevant skill and command
files, state what they would do, and do not actually launch tasks or mutate the
repository.

For every case record:

- selected harness and, for Claude, selected backend;
- native launch mechanism;
- stable identifier reported to the user;
- inspection/open controls;
- whether the original prompt is preserved; and
- whether launch-only flags leaked into the child prompt.

| Case | Request context | Expected behavior |
|---|---|---|
| Codex default | From a Codex task, `/spawn investigate flaky CI` | Create a native Codex task. Report its task/thread ID and Codex sidebar/open controls. Never launch Claude. |
| Claude local default | From local Claude Code, `/spawn investigate flaky CI` | Select the Claude harness, then the local backend. Preserve PR #58's `claude --bg` behavior and CLI inspect controls. |
| Claude cloud default | From Claude Code on the web, `/spawn investigate flaky CI` | Select the Claude harness, then the cloud backend. Preserve PR #58's `create_session` source propagation and cloud inspection controls. |
| Codex to Claude override | From Codex, `/spawn --harness claude investigate flaky CI` | Select Claude explicitly, then its applicable backend. Report Claude identifiers/controls; do not create a Codex task. |
| Claude to Codex override | From Claude, `/spawn --harness codex investigate flaky CI` | Select Codex explicitly. Use native Codex task creation when available; if it is unavailable, report that capability error and stop without falling back to Claude. |
| Invalid override | `/spawn --harness turtles investigate flaky CI` | Reject the value and list `codex` and `claude`; launch nothing. |
| Codex ticket default | From Codex, `/spawn-tickets #63` | Create a native Codex task whose prompt contains `/start-ticket #63`, the complete `SPAWN_CAP`, and `Role: implementer`. Report Codex identifiers/controls. |
| Ticket override isolation | From Codex, `/spawn-tickets #63 --harness claude` | Select Claude for the launch, but omit `--harness claude` from the spawned `/start-ticket` prompt. Preserve the ticket briefing, cap, and role exactly. |
| File then spawn | From Codex, `/make-ticket investigate X --spawn` | After filing, pass the new issue ID through the same ticket SPAWN path and inherit Codex unless an explicit harness override was supplied. |

Regression failure: any default crosses harnesses, an explicit override silently
falls back, ticket bounds are dropped, or the reported identifier/inspection
controls belong to a different harness.
