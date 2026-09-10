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
  derive its own. Verified 2026-09-10 against a real child spawned with
  `source_revision: <base>` + `outcome_branch: <name>`: the container comes up with
  `<name>` **already checked out** — a plain checkout of the clone (no worktree), no
  upstream configured, at the tip of `<base>` — and the child's harness prompt names
  `<name>` as its designated branch ("develop on branch `<name>`", `git push -u origin
  <name>`). No env var carries either value; `get_session` shows them under
  `session_context.sources[].revision` / `outcomes[].git_info.branches`. The branch
  does **not** exist on origin until the child pushes, so "does `origin/<name>`
  exist" is a valid pushed-yet signal. A briefing directive that names the same
  branch (the ticket layer's `Worktree:`) does not fight it — the child finds the
  branch already checked out and reuses it.
- **`source_revision`** — the checkout *is* the child's base: it starts on
  `outcome_branch` at exactly this revision, so it must already be on origin at
  launch — a caller stacking one child on another's branch gates the launch on
  that branch being pushed (`git ls-remote --heads origin <branch>`), rather than
  launching early and hoping the checkout waits.
- **`model` / `environment_id`** — omit both unless the caller asked for something
  specific; they inherit.

`create_session` returns the child's `id` (`session_...`) and records
`parent_session_id` pointing back at the spawner. **Record the id per unit** — it is
the durable handle, and unlike a title it can't be renamed out from under you.

## Don't lead the prompt with a slash command the target lacks

A prompt that **begins** with a slash command (`/start-ticket …`, `/spawn …`) is
dispatched as a command by the child's harness *before the model runs*. If that
command isn't installed in the child's environment — the plugin isn't enabled
there, even though the repo may carry it — the harness rejects the prompt with
"Unknown command" and the session never does anything; it looks launched and
simply produces nothing. Observed 2026-09-10 on a real fan-out from a cloud
session: children briefed with a leading `/start-ticket` were rejected this way;
the relaunch with prose worked.

The child inherits the spawner's environment, so the test is local: if *you* can
invoke the command as a slash command in this session, so can the child, and a
leading slash command is fine. If you are following a skill by reading its file
from the checkout (because the command wasn't there for you either), **lead with
prose that names the file** — e.g. `Start work on issue #42. Read
plugins/ticket-workflow/skills/ticket-workflow/SKILL.md and follow its START phase
for #42.` — and put the rest of the briefing after it. A slash command *mid-prompt*
is only text; the rejection is about the first token.

## Report

Report **session IDs**, not shell commands — the local inspect commands don't exist
for a web user:

| Session | ID | Scope |
|---|---|---|
| `toolbox investigate flaky CI` | `session_01ABC…` | <one-line summary> |

Point at: the session's page on claude.ai/code (each row is openable there);
`get_session(id)` for one child's status (use the ids you recorded at launch —
beyond `session_status` it carries `status_bucket`, a `post_turn_summary` the child
wrote when it last went idle, and `external_metadata.current_branches`, enough to
tell working / idle-with-a-summary / ended without opening the transcript); or
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

**The poller is itself reclaimed while it waits.** A cloud container is released
after a period of inactivity, and a turn spent waiting on children is inactivity —
so a caller that must outlive its children (an aggregating orchestrator) cannot
sit in a poll loop. It arms `send_later` (a self-bound one-shot Routine that
delivers a message as a user turn into the same session, survives container
reclaim, and disables itself after firing), **ends the turn**, and re-checks when
the message arrives. The ticket-workflow skill's EPIC phase (`phases/epic.md`
Step 6) is the worked example.

**The one working spawner→child path is a scheduled Routine, and it is
narrow.** Verified 2026-09-10 against a live child, three ways at once:

- `create_trigger({"persistent_session_id": "<child id>", "run_once_at":
  "<a minute or more ahead>", "prompt": "<message>", "initiation":
  "own_followup"})` **delivers** — the child received the prompt as a user turn
  at the scheduled minute and acted on it (its run record names the child's
  session id).
- `fire_trigger` on that same Routine does **not** reach the child: the force-run
  minted a *new* session (origin `force_run_trigger`, no sources) that the child
  never saw. Schedule, don't fire.
- `update_trigger` refuses to change the prompt of a Routine bound to a session
  that isn't your own — the message is fixed at creation; to say something else,
  create another Routine.

So it is a one-shot, minute-granularity, same-account **poke**, not a
conversation: fine for a rare redirect ("stop", "rebase onto <base>"), wrong for
anything chatty, and it goes one way — the child cannot reach you back (a child
could bind a Routine to *your* id the same way, but nothing in this backend
arranges that, so don't count on it). Everything a child needs by default still
goes in its `prompt`.
