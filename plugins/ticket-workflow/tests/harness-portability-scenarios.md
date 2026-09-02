# Ticket-workflow Harness Portability Behavioral Scenarios

Use these scenarios as fresh-context pressure tests for `ticket-workflow`.
Evaluators inspect the routed skill/command resources and state the decision
they would make. They do not launch tasks, write role state, create PRs, or
mutate the repository.

These cases test decisions at the harness boundary. They are intentionally
separate from #63's generic Spawn launch-selection cases and #64's worktree
lifecycle coverage.

## Evaluator contract

For every case, record the evaluator's chosen action rather than matching
source phrasing. Score these observable outcomes:

| Dimension | Pass condition |
|---|---|
| Portable activation | The installed skill activates for `/role`, `/spawn-epic`, and natural requests to adopt, inspect, or clear a role or launch an epic; the portable procedure does not depend on a Claude-only command wrapper being available. |
| Resource origin | The evaluator reads an explicitly routed, harness-appropriate resource; it does not search guessed package paths. `/role` and natural role management read `phases/role.md` completely through `RESOURCES`; `/spawn-epic` reads `phases/spawn-epic.md` completely through `RESOURCES`. |
| Role state | A Codex role is adopted in the current task's prompt/context for its full lifetime, with no plugin hook, out-of-band marker, or mechanical edit-guard claim. Claude retains its documented role persistence. |
| Launch owner | Ticket-workflow delegates harness selection and native task/session creation for both epic and child launches to generic `spawn`; no duplicated ticket-workflow launcher or other harness CLI is emitted. |
| Identifier | The evaluator reports the stable identifier native to the selected harness and does not use a queued identifier with operations that require a ready task. |
| Inspection and messaging | Every ticket-workflow unit delegated to generic `spawn` sets lazy `notify: requested` metadata. Generic `spawn` alone resolves that request for the selected caller/target edge, appending a notifier only when reachable and otherwise omitting it without an unnecessary identity lookup. The evaluator selects the active harness's inspection/follow-up operation and treats child notices as hints verified through durable tracker/PR state. |
| Attribution | A generated PR footer names the active harness's generated-agent attribution, not a different harness. |

An answer fails if it gets the desired end result only by inventing a
compatibility layer, falling back across harnesses, or treating a raw source
string as the assertion. Record the selected resource/state/operation/footer
in the scenario result so a later implementation can be scored against the
same contract.

## Scenarios

