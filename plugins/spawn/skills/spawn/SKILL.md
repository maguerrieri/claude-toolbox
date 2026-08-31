---
name: spawn
description: Use when asked to spawn, fan out, kick off, background, or parallelize one or more sessions/agents for arbitrary tasks and hand back without blocking ("spawn a session to investigate X", "fan out 3 agents to each do Y", "run these in the background", "get X going while I'm out"). ALSO use whenever /spawn appears anywhere in a message, even mid-sentence ("make an issue and /spawn it"), and even if this skill is already in context. Generic — not ticket-specific; for issue/ticket fan-out use the /spawn-tickets command (ticket-workflow skill).
---

# Spawn (background-session fan-out)

Fan out one or more **independent** background sessions for arbitrary work, name them so they're recognizable, report a table, and hand back **without blocking**. The mechanic is ticket-agnostic — it knows nothing about issues, trackers, or profiles. (`/spawn-tickets` is a specialization that builds `/start-ticket` prompts and then uses this mechanic.)

**How** a session is launched first depends on the execution **harness** — Codex
or Claude. The Claude harness then selects its local/cloud **backend**. Those are
separate axes: harness selection happens in step 3, before any backend choice.

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

Also parse an optional launch-only harness override:

- `--harness codex` / an explicit request for a Codex task
- `--harness claude` / an explicit request for a Claude session

Remove the `--harness <value>` tokens from `prompt`; they select where the unit
runs and are not work for the child. Reject an unknown value or conflicting
overrides before launching anything. Natural-language selection counts only
when the caller explicitly names the target harness — never infer a crossing
from the task's subject matter.

### 2 — Pick a context label

A short prefix that makes the task findable in the selected harness:
- In a repo / working dir → its basename (e.g. `misc`, `sonder`).
- Otherwise → a topic word from the task.

### 3 — Select the harness

Selection precedence is deterministic:

1. An explicit override from step 1 wins.
2. Otherwise inherit the harness executing this skill.

Use the runtime identity and native task tools already present in the session.
`CODEX_THREAD_ID` / `CODEX_SESSION_ID` or Codex task tools identify Codex;
`CLAUDE_SESSION_ID`, `CLAUDECODE`, or `CLAUDE_CODE_REMOTE_SESSION_ID` identify
Claude. The executable being installed is not evidence that it is the current
harness — a Codex machine may also have `claude`, which is the regression this
step prevents.

- **codex** — read `harnesses/codex.md` now.
- **claude** — read `harnesses/claude.md` now.

Read exactly one harness adapter and follow it for steps 4–5. If the signals
conflict or establish neither harness, use the known active tool/runtime context;
if that is also ambiguous, ask instead of guessing. If an explicitly selected
harness's native launch capability is unavailable, report that and stop — never
silently fall back to the current harness.

### 4 — Spawn in parallel

Launch one task per unit, **all in a single message** so they start concurrently.
The launch mechanic is the one in the harness adapter selected in step 3 (and,
for Claude, the backend that adapter selects).

Whichever harness you're on:
- `<desc>` — under 5 words, recognizable (e.g. `investigate flaky CI`); the session's name is `<context> <desc>`.
- Pass the caller's `prompt` **verbatim**. Add no cap; the prompt carries whatever bounds the caller wrote.
- **Record the stable identifier** the launch returns — a Codex task/thread ID
  or the Claude backend's session handle/ID. Names can change; identifiers are
  how a stuck task is inspected later.

### 5 — Report and hand back

Print a table, then stop — **don't block on the sessions**:

| Session | Scope |
|---|---|
| `misc investigate flaky CI` | <one-line summary> |

Then point at the inspect/open path **for the selected harness**. Codex sidebar
tasks, local Claude CLI jobs, and Claude cloud sessions use different controls;
the selected adapter spells out which identifiers and controls to print.

## Spawn does NOT

- Cross harnesses by accident — default to the active harness and cross only on
  an explicit request.
- Substitute another harness when an override cannot launch — report the missing
  native capability and stop.
- Bypass a selected harness adapter's isolation rule. Codex project work uses a
  native worktree task; Claude's local backend resolves a durable launch
  directory; Claude cloud passes the repository explicitly.
- Babysit or poll the sessions — each runs on its own.
- Block on completion — spawn, report, hand back.
- Add any cap — bounds live in the prompt text.
- Know about issues / tickets / trackers / profiles — that's the `/spawn-tickets` command (the `ticket-workflow` skill).
