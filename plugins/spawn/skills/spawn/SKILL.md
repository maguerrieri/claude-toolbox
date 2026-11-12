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

**Projects mode first.** When this session's tools include any `mcp__hearthbot__` tool (listed or deferred), it runs in a Claude Project, where sessions start as project threads: a cloud `create_session` child would land outside the Project, where neither its thread board nor its coordinator sees it. Launch nothing here. In a thread (it has `mcp__hearthbot__reply`), say in one line of the thread's reply that each task needs its own thread (the channel session reads thread replies and starts them), and keep the tasks out of this thread's own PR. In the project's channel session (it has `mcp__hearthbot__start_thread_session`), start one thread per task with that tool instead, never one thread for several; a task that works an issue starts on the branch stem ticket-workflow's Projects mode names (`claude/<BRANCH(id)>`). Without those tools, run the steps below.

### 1 — Parse into units

Split the request into one or more `(prompt, desc)` units:
- **One task** (the common case): the whole request is the prompt. `/spawn to investigate the flaky CI` → a single unit.
- **Several tasks:** an explicit list, or "spawn N agents to each do X" → N units.

`prompt` = the full instruction the background session acts on (verbatim — don't trim the caller's bounds). `desc` = an under-5-word summary for the session name.

A unit may also carry a **`model`**, and usually doesn't. It comes from one of two places: the caller (ticket-workflow resolves one from its `Session model:` lines and hands it over with the unit; such a caller has already decided, so the next rule doesn't apply to its units), or, on a `/spawn` request, the user telling you which model the spawned session should run on ("spawn this on sonnet", "use opus for these"), which applies to the units it names. That instruction is addressed to you, so it is the one part of the request left out of the prompt; a model named as part of the task ("benchmark the summarizer on sonnet") is task text and stays in. When you can't tell which it is, pass no model and keep the words in the prompt. Spawn reads no setting of its own for it. **No model given means none passed**: the session runs on Claude Code's default. Take it only when it is a model alias or ID and nothing else, matching `^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9]+\])?$` (e.g. `sonnet`, `claude-opus-5-5`, `opus[1m]`), since it lands in a shell command. A caller hands over only a value it already checked. A user names models loosely, so first read their words as the alias they plainly mean ("on Sonnet" is `sonnet`, "use Opus" is `opus`), and take "the default model" as no model at all. When what they asked for still isn't one value that fits the pattern ("Sonnet 4.5", a name you can't place), don't guess and don't launch that unit on some other model: skip it and say why in the report, so they can restate the model or drop it. The pattern checks shape, not existence: if a launch errors on the model, report that unit as failed, not launched.

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
- **Local: resume before you spawn.** When a unit may already have a session (a re-spawn after a restart or a `claude stop`, a retried fan-out), look it up with `claude agents --json --all` and resume a stopped one with `claude --bg --resume` instead of launching fresh — `backends/local.md`'s *Find and resume before you spawn*. `ListAgents` lists live sessions only, and bare `claude agents` fails without a TTY, so neither can tell you a session is gone.
- `<desc>` — under 5 words, recognizable (e.g. `investigate flaky CI`); the session's name is `<context> <desc>`.
- Pass the caller's `prompt` **verbatim**. Add no cap; the prompt carries whatever bounds the caller wrote.
- A unit's `model`, when it has one, goes where the backend file says (`--model` locally, the `model` field on cloud), on a fresh launch only. A resume never passes one: the session keeps the model it was launched with.
- **Record the handle** the launch returns (a session handle locally, a `session_...` id on cloud) — it survives a rename and is how you inspect a stuck session later.

### 5 — Report and hand back

Print a table, then stop — **don't block on the sessions**:

| Session | Scope |
|---|---|
| `misc investigate flaky CI` | <one-line summary> |

For a unit launched with a `model`, name it in its row's Scope (`… (on sonnet)`), and say when a unit wasn't launched because the model asked for was invalid. A resumed unit keeps its launch model, so claim no new one for it.

Then point at the inspect path **for your backend** — the local CLI commands and the cloud session listings are not interchangeable, and naming the wrong ones hands the user commands they can't run. The backend file spells out which to print (and the cloud one adds an ID column).

## Spawn does NOT

- Launch by the wrong mechanism for where it's running — select the backend (step 3) first. `claude --bg` from a cloud session produces sessions that die with the container and that the user can't see; `create_session` is not available locally.
- Launch from inside a disposable worktree **on the local backend** — resolve the durable launch dir first, or attach/resume breaks when the worktree is later removed. (No launch dir exists on cloud.)
- Babysit or poll the sessions — each runs on its own.
- Block on completion — spawn, report, hand back.
- Add any cap — bounds live in the prompt text.
- Know about issues / tickets / trackers / profiles — that's the `/spawn-tickets` command (the `ticket-workflow` skill).