| Case | Fresh-context prompt | Expected decision after the portability fix | RED observation on the #63 base |
|---|---|---|---|
| Portable role discovery | "Adopt the ticket-workflow planner role in this Codex task, show me which role is active, then clear it." | Activate `ticket-workflow` from the natural adopt/inspect/clear request (and equally from `/role`). Follow the mandatory skill index to read `phases/role.md` completely through `RESOURCES`, then run that authoritative mini-phase through the active harness's `ROLE_STATE`; do not depend on a Claude command wrapper or implement state in that wrapper. | The skill trigger names ticket phases and commands but omits `/role` and natural role-management phrases. The detailed procedure exists only in the Claude command wrapper, so a runtime that discovers portable skills rather than Claude commands cannot reliably find or execute it. |
| Portable epic launcher discovery | "From Codex, /spawn-epic #40 --harness claude --surface cloud --finish." | Activate `ticket-workflow`, follow the mandatory skill index to read `phases/spawn-epic.md` completely through `RESOURCES`, then run that authoritative thin-launch mini-phase: strip both launch-only flags from the child prompt while preserving them as generic-spawn metadata, preserve `--finish`, use the exact named unit, `Role: epic-coordinator`, and lazy `notify: requested`, add no `SPAWN_CAP`, and let generic `spawn` alone launch/report. The Claude command wrapper only delegates to this procedure. | The exact launcher procedure exists only in the Claude command wrapper. The portable skill says `/spawn-epic` is thin but does not contain enough instructions for a Codex skill-only runtime to construct the unit safely. |
| Lazy EPIC child notifier | "An EPIC wave has one ready child. Build its generic-spawn unit from Codex desktop, Claude cloud, and Claude CLI callers." | Set `notify: requested` on the unit in all three cases without reading messaging state or choosing an address. Generic `spawn` resolves and appends `Notify:` only for the reachable Claude-CLI-to-Claude-CLI edge; the Codex and cloud edges omit it without a discarded `ListAgents` lookup. | EPIC consults the active harness's `MESSAGE` operation before delegation and makes notification metadata optional, so ticket-workflow prematurely decides whether the child unit requests a notifier. |
| Codex implementer role | "You are in a Codex START run. The launch briefing contains `Role: implementer`. Locate and adopt the role charter. Explain what survives compaction or resume." | Route to a Codex-supported implementer charter without package-path discovery. Keep that adoption prompt-durable for the current Codex task across compaction/resume. Do not read/write Claude state, rely on a plugin hook or out-of-band marker, or claim a mechanical edit guard. | The evaluator routes to `plugins/ticket-workflow/skills/ticket-workflow/roles/implementer.md`, then writes `implementer` to `${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}/$CLAUDE_SESSION_ID`. It names `CLAUDE_SESSION_ROLES_DIR`, `HOME`, and `CLAUDE_SESSION_ID`; no Codex-native identifier, state directory, hook, reinjection mechanism, or degradation is specified. If `CLAUDE_SESSION_ID` is unset, persistence is skipped. |
| Codex epic coordinator | "From a Codex task, run `/spawn-epic #40` in the background. Then show how I can inspect it and how the coordinator will inspect or redirect a child task." | Delegate epic and child launch selection plus native Codex task creation to generic `spawn`; do not duplicate launcher logic in ticket-workflow. Report a ready `threadId` (or only report `clientThreadId` while queued) and use Codex task inspection/wait/follow-up/navigation controls. Child notices are optional hints and durable PR/epic-comment state remains authoritative. Do not attach a reverse notifier unless the parent has an explicitly known, ready `threadId`; never invent one from a title, name, or implicit parent. | `/spawn-epic` launches `claude --bg` from the main checkout and returns a Claude handle. Its stated controls are `claude agents`, `claude attach`, and `claude logs`; EPIC Step 5 launches each child with `claude --bg`. It uses `SendMessage`/`ListAgents` with Claude session names or handles and defaults EPIC children to `Notify: <orchestrator session name>`. PR and epic-comment state are the only harness-independent durable record. |
| Codex START PR attribution | "You are a Codex implementer completing START for issue #65. Draft the PR body, including its generated-agent attribution." | Produce the selected tracker's PR template with a Codex-generated-agent footer. The footer must identify Codex, while preserving tracker-required issue closure and test-plan content. | The mandatory PR template ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`, so a Codex implementer attributes the PR to Claude Code. The GitHub profile also requires an issue-closing footer such as `Closes #65`. |
| Claude Code local role and messaging control | "You are a local Claude Code coordinator. A child START briefing has `Role: implementer` and `Notify: <coordinator session name>`. Explain role persistence, the child's `done:` notification, and how you verify completion or inspect the child." | Preserve the existing local-Claude route: use the Claude role charter and its documented session-role persistence, send `done:` through the local Claude message operation to the coordinator session (with its resolved reference if required), and verify durable PR/tracker state before treating it as complete. Use local Claude inspection controls. | This control remains Claude-specific: role state is the `CLAUDE_SESSION_ROLES_DIR` marker keyed by `CLAUDE_SESSION_ID`; `done:` is sent through `SendMessage` to the coordinator session name, retrying with the ` [ref]` suffix after `ListAgents` if needed. The coordinator verifies branch PR state and may use `claude agents`, `claude logs <handle>`, or `claude attach "<name>"`. |

## Result record template

Copy this block for each evaluation. It makes failures comparable without
requiring the evaluator to reproduce implementation prose.

```text
Case:
Selected harness/backend:
Resource origin selected:
Role-state prompt/context control selected:
Launch owner/delegation and launch operation:
Stable identifier reported:
Inspection/follow-up operation:
Reverse notifier (ready parent `threadId`, or omitted):
Durable completion verification:
PR attribution/footer:
Verdict: PASS | FAIL
Observed reason:
```

Regression failure: a Codex case reads or writes Claude-specific role state,
uses a plugin hook/out-of-band marker or mechanical edit guard for role
persistence, duplicates generic Spawn launch selection/creation, launches a
Claude session, reports or operates on a Claude handle, uses Claude-only
message/inspection controls, invents a reverse notifier without a ready parent
`threadId`, or attributes a Codex-created PR to Claude Code. A Claude-local
control failure is any loss of its existing role, notification,
durable-verification, or inspection behavior.
