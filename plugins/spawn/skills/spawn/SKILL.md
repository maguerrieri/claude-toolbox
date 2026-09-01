---
name: spawn
description: >-
  Use when asked to spawn, fan out, kick off, background, or parallelize one or more tasks/sessions/agents for arbitrary work and hand back without blocking ("spawn a session to investigate X", "fan out 3 agents to each do Y", "run these in the background", "get X going while I'm out"). ALSO use whenever /spawn appears anywhere in a message, even mid-sentence ("make an issue and /spawn it"), and even if this skill is already in context. Generic — not ticket-specific; for issue/ticket fan-out use the /spawn-tickets command (ticket-workflow skill).
---

# Spawn (background-task fan-out)

Fan out one or more **independent** background tasks for arbitrary work, name them so they're recognizable, report a table, and hand back **without blocking**. The mechanic is ticket-agnostic — it knows nothing about issues, trackers, or profiles. (`/spawn-tickets` is a specialization that builds `/start-ticket` prompts and then uses this mechanic.)

**How** a task is launched depends on two independent launch coordinates:
the **harness** (`codex` or `claude`) and the execution **surface** (`desktop`,
`cli`, or `cloud`). Select both in step 3 before reading the one matching
adapter path. A surface is never a fallback policy.

## When to use

- "Spawn a session to investigate this." — one background task, fire-and-forget.
- "Fan out 3 agents to each try X." — several independent tasks at once.
- Any time you want work to run as its own durable background task and keep your current session free.

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

Spawn adds **no** safety bound — each task does exactly what its prompt says. If you want a limit, write it into the task text, e.g. `/spawn investigate the crash, read-only, don't push or merge`. (The ticket-only `SPAWN_CAP` is applied by the ticket-workflow SPAWN phase *before* it hands a prompt here; it is not part of generic spawn.)

## Steps

### 1 — Parse into units

First consume optional `harness?` and `surface?` values as **request-global
launch metadata**, then split the cleaned request into one or more
`(prompt, desc, name?, notify?)` units. A selected pair applies to every unit;
per-unit routing overrides are not supported. Remove all launch-flag tokens from
the whole request before splitting so none can leak into any child prompt.
Reject duplicate, conflicting, or invalid launch flags before launching
anything.

Then split the remaining work:
- **One task** (the common case): the whole request is the prompt. `/spawn to investigate the flaky CI` → a single unit.
- **Several tasks:** an explicit list, or "spawn N agents to each do X" → N units.

`prompt` = the full instruction the background task acts on (verbatim — don't trim the caller's bounds). `desc` = an under-5-word summary. `name` is optional: a delegating workflow can supply the exact task/session title; otherwise step 2 derives one. Harness adapters preserve an explicit `name` verbatim.

`notify` is also optional, lazy prompt-decoration metadata. `requested` asks the
selected adapter for a wake-up channel without resolving the caller's identity
up front. Only an adapter whose edge supports that channel resolves the spawner
name/handle and appends `Notify: <spawner>`. Other adapters omit it without
performing an identity lookup or substituting another notification mechanism.

Also parse an optional launch-only harness override:

- `--harness codex` / an explicit request for a Codex task
- `--harness claude` / an explicit request for a Claude session

The request-level parse removes the `--harness <value>` tokens before unit
construction; they select where all units run and are not work for any child.
Natural-language selection counts only
when the caller explicitly names the target harness — never infer a crossing
from the task's subject matter.

Also consume an optional `--surface desktop|cli|cloud` override at request
scope. The request-level parse removes it before unit construction just like
`--harness`. A natural-language surface choice counts only when explicit.

### 2 — Pick a context label

A short prefix that makes the task findable in the selected harness:
- In a repo / working dir → its basename (e.g. `misc`, `sonder`).
- Otherwise → a topic word from the task.

When the unit has no explicit `name`, set it to `<context> <desc>`. When it does,
keep that exact value — don't recompute it from the current directory.

### 3 — Select the harness and surface

First identify the **caller harness** and **caller surface** from the runtime
executing this skill. Retain both as launch metadata even when the target is
overridden: adapters may need to know whether a communication channel exists.

Target harness selection is deterministic:

1. An explicit override from step 1 wins.
2. Otherwise the target inherits the caller harness.

Target surface selection is also deterministic:

1. An explicit `--surface` override wins.
2. A same-harness target inherits the caller surface exactly.
3. A cross-harness target maps a local caller (`desktop` or `cli`) to the target
   harness's `cli` surface, and maps a cloud caller to the target's `cloud`
   surface. This mapping is selection, not fallback.

Use the runtime identity and native task tools already present in the session.
`CODEX_THREAD_ID` / `CODEX_SESSION_ID` or Codex task tools identify Codex;
`CLAUDE_SESSION_ID`, `CLAUDECODE`, or `CLAUDE_CODE_REMOTE_SESSION_ID` identify
Claude. Native Codex app task tools identify the Codex `desktop` surface;
`CLAUDE_CODE_REMOTE_SESSION_ID` identifies Claude `cloud`; otherwise an active
Claude Code runtime is Claude `cli`. A Codex runtime without native app task
tools is Codex `cli` unless its runtime explicitly identifies Codex cloud. The
executable being installed is not evidence that it is the caller.

- **codex** — read `harnesses/codex.md` now.
- **claude** — read `harnesses/claude.md` now.

Read exactly one harness adapter; it then reads exactly one surface adapter (or
Claude backend) and follows it for steps 4–5. If the caller signals conflict or
establishes neither harness, use the known active tool/runtime context; if that is
also ambiguous, ask instead of guessing. If the selected harness-plus-surface
launch capability is unavailable, name that exact pair and stop. Never
substitute another harness or surface, whether selection was explicit,
inherited, or cross-harness mapped.

### 4 — Spawn in parallel

Launch one task per unit, **all in a single message** so they start concurrently.
The launch mechanic is the one for the harness-plus-surface pair selected in
step 3.

Whichever harness you're on:
- `name` — the explicit unit name or step 2's `<context> <desc>` fallback.
- Preserve the caller's `prompt` **verbatim**. Add no cap; the prompt carries whatever bounds the caller wrote. An adapter may append only its documented execution directive and a supported `notify` directive; it never rewrites or drops the caller's bounds.
- **Record the stable identifier** the launch returns — a Codex task/thread ID
  or the Claude backend's session handle/ID. Names can change; identifiers are
  how a stuck task is inspected later.

### 5 — Report and hand back

Print a table, then stop — **don't block on the tasks**:

| Task | Scope |
|---|---|
| `misc investigate flaky CI` | <one-line summary> |

Then point at the inspect/open path **for the selected harness and surface**.
Codex desktop tasks, CLI jobs, and cloud sessions use different controls; the
selected adapter spells out which identifiers and controls to print.

## Spawn does NOT

- Cross harnesses by accident — default to the caller harness and cross only on
  an explicit request.
- Fall back across harnesses or surfaces when the selected pair cannot launch —
  report the exact missing capability and stop.
- Bypass a selected harness adapter's isolation rule. Codex project work uses a
  native worktree task; Claude's local backend resolves a durable launch
  directory; Claude cloud passes the repository explicitly.
- Babysit or poll the tasks — each runs on its own.
- Block on completion — spawn, report, hand back.
- Add any cap — bounds live in the prompt text.
- Know about issues / tickets / trackers / profiles — that's the `/spawn-tickets` command (the `ticket-workflow` skill).
