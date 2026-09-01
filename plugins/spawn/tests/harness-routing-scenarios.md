# Harness Routing Behavioral Scenarios

Use these scenarios as fresh-context pressure tests for the installed `spawn`
and `ticket-workflow` skills. Evaluators inspect the relevant skill and command
files, state what they would do, and do not actually launch tasks or mutate the
repository.

For every case record:

- selected harness and execution surface (`desktop`, `cli`, or `cloud`), plus
  the subordinate backend when an adapter uses one;
- native launch mechanism;
- stable address/identifier reported to the user;
- inspection/open controls;
- whether the original prompt is preserved; and
- whether launch-only flags leaked into the child prompt;
- whether an explicit unit name is preserved verbatim;
- whether the selected harness creates or reuses the right workspace; and
- whether notification and queued-identifier controls match the actual edge.

| Case | Request context | Expected behavior |
|---|---|---|
| Codex desktop default | From a Codex desktop task, `/spawn investigate flaky CI` | Inherit Codex + desktop. Create a native Codex task, report its ready `threadId` + `hostId` (or queued-only `clientThreadId`) and sidebar/open controls, and never launch either CLI. The native project target supplies the worktree; generic spawn injects no `Worktree:` directive. |
| Codex CLI default | From Codex CLI, `/spawn investigate flaky CI` | Inherit Codex + CLI. If no durable non-blocking Codex CLI launcher is available, report that exact capability error and launch nothing; never jump to Codex desktop, Codex cloud, or Claude. |
| Claude local default | From local Claude Code, `/spawn investigate flaky CI` | Select the Claude harness, then the local backend. Preserve PR #58's `claude --bg` behavior, report its stable handle, and use that handle for CLI inspect controls. |
| Claude cloud default | From Claude Code on the web, `/spawn investigate flaky CI` | Select the Claude harness, then the cloud backend. Preserve PR #58's `create_session` source propagation and cloud inspection controls. |
| Codex desktop to Claude override | From Codex desktop, `/spawn --harness claude investigate flaky CI` | Select Claude explicitly and map the local crossing to Claude CLI. Launch `claude --bg`, report its CLI controls, and do not create a Codex task. This documented mapping is not a fallback. |
| Claude CLI to Codex override | From local Claude Code, `/spawn --harness codex investigate flaky CI` | Select Codex explicitly and map the local crossing to Codex CLI. If that surface lacks a durable non-blocking launcher, report the capability error and stop; never substitute Codex desktop or Claude. |
| Explicit Codex desktop crossing | From Claude CLI, `/spawn --harness codex --surface desktop investigate flaky CI` | Select exactly Codex + desktop. Use native Codex task creation when available; otherwise report that exact capability error. Strip both launch-only flags and never substitute Codex CLI or cloud. |
| Explicit Claude cloud crossing | From Codex desktop, `/spawn --harness claude --surface cloud investigate flaky CI` | Select exactly Claude + cloud. Use the cloud adapter only when its native launcher is available; otherwise report that exact capability error. Strip both flags and never run `claude --bg`. |
| Cloud to explicit Claude CLI | From a cloud caller, `/spawn --harness claude --surface cli investigate flaky CI` | Explicitly select Claude + CLI, then report that the pair is unavailable because the user cannot durably access container-local jobs or CLI inspect controls. Launch nothing and never fall back to Claude cloud. |
| Invalid override | `/spawn --harness turtles investigate flaky CI` | Reject the value and list `codex` and `claude`; launch nothing. |
| Invalid surface | `/spawn --surface basement investigate flaky CI` | Reject the value and list `desktop`, `cli`, and `cloud`; launch nothing. |
| Codex desktop ticket default | From Codex desktop, `/spawn-tickets #63` | Create a native Codex task whose prompt contains `/start-ticket #63`, the complete `SPAWN_CAP`, and `Role: implementer`, with no injected `Worktree:` directive. START detects and reuses the native linked worktree, then selects the tracker's issue branch instead of creating a sibling. Report the ready `threadId` + `hostId`, or queued-only `clientThreadId`, with matching controls. |
| Codex desktop EPIC child | A Codex EPIC wave supplies `Worktree: epic-40-63` in its named child unit | Preserve that one named directive unchanged; generic spawn appends no second workspace directive. START detects and reuses the native linked worktree, then selects or creates exact issue branch `epic-40-63` there. |
| Ticket override isolation | From Codex desktop, `/spawn-tickets #63 --harness claude --surface cloud` | Select exactly Claude + cloud, but omit both launch flags from the spawned `/start-ticket` prompt. Preserve the ticket briefing, cap, and role exactly. Perform no Claude `ListAgents` lookup and append no `Notify:` across the harness/surface boundary. If cloud launch is unavailable, fail without starting local Claude. |
| File then spawn | From Codex desktop, `/make-ticket investigate X --spawn` | After filing, pass the new issue ID through the same ticket SPAWN path and inherit Codex + desktop unless an explicit launch override was supplied. |
| Exact delegated name | Ticket SPAWN supplies `widgets #63: inherit harness` | Every harness adapter uses that exact name/title; generic spawn does not rebuild it from cwd. |
| CLI notifier | From Claude CLI, `/spawn-tickets #63` with a reachable spawner name | Append `Notify: <spawner>` as adapter-supported prompt metadata so START can send `pushed:`/`done:`/`blocked:`/`filed:`. Cloud, desktop, and cross-harness edges omit it. |
| Queued Codex task | Codex `create_thread` returns only `clientThreadId` | Report the queued ID and emit the created-task UI directive. Do not pass it to read/message/navigation/wait controls; those become available only after a real `threadId` exists. |
| Managed lifecycle | A Codex `/start-ticket` runs in the native linked worktree, later reaches `/finish-ticket`, and cleans up | Every START step uses the inherited checkout. Re-entering START switches to an existing issue branch instead of trying to recreate it. FINISH leaves the app-owned worktree and branch to Codex; it never removes/deletes them as workflow-owned resources. |
| Lazy notifier resolution | `/spawn-tickets #63` from Codex desktop, Claude cloud, and Claude CLI | The ticket unit requests notification without resolving a session identity. Only Claude CLI-to-Claude-CLI resolves its spawner name/handle and appends `Notify:`; other pairs perform no `ListAgents` lookup. |
| PR workspace marker | START opens a PR first from a workflow-owned checkout, then from a harness-provided linked checkout | The template tells the agent to delete the `WORKSPACE_MARKER` line for the workflow-owned checkout and replace it with exactly `<!-- ticket-workflow-workspace: harness -->` for the harness-owned checkout. Neither PR body contains a literal conditional placeholder. |
| Stable Claude CLI inspection | Generic Claude CLI spawn and `/spawn-epic` each return a display name plus a session handle | Both report the stable handle and use it with `claude attach "<handle>"` / `claude logs "<handle>"`. The mutable name remains a display label, never the only inspection key. |
| Harness-neutral terminology | A reader follows generic `spawn` for Codex desktop and Claude CLI targets | Shared instructions call spawned units background tasks and use task/session only where the selected adapter supplies that term; the title, introduction, stable-ID contract, and generic report do not imply every Codex task is a session. |
| Multi-unit global overrides | `/spawn task A ; task B --harness claude --surface cli` | Parse each override once as request-global launch metadata, apply the same Claude + CLI pair to both units, and remove both flags from every child prompt. Reject duplicate, conflicting, or unit-specific override attempts before any launch. |
| Harness-neutral PR attribution | START opens the same ticket PR once from Codex and once from Claude | The shared PR template uses a fixed harness-neutral AI-agent footer that is accurate for both origins; it never labels a Codex-authored PR as generated by Claude Code or vice versa. |

Regression failure: any default loses the caller's harness/surface, a documented
local crossing selects a non-CLI surface, an explicit override silently falls
back, launch-only flags leak, ticket bounds are dropped, Codex desktop injects
a workspace directive instead of preserving the unit's named-or-absent shape,
or the reported identifier/inspection controls belong to a different harness
or surface.
