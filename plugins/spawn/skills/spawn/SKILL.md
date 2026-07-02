---
name: spawn
description: Use when asked to spawn, fan out, kick off, background, or parallelize one or more sessions/agents for arbitrary tasks and hand back without blocking ("spawn a session to investigate X", "fan out 3 agents to each do Y", "run these in the background", "get X going while I'm out"). ALSO use whenever /spawn appears anywhere in a message, even mid-sentence ("make an issue and /spawn it"), and even if this skill is already in context. Generic — not ticket-specific; for issue/ticket fan-out use the /spawn-tickets command (ticket-workflow skill).
---

# Spawn (background-session fan-out)

Fan out one or more **independent** background `claude --bg` sessions for arbitrary work, name them so they're recognizable in `claude agents`, report a table, and hand back **without blocking**. The mechanic is ticket-agnostic — it knows nothing about issues, trackers, or profiles. (`/spawn-tickets` is a specialization that builds `/start-ticket` prompts and then uses this mechanic.)

## When to use

- "Spawn a session to investigate this." — one background task, fire-and-forget.
- "Fan out 3 agents to each try X." — several independent tasks at once.
- Any time you want work to run in its own durable `claude --bg` session and keep your current session free.

**Not for:** work you must watch to completion or aggregate (that's babysitting — do it inline, or use the ticket-workflow EPIC phase). Issue/ticket fan-out → use the `/spawn-tickets` command (the `ticket-workflow` skill).

## Invocation discipline

A `/spawn` mention appearing **anywhere** in the user's message — mid-sentence, in any casing, woven into a sentence ("and /spawn it") — is an invocation of that command, not a figure of speech. (A `/spawn-tickets` mention is the `ticket-workflow` skill's territory — route there, not here.) Natural-language equivalents that match this skill's description count the same.

Invoke the covering skill via the Skill tool for **every** new request it covers, even if that skill's content is already in your context from earlier in the session.

| Rationalization | Reality |
|---|---|
| "The skill is already in context — I'll just run `claude --bg` myself" | Hand-rolled spawns drift from the skill (naming, quoting, reporting) and silently skip skill updates. Invoke the skill. |
| "It's a small one-off spawn" | Size doesn't change the mechanics. Invoke the skill. |
| "The user only mentioned /spawn in passing" | Mentioning `/spawn` with a target IS calling it. Invoke the skill. |

Compound requests ("make an issue and /spawn it"): do **both halves in the same turn** — create, then immediately spawn with the result. Don't park the spawn behind a report or a clarifying question unless the spawn itself is genuinely ambiguous.

## No cap

Spawn adds **no** safety bound — each session does exactly what its prompt says. If you want a limit, write it into the task text, e.g. `/spawn investigate the crash, read-only, don't push or merge`. (The ticket-only `SPAWN_CAP` is applied by the ticket-workflow SPAWN phase *before* it hands a prompt here; it is not part of generic spawn.)

## Steps

### 1 — Parse into units

Split the request into one or more `(prompt, desc)` units:
- **One task** (the common case): the whole request is the prompt. `/spawn to investigate the flaky CI` → a single unit.
- **Several tasks:** an explicit list, or "spawn N agents to each do X" → N units.

`prompt` = the full instruction the background session acts on (verbatim — don't trim the caller's bounds). `desc` = an under-5-word summary for the session name.

### 2 — Pick a context label

A short prefix that makes the session findable in `claude agents`:
- In a repo / working dir → its basename (e.g. `misc`, `sonder`).
- Otherwise → a topic word from the task.

### 3 — Resolve a durable launch directory

The bg job records its launch cwd (in `~/.claude/jobs/<id>/state.json`), and later attach/resume re-enters that directory. **Never spawn a background session from inside a disposable worktree** — once the worktree is cleaned up (e.g. when the spawning ticket session finishes), the recorded cwd dangles and attaching to the spawned job fails with "session ended", even if the job completed fine.

- **In a git checkout:** launch from the repo's **main checkout** — the first entry of `git worktree list`:
  ```bash
  launch_dir=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //'); launch_dir=${launch_dir:-$PWD}
  ```
  (`--porcelain` keeps paths with spaces intact; in typical layouts the parent of `git rev-parse --git-common-dir` gives the same answer.) The `${launch_dir:-$PWD}` fallback makes the line safe to run unconditionally — inside a main checkout it's a no-op, and outside any git repo it resolves to the current dir instead of erroring. The spawned session sets up its own workspace anyway; the launch cwd only needs to be **stable**.
- **Not in a git repo:** the fallback above gives the current dir — fine, unless it's itself temporary (a job tmp dir, `/tmp`), in which case pick a durable one (e.g. `$HOME` or the relevant project dir).

### 4 — Spawn in parallel

One Bash call per unit, **all in a single message** so they launch concurrently — each wrapped in a subshell so the `cd` to the durable launch dir doesn't leak into your session:

```bash
( cd "$launch_dir" && claude --bg --name "<context> <desc>" "<prompt>" )
```

- `<desc>`: under 5 words, recognizable (e.g. `investigate flaky CI`). Spaces and special characters are fine — keep `--name`'s argument quoted.
- `<prompt>`: quote it so the shell can't mangle it. Plain prose in double quotes is fine (apostrophes are safe), but if the prompt contains `$`, backticks, or `$(...)`, double quotes will **expand** them and corrupt the spawned prompt. For those, feed the prompt through a single-quoted heredoc into a variable and pass the variable:
  ```bash
  read -r -d '' p <<'PROMPT'
  …prompt text, verbatim…
  PROMPT
  ( cd "$launch_dir" && claude --bg --name "<context> <desc>" "$p" )
  ```
- Add no cap; the prompt carries whatever bounds the caller wrote.
- `claude --bg` prints a **session handle** at spawn — record it per unit; it survives the user renaming the session and is how you inspect a stuck one later.

### 5 — Report and hand back

Print a table, then stop — **don't block on the sessions**:

| Session | Scope |
|---|---|
| `misc investigate flaky CI` | <one-line summary> |

Point at the inspect commands: `claude agents` (list), `claude attach "<name>"` (open), `claude logs "<name>"` (read-only). Quote names — they contain spaces.

## Spawn does NOT

- Launch from inside a disposable worktree — resolve the durable launch dir (step 3) first, or attach/resume breaks when the worktree is later removed.
- Babysit or poll the sessions — each runs on its own.
- Block on completion — spawn, report, hand back.
- Add any cap — bounds live in the prompt text.
- Know about issues / tickets / trackers / profiles — that's the `/spawn-tickets` command (the `ticket-workflow` skill).
