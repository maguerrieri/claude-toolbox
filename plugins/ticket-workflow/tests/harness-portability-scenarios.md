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
| Resource origin | The evaluator reads an explicitly routed, harness-appropriate resource; it does not search guessed package paths. |
| Role state | The evaluator uses only state and persistence controls supported by the active harness, or explicitly reports that no such control is available. |
| Launch owner | The selected harness owns both the epic launch and child launch; no other harness CLI is emitted. |
| Identifier | The evaluator reports the stable identifier native to the selected harness and does not use a queued identifier with operations that require a ready task. |
| Inspection and messaging | The evaluator selects the active harness's inspection/follow-up operation, and treats child notices as hints verified through durable tracker/PR state. |
| Attribution | A generated PR footer names the active harness's generated-agent attribution, not a different harness. |

An answer fails if it gets the desired end result only by inventing a
compatibility layer, falling back across harnesses, or treating a raw source
string as the assertion. Record the selected resource/state/operation/footer
in the scenario result so a later implementation can be scored against the
same contract.

## Scenarios

| Case | Fresh-context prompt | Expected decision after the portability fix | RED observation on the #63 base |
|---|---|---|---|
| Codex implementer role | "You are in a Codex START run. The launch briefing contains `Role: implementer`. Locate and adopt the role charter. Explain what survives compaction or resume, including any role-state write you would make." | Route to a Codex-supported implementer charter without package-path discovery. Persist only through a documented Codex state/control, keyed by a Codex task/session identifier, or explicitly report the defined Codex degradation. Do not read/write Claude state or rely on Claude hooks. | The evaluator routes to `plugins/ticket-workflow/skills/ticket-workflow/roles/implementer.md`, then writes `implementer` to `${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}/$CLAUDE_SESSION_ID`. It names `CLAUDE_SESSION_ROLES_DIR`, `HOME`, and `CLAUDE_SESSION_ID`; no Codex-native identifier, state directory, hook, reinjection mechanism, or degradation is specified. If `CLAUDE_SESSION_ID` is unset, persistence is skipped. |
| Codex epic coordinator | "From a Codex task, run `/spawn-epic #40` in the background. Then show how I can inspect it and how the coordinator will inspect or redirect a child task." | Launch a native Codex epic-coordinator task and native Codex children. Report a ready `threadId` (or only report `clientThreadId` while queued); use Codex task inspection/wait/follow-up/navigation controls. Child notices are optional hints and durable PR/epic-comment state remains authoritative. | `/spawn-epic` launches `claude --bg` from the main checkout and returns a Claude handle. Its stated controls are `claude agents`, `claude attach`, and `claude logs`; EPIC Step 5 launches each child with `claude --bg`. It uses `SendMessage`/`ListAgents` with Claude session names or handles and defaults EPIC children to `Notify: <orchestrator session name>`. PR and epic-comment state are the only harness-independent durable record. |
| Codex START PR attribution | "You are a Codex implementer completing START for issue #65. Draft the PR body, including its generated-agent attribution." | Produce the selected tracker's PR template with a Codex-generated-agent footer. The footer must identify Codex, while preserving tracker-required issue closure and test-plan content. | The mandatory PR template ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`, so a Codex implementer attributes the PR to Claude Code. The GitHub profile also requires an issue-closing footer such as `Closes #65`. |
| Claude Code local role and messaging control | "You are a local Claude Code coordinator. A child START briefing has `Role: implementer` and `Notify: <coordinator session name>`. Explain role persistence, the child's `done:` notification, and how you verify completion or inspect the child." | Preserve the existing local-Claude route: use the Claude role charter and its documented session-role persistence, send `done:` through the local Claude message operation to the coordinator session (with its resolved reference if required), and verify durable PR/tracker state before treating it as complete. Use local Claude inspection controls. | This control remains Claude-specific: role state is the `CLAUDE_SESSION_ROLES_DIR` marker keyed by `CLAUDE_SESSION_ID`; `done:` is sent through `SendMessage` to the coordinator session name, retrying with the ` [ref]` suffix after `ListAgents` if needed. The coordinator verifies branch PR state and may use `claude agents`, `claude logs <handle>`, or `claude attach "<name>"`. |

## Result record template

Copy this block for each evaluation. It makes failures comparable without
requiring the evaluator to reproduce implementation prose.

```text
Case:
Selected harness/backend:
Resource origin selected:
Role-state path/control selected (or declared degradation):
Launch owner and launch operation:
Stable identifier reported:
Inspection/follow-up operation:
Durable completion verification:
PR attribution/footer:
Verdict: PASS | FAIL
Observed reason:
```

Regression failure: a Codex case reads or writes Claude-specific role state,
launches a Claude session, reports or operates on a Claude handle, uses
Claude-only message/inspection controls, or attributes a Codex-created PR to
Claude Code. A Claude-local control failure is any loss of its existing role,
notification, durable-verification, or inspection behavior.
