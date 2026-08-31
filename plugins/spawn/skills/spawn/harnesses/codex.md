# Harness: Codex (native task creation)

The selected target is a user-owned Codex task. Create a peer task in the Codex
app; do not use an in-session review/helper subagent, and do not invoke
`claude --bg`.

## Resolve the native tools

Use `list_projects` and `create_thread` (tool names are the stable interface;
their server prefix can vary). If they are not already callable, search the tool
catalog for those exact capabilities. If native Codex task creation remains
unavailable, report that the Codex harness cannot be launched from this runtime
and stop. Never fall back to Claude after Codex was selected.

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
  prompt: "<prompt>",
  title: "<context> <desc>",
  target: {
    type: "project",
    projectId: "<matched project id>",
    environment: { type: "worktree" }
  }
})
```

Pass the prompt verbatim after the shared step removed launch-only harness flags.
Omit `model` and `thinking` unless the caller explicitly requested overrides so
the task inherits the user's configured Codex defaults. Creation is non-blocking;
do not wait for the child to finish.

Record `threadId` when the task is ready or `clientThreadId` while worktree setup
is queued. Either is the stable identifier for that row.

## Report

Use Codex task terminology and include IDs:

| Task | ID | Scope |
|---|---|---|
| `toolbox investigate flaky CI` | `<threadId or clientThreadId>` | <one-line summary> |

The task appears in the Codex sidebar. Point at the native task controls: open it
from the sidebar (or navigate to it when asked), inspect progress with the Codex
task list/read controls, and send follow-ups to that task by ID. When the app
supports a created-task directive, emit it with the returned `threadId` or
`clientThreadId` so the row is directly openable.
