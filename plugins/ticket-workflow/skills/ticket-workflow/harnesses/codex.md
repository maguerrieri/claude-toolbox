# Harness: Codex

Use this adapter when the task currently executing ticket-workflow runs in
Codex. This selection describes the caller's runtime. It does not select where
generic `spawn` launches a child.

## RESOURCES

Treat the directory containing the active ticket-workflow `SKILL.md` as the
skill root. Read bundled support paths relative to that root: `roles/*.md`,
`messaging.md`, `harnesses/*.md`, `phases/*.md`, `trackers/*.md`, and bundled
`profiles/*.md`. When Codex exposes the skill as an opaque package, use that
package's resource reader with the same relative path.

A required resource that cannot be read is a hard error for the current phase:
report the relative path and stop. Never recover by walking parent directories,
searching an installed-plugin cache, or guessing another copy of the package.

## ROLE_STATE

Valid `/role` values are `planner`, `epic-coordinator`, `implementer`, and
`none`. For `adopt` of a non-`none` role, validate the value, read
`roles/<role>.md` through `RESOURCES`, and adopt that charter as governing for
the current Codex task. Keep the adoption prompt-durable in the task context
across compaction/resume. Roles are never implicitly inherited across spawn or
fork: only role-bearing ticket-workflow child edges receive their own explicit
`Role:` directive. Implementer helper work items remain role-free as specified
in `roles/implementer.md`.

Codex has no ticket-workflow plugin hook or writable per-thread environment
contract. Do not read or write Claude role markers, test
`$CLAUDE_SESSION_ID`, or claim a plugin hook, out-of-band marker, or mechanical
planner edit guard is armed. State the limitation when adopting a role:
the charter is prompt-durable in this task, and adherence is contextual rather
than mechanically guarded.

`persist` means keeping the adopted charter in this task's prompt/history; it
does not write external state. `clear` stops applying the charter in the current
task context and does not claim to delete a marker. `report` returns the role
governing this task plus the prompt-durable/no-mechanical-guard limitation. For
an invalid or empty value, report the four valid values and current contextual
role when one is known; do not change state.

## IDENTITY

A ready Codex task is addressed by the stable `threadId` together with its
`hostId`. A `clientThreadId` means native worktree setup is still queued: report
it as queued state and use it only in the created-task UI directive. Never pass
a `clientThreadId` to read, wait, navigation, follow-up, or mutation controls
that require a ready `threadId`. Task titles are display labels, never
addresses.

Generic `spawn` owns `LAUNCH`. For exact Codex creation, isolation, queued-ID,
and reporting behavior, use the generic spawn skill's `harnesses/codex.md`; do
not call native task creation or reproduce its launcher in ticket-workflow.

## MESSAGE

Read `messaging.md` for the shared state-change vocabulary and durable-record
rules. Parent-to-child steering uses the native Codex follow-up control with the
child's ready `threadId` and `hostId`.

Codex child launches carry no reverse `Notify:` directive by default because
the caller's own ready `threadId` is not reliably exposed to the child. The
parent observes progress with native wait/read controls and verifies PR/tracker
state. Only when the child is explicitly given a known, ready parent
`threadId` plus its `hostId` may it send a state-change follow-up to that stable
address. Never derive a reverse address from a title or name, use a queued
`clientThreadId`, or invent a notifier when the parent ID is unknown.

Messages are hints. Verify every state transition against PRs, issues, and
tracker `COORD` markers before acting.

## INSPECT

Use Codex's native task controls with stable IDs:

- list tasks with `list_threads`;
- inspect a ready task with `read_thread(threadId, hostId)`;
- wait for progress with `wait_threads` using `threadId` plus `hostId` and the
  returned cursor;
- steer a ready task with `send_message_to_thread(threadId, hostId)`; and
- open it with `navigate_to_codex_page(threadId)`.

Poll with read/wait when there is no reverse notifier. A child notice only
schedules a re-check; durable PR/tracker state remains completion authority.
Do not use Claude CLI commands, Claude marker paths, Claude handles,
`SendMessage`/`ListAgents`, title-based addressing, or a queued
`clientThreadId` for these operations.

## ATTRIBUTION

Use this generated-agent footer on PRs and other generated artifacts:

```markdown
🤖 Generated with Codex
```
