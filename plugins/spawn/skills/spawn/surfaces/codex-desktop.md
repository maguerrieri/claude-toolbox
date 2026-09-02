# Codex surface: desktop

The selected target is a user-owned task in the Codex desktop app.

## Resolve the native tools

Use `list_projects` and `create_thread` (tool names are the stable interface;
their server prefix can vary). If they are not already callable, search the tool
catalog for those exact capabilities. If native Codex task creation remains
unavailable, report that the selected `codex+desktop` pair cannot be launched
from this runtime and stop.

## Choose the target

Call `list_projects` once. For repository work, match the current repository or
the project named by the caller:

- Git repository project → `target.type = "project"` with
  `environment.type = "worktree"`.
- Non-Git saved project → `target.type = "project"` with
  `environment.type = "local"`.
- Work with no repository → `target.type = "projectless"`.

If repository work has no matching saved project, or more than one project is a
plausible match, stop and ask rather than creating a projectless task with no
checkout. Do not set a starting branch/state unless the caller explicitly asks;
the native project worktree default supplies isolation.

## Launch

Call `create_thread` once per unit, all calls in the same message:

```text
create_thread({
  prompt: "<prompt + execution directive when applicable>",
  title: "<name>",
  target: {
    type: "project",
    projectId: "<matched project id>",
    environment: { type: "worktree" }
  }
})
```

Preserve the prompt after the shared step removed launch-only harness and
surface flags. Do not append a `Worktree:` directive for any target. For a Git
project worktree target, preserve the unit's workspace contract in exactly one
of these shapes:

- **No explicit `Worktree:` directive in the unit prompt:** leave the prompt
  without one. The native Codex target already supplies the linked checkout.
- **An explicit `Worktree:` directive is present:** preserve it unchanged as
  the sole directive. In particular, an EPIC child keeps its named
  `Worktree: epic-...` assignment.

Both ticket shapes depend on ticket-workflow START's managed-checkout contract:
START detects the native linked worktree and reuses it as inherited. Without a
directive it selects the tracker's issue branch; with a named directive it
selects that exact issue branch in the same checkout. Generic spawn does not
duplicate that lifecycle logic. Non-Git local and projectless targets likewise
receive no workspace directive.

Ignore optional `notify` metadata: Codex peer tasks do not use
ticket-workflow's in-session SendMessage edge, so their progress is read through
native task and PR state instead.

Preserve an explicit unit `name` verbatim; otherwise use the shared
`<context> <desc>` fallback. Omit `model` and `thinking` unless the caller
explicitly requested overrides so the task inherits the user's configured Codex
defaults. Creation is non-blocking; do not wait for the child to finish.

Record the ready task address as both `threadId` and `hostId`, or record
`clientThreadId` while worktree setup is queued. They have different control
contracts:

- `threadId` + `hostId` — ready task address; retain and report both. Pass both
  to read, wait, follow-up, and mutation controls that accept the host. Native
  navigation uses the `threadId`.
- `clientThreadId` — setup queue identifier; report it and use it only in the
  created-task UI directive. Never pass it to a tool that requires `threadId`.

## Report

Use Codex task terminology and include IDs:

| Task | Address | Scope |
|---|---|---|
| `toolbox investigate flaky CI` | `<threadId> + <hostId>` or `<clientThreadId> (queued)` | <one-line summary> |

The task appears in the Codex sidebar. For a ready `threadId` + `hostId`, point
at the native task controls: open it from the sidebar (or navigate by
`threadId` when asked), inspect progress with Codex task list/read controls,
and send follow-ups using the ready address, including `hostId` wherever the
control accepts it. For a queued `clientThreadId`, say setup is pending and do
not advertise thread-only controls yet. Emit the app's created-task directive
with the returned `threadId` or queued `clientThreadId` so the row is directly
openable; the directive does not replace reporting the ready task's `hostId`.
