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
- whether launch-only flags leaked into the child prompt;
- whether an explicit unit name is preserved verbatim;
- whether the selected harness creates or reuses the right workspace; and
- whether notification and queued-identifier controls match the actual edge.

| Case | Request context | Expected behavior |
|---|---|---|
| Codex default | From a Codex task, `/spawn investigate flaky CI` | Create a native Codex task. Report its task/thread ID and Codex sidebar/open controls. Never launch Claude. The task prompt tells work to stay in the native Codex worktree. |
| Claude local default | From local Claude Code, `/spawn investigate flaky CI` | Select the Claude harness, then the local backend. Preserve PR #58's `claude --bg` behavior and CLI inspect controls. |
| Claude cloud default | From Claude Code on the web, `/spawn investigate flaky CI` | Select the Claude harness, then the cloud backend. Preserve PR #58's `create_session` source propagation and cloud inspection controls. |
| Codex to Claude override | From Codex, `/spawn --harness claude investigate flaky CI` | Select Claude explicitly, then its applicable backend. Report Claude identifiers/controls; do not create a Codex task. |
| Claude to Codex override | From Claude, `/spawn --harness codex investigate flaky CI` | Select Codex explicitly. Use native Codex task creation when available; if it is unavailable, report that capability error and stop without falling back to Claude. |
| Invalid override | `/spawn --harness turtles investigate flaky CI` | Reject the value and list `codex` and `claude`; launch nothing. |
| Codex ticket default | From Codex, `/spawn-tickets #63` | Create a native Codex task whose prompt contains `/start-ticket #63`, the complete `SPAWN_CAP`, `Role: implementer`, and `Worktree: current`. START reuses that one native worktree; it does not create a sibling. Report Codex identifiers/controls. |
| Ticket override isolation | From Codex, `/spawn-tickets #63 --harness claude` | Select Claude for the launch, but omit `--harness claude` from the spawned `/start-ticket` prompt. Preserve the ticket briefing, cap, and role exactly. Because the caller is Codex, perform no Claude `ListAgents` lookup and append no `Notify:` even though the target Claude backend is local. |
| File then spawn | From Codex, `/make-ticket investigate X --spawn` | After filing, pass the new issue ID through the same ticket SPAWN path and inherit Codex unless an explicit harness override was supplied. |
| Exact delegated name | Ticket SPAWN supplies `widgets #63: inherit harness` | Every harness adapter uses that exact name/title; generic spawn does not rebuild it from cwd. |
| Local notifier | From local Claude, `/spawn-tickets #63` with a reachable spawner name | Append `Notify: <spawner>` as adapter-supported prompt metadata so START can send `pushed:`/`done:`/`blocked:`/`filed:`. Claude cloud and Codex omit it. |
| Queued Codex task | Codex `create_thread` returns only `clientThreadId` | Report the queued ID and emit the created-task UI directive. Do not pass it to read/message/navigation/wait controls; those become available only after a real `threadId` exists. |
| Managed lifecycle | A Codex `/start-ticket` with `Worktree: current` initializes submodules, later reaches `/finish-ticket`, and cleans up | Every START step uses the current checkout. FINISH leaves the app-owned worktree and branch to Codex; it never removes/deletes them as workflow-owned resources. |
| Lazy notifier resolution | `/spawn-tickets #63` from Codex, Claude cloud, and Claude local | The ticket unit requests notification without resolving a session identity. Only Claude local resolves its spawner name/handle and appends `Notify:`; Codex/cloud perform no `ListAgents` lookup. |

Regression failure: any default crosses harnesses, an explicit override silently
falls back, ticket bounds are dropped, or the reported identifier/inspection
controls belong to a different harness.
