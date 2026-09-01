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
surface flags. For a Git project worktree target, append `Worktree: current`;
that execution directive tells arbitrary work to stay in the native Codex
checkout and tells ticket START to reuse it instead of creating a second
worktree. Do not append the directive for non-Git local or projectless targets,
which have no managed worktree. Ignore optional `notify` metadata: Codex peer
tasks do not use ticket-workflow's in-session SendMessage edge, so their progress
is read through native task and PR state instead.

Preserve an explicit unit `name` verbatim; otherwise use the shared
`<context> <desc>` fallback. Omit `model` and `thinking` unless the caller
explicitly requested overrides so the task inherits the user's configured Codex
defaults. Creation is non-blocking; do not wait for the child to finish.

Record `threadId` when the task is ready or `clientThreadId` while worktree setup
is queued. They have different control contracts:

- `threadId` — ready task; safe for read, navigation, wait, follow-up, and task
  mutation tools.
- `clientThreadId` — setup queue identifier; report it and use it only in the
  created-task UI directive. Never pass it to a tool that requires `threadId`.

## Report

Use Codex task terminology and include IDs:

| Task | ID | Scope |
|---|---|---|
| `toolbox investigate flaky CI` | `<threadId or clientThreadId>` | <one-line summary> |

The task appears in the Codex sidebar. For a ready `threadId`, point at the
native task controls: open it from the sidebar (or navigate to it when asked),
inspect progress with Codex task list/read controls, and send follow-ups by
thread ID. For a queued `clientThreadId`, say setup is pending and do not
advertise thread-only controls yet. Emit the app's created-task directive with
whichever identifier was returned so the queued/ready row is directly openable.
