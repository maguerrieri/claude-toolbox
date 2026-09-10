# Backend: cloud (`create_session` MCP)

The spawner is itself a cloud session (Claude Code on the web, or another remote
environment). Siblings are **cloud sessions** created with the session-management
MCP tools — `create_session`, plus `list_sessions` / `get_session` to inspect —
each in its own container, and the user opens them on claude.ai/code.

Address those by **tool name**, not by server: they're the stable part. The server
carrying them varies by harness configuration (in Claude Code on the web it's
`Claude_Code_Remote`). If the tool names aren't in your tool list, search for them
before concluding they're unavailable.

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
create_session({"prompt": "<prompt>", "title": "<context> <desc>", "source_url": "<repo clone URL>"})
```

Those three are the required core: `prompt` is the caller's instruction **verbatim**;
`title` follows the same `<context> <desc>` convention as the local backend;
`source_url` is the repo to check out (**required** — see below).

Two optional fields, added only when they apply:

- `source_revision: "<base branch>"` — when the caller pinned a base other than the
  repo's default branch.
- `tags: ["spawn:<context>"]` — metadata for the **user's** own session listings.
  It is not how *you* find the fan-out afterwards (see Report: `parent_session_id`),
  and you can't filter on it from inside a session.

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

Point at: the session's page on claude.ai/code (each row is openable there);
`get_session(id)` for one child's status (use the ids you recorded at launch); or
`list_sessions()` filtered to rows whose `parent_session_id` equals **your own id**
(`$CLAUDE_CODE_REMOTE_SESSION_ID`) to see the whole fan-out. Every session created
by `create_session` records its spawner there, so that filter is exact — unlike
title, which the user can rename, or a `<context>` prefix, which collides across
fan-outs.

Two things about `list_sessions` that aren't obvious from its name:

- `mine: true` scopes by **account**, not by spawner — it exists for shared bot
  pools (Slack) and is a no-op on a personal account. It is not "sessions I
  spawned"; `parent_session_id` is.
- Don't pass `tags` from inside a session — the tool's contract reserves that
  filter for OAuth callers and errors otherwise. The `tags` you set at launch are
  for the user's own listings, not for yours.

## No wake-up channel on this edge

`ListAgents` does not see cloud siblings and `SendMessage` cannot reach them —
verified against a live, connected child spawned from this same backend, in **both**
directions. So:

- Emit **no** `Notify:` directive in a cloud sibling's briefing; there is
  nothing for the child to ping and nothing that can poke it back.
- A caller that needs to know when a child finished **polls** — `get_session(id)`
  for session status, and for ticket work the PR/tracker state that is the durable
  record anyway.

`get_session` returns status, not a transcript; reading what a stuck child actually
did means opening it in the web UI.
