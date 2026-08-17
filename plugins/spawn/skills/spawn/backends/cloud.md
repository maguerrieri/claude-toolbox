# Backend: cloud (`create_session` MCP)

The spawner is itself a cloud session (Claude Code on the web, or another remote
environment). Siblings are **cloud sessions** created through the
`Claude_Code_Remote` MCP server, each in its own container, and the user opens them
on claude.ai/code.

**Do not use `claude --bg` here**, even though the CLI is installed in the
container. A bg job would be a child process of a container that gets reclaimed
after inactivity, and the user — who is on the web, not in this container's shell —
would have no way to list, attach to, or resume it. It dies with the container.

There is likewise **no launch directory to resolve**. The whole clone is disposable;
stability comes from the session record on the server, not from a path.

## Launch

One `create_session` call per unit, **all in a single message** so they start
concurrently. Prompts travel as JSON, so none of the local backend's shell-quoting
hazards apply — pass the prompt verbatim, `$` and backticks and all.

```
create_session({
  prompt:          "<prompt>",                    // verbatim; no shell quoting needed
  title:           "<context> <desc>",            // same naming convention as local
  tags:            ["spawn:<context>"],           // makes the fan-out listable as a set
  source_url:      "<repo clone URL>",            // REQUIRED — see below
  source_revision: "<base branch>",               // omit only to accept the default branch
})
```

**`source_url` is not optional.** Omitting `environment_id` inherits the spawner's
*environment*, but **not its git source** — a child spawned without `source_url`
comes back with a `session_context` carrying no `sources` at all, i.e. no checkout
to work in. Verified: a probe session spawned with the field omitted inherited the
environment and nothing else. Resolve it from the spawner's own remote:

```bash
git remote get-url origin
```

Other fields:

- **`permission_mode`** — omit it to inherit the spawner's mode. **Never pass
  `plan`**: a `plan` session proposes a plan and then blocks for human approval in
  the web UI, so an unattended child stalls there indefinitely.
- **`outcome_branch`** — pass it when the caller needs a *deterministic* branch name
  (the ticket layer's stacking does). Otherwise leave it off and let the session
  derive its own.
- **`model` / `environment_id`** — omit both unless the caller asked for something
  specific; they inherit.

`create_session` returns the child's `id` (`session_...`) and records
`parent_session_id` pointing back at the spawner. **Record the id per unit** — it is
the durable handle, and unlike a title it can't be renamed out from under you.

## Report

Report **session IDs**, not shell commands — the local inspect commands don't exist
for a web user:

| Session | ID | Scope |
|---|---|---|
| `toolbox investigate flaky CI` | `session_01ABC…` | <one-line summary> |

Point at: the session's page on claude.ai/code (each row is openable there), or
`list_sessions({mine: true, tags: ["spawn:<context>"]})` to list the whole fan-out
and `get_session(id)` for one child's status.

## No wake-up channel on this edge

`ListAgents` does not see cloud siblings and `SendMessage` cannot reach them —
verified against a live, connected child spawned from this same backend, in **both**
directions. So:

- Emit **no** notify/mailbox directive in a cloud sibling's briefing; there is
  nothing for the child to ping and nothing that can poke it back.
- A caller that needs to know when a child finished **polls** — `get_session(id)`
  for session status, and for ticket work the PR/tracker state that is the durable
  record anyway.

`get_session` returns status, not a transcript; reading what a stuck child actually
did means opening it in the web UI.
