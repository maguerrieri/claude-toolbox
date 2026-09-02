---
name: spawn
description: Use when asked to spawn, fan out, kick off, background, or parallelize one or more sessions/agents for arbitrary tasks and hand back without blocking ("spawn a session to investigate X", "fan out 3 agents to each do Y", "run these in the background", "get X going while I'm out"). ALSO use whenever /spawn appears anywhere in a message, even mid-sentence ("make an issue and /spawn it"), and even if this skill is already in context. Generic — not ticket-specific; for issue/ticket fan-out use the /spawn-tickets command (ticket-workflow skill).
---

# Spawn (background-session fan-out)

Fan out one or more **independent** background sessions for arbitrary work, name them so they're recognizable, report a table, and hand back **without blocking**. The mechanic is ticket-agnostic — it knows nothing about issues, trackers, or profiles. (`/spawn-tickets` is a specialization that builds `/start-ticket` prompts and then uses this mechanic.)

**How** a session is launched depends on where you're running — local `claude --bg` jobs, or cloud sessions via MCP. That's the **backend** (step 3); everything else on this page is the same either way.

## When to use

- "Spawn a session to investigate this." — one background task, fire-and-forget.
- "Fan out 3 agents to each try X." — several independent tasks at once.
- Any time you want work to run in its own durable background session and keep your current session free.

**Not for:** work you must watch to completion or aggregate (that's babysitting — do it inline, or use the ticket-workflow EPIC phase). Issue/ticket fan-out → use the `/spawn-tickets` command (the `ticket-workflow` skill).

## Invocation discipline

A `/spawn` mention appearing **anywhere** in the user's message — mid-sentence, in any casing, woven into a sentence ("and /spawn it") — is an invocation of that command, not a figure of speech. (A `/spawn-tickets` mention is the `ticket-workflow` skill's territory — route there, not here.) Natural-language equivalents that match this skill's description count the same.

Invoke the covering skill via the Skill tool for **every** new request it covers, even if that skill's content is already in your context from earlier in the session.

| Rationalization | Reality |
|---|---|
| "The skill is already in context — I'll just launch it myself" | Hand-rolled spawns drift from the skill (backend selection, naming, quoting, reporting) and silently skip skill updates. Invoke the skill. |
| "It's a small one-off spawn" | Size doesn't change the mechanics. Invoke the skill. |
| "The user only mentioned /spawn in passing" | Mentioning `/spawn` with a target IS calling it. Invoke the skill. |

Compound requests ("make an issue and /spawn it"): do **both halves in the same turn** — create, then immediately spawn with the result. Don't park the spawn behind a report or a clarifying question unless the spawn itself is genuinely ambiguous. When the "issue" half is a tracker ticket, the `ticket-workflow` skill's `/make-ticket --spawn` is the covering command for the whole compound — route there instead of assembling the halves here.

## No cap

Spawn adds **no** safety bound — each session does exactly what its prompt says. If you want a limit, write it into the task text, e.g. `/spawn investigate the crash, read-only, don't push or merge`. (The ticket-only `SPAWN_CAP` is applied by the ticket-workflow SPAWN phase *before* it hands a prompt here; it is not part of generic spawn.)

## Steps

### 1 — Parse into units

Split the request into one or more `(prompt, desc)` units:
- **One task** (the common case): the whole request is the prompt. `/spawn to investigate the flaky CI` → a single unit.
- **Several tasks:** an explicit list, or "spawn N agents to each do X" → N units.

`prompt` = the full instruction the background session acts on (verbatim — don't trim the caller's bounds). `desc` = an under-5-word summary for the session name.

### 2 — Pick a context label

A short prefix that makes the session findable in whatever lists sessions on your backend (`claude agents` locally, the session list on cloud):
- In a repo / working dir → its basename (e.g. `misc`, `sonder`).
- Otherwise → a topic word from the task.

### 3 — Select the backend

Where you're running decides how a session is launched. Check one env var:

```bash
[ -n "${CLAUDE_CODE_REMOTE_SESSION_ID:-}" ] && echo cloud || echo local
```

- **cloud** — you're a cloud session (Claude Code on the web, or another remote environment). Read `backends/cloud.md` now.
- **local** — you're on a machine the user has a shell on. Read `backends/local.md` now.

Read exactly one, and follow it for steps 4–5. Don't guess the mechanics from memory: the two differ in more than the command name (the cloud backend has no launch directory at all, and needs the repo passed explicitly).

The backend is about **where the spawner is**, not what the task is. A local session spawns local siblings even when the work targets a remote repo.

### 4 — Spawn in parallel

Launch one session per unit, **all in a single message** so they start concurrently. The launch mechanic is the one in the backend file you read in step 3.

Whichever backend you're on:
- `<desc>` — under 5 words, recognizable (e.g. `investigate flaky CI`); the session's name is `<context> <desc>`.
- Pass the caller's `prompt` **verbatim**. Add no cap; the prompt carries whatever bounds the caller wrote.
- **Record the handle** the launch returns (a session handle locally, a `session_...` id on cloud) — it survives a rename and is how you inspect a stuck session later.

### 5 — Report and hand back

Print a table, then stop — **don't block on the sessions**:

| Session | Scope |
|---|---|
| `misc investigate flaky CI` | <one-line summary> |

Then point at the inspect path **for your backend** — the local CLI commands and the cloud session listings are not interchangeable, and naming the wrong ones hands the user commands they can't run. The backend file spells out which to print (and the cloud one adds an ID column).

## Spawn does NOT

- Launch by the wrong mechanism for where it's running — select the backend (step 3) first. `claude --bg` from a cloud session produces sessions that die with the container and that the user can't see; `create_session` is not available locally.
- Launch from inside a disposable worktree **on the local backend** — resolve the durable launch dir first, or attach/resume breaks when the worktree is later removed. (No launch dir exists on cloud.)
- Babysit or poll the sessions — each runs on its own.
- Block on completion — spawn, report, hand back.
- Add any cap — bounds live in the prompt text.
- Know about issues / tickets / trackers / profiles — that's the `/spawn-tickets` command (the `ticket-workflow` skill).
