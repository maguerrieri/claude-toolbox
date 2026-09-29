# Backend: local (`claude --bg`)

The spawner is running on a machine the user has a shell on. Sessions are
background jobs of the local CLI, recorded under `~/.claude/jobs/`, and the user
inspects them with `claude agents`, `claude attach`, and `claude logs`.

## Resolve a durable launch directory

The bg job records its launch cwd (in `~/.claude/jobs/<id>/state.json`), and later
attach/resume re-enters that directory. **Never spawn a background session from
inside a disposable worktree** — once the worktree is cleaned up (e.g. when the
spawning ticket session finishes), the recorded cwd dangles and attaching to the
spawned job fails with "session ended", even if the job completed fine.

- **In a git checkout:** launch from the repo's **main checkout** — the first entry
  of `git worktree list`:
  ```bash
  launch_dir=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //'); launch_dir=${launch_dir:-$PWD}
  ```
  (`--porcelain` keeps paths with spaces intact; in typical layouts the parent of
  `git rev-parse --git-common-dir` gives the same answer.) The `${launch_dir:-$PWD}`
  fallback makes the line safe to run unconditionally — inside a main checkout it's
  a no-op, and outside any git repo it resolves to the current dir instead of
  erroring. The spawned session sets up its own workspace anyway; the launch cwd
  only needs to be **stable**.
- **Not in a git repo:** the fallback above gives the current dir — fine, unless
  it's itself temporary (a job tmp dir, `/tmp`), in which case pick a durable one
  (e.g. `$HOME` or the relevant project dir).

## Find and resume before you spawn

A background session that stopped (a machine restart, `claude stop`, a crash) or
finished (`done`) still exists and can be continued **with its context**. A
fresh session for the same unit starts from nothing: it re-reads the work from
PRs and the tracker, loses in-flight reasoning, and may redo decisions. So when a
unit may already have a session (a re-spawn after a restart, a retried fan-out, a
caller whose names are deterministic, like ticket-workflow's `<repo> <ID>: …`),
look it up first and **resume it; spawn fresh only when nothing resumable
matches**.

**Look up with `claude agents --json --all`, and nothing else.** Two lookalikes
give a false "none":

- **`ListAgents`** (the SendMessage directory) lists **live** sessions only. A
  stopped session isn't in it, so its absence proves nothing.
- **Bare `claude agents`** needs a TTY. From a tool call it exits with *"requires
  an interactive terminal (stdout is not a TTY)"*. Sending stderr to `/dev/null`
  and reading the empty output as "no sessions" is exactly how a stopped
  coordinator got replaced by a fresh one (#194).

`--json` prints interactive and background sessions without a TTY, and `--all`
adds the completed ones (without it, `done` sessions are left out). Each row has
`name`, `status`, `sessionId`, `cwd` (the recorded launch dir), `kind`, and
`startedAt`. **List once per run** and match every unit against that one
listing, rather than re-listing per unit: the list grows with every session ever
run, across every project on the machine.

**Match on the launch dir as well as the name.** The listing is machine-wide,
and a name alone can collide: two clones, or two repos with the same basename
under different owners, produce the same `<repo> <ID>: …` names. Every unit is
launched from the durable launch dir (above), so keep only rows whose `cwd` is
exactly that dir (`claude agents --cwd` matches everything *under* a path, which
is too loose). If you recorded a unit's handle at spawn, match that `sessionId`
instead: it survives the user renaming the session, which a name match misses.
Otherwise match by name, exactly or by prefix when only part of the name is
deterministic; `$ps` takes several prefixes for one unit when its name has more
than one spelling (a caller's ID with and without a `#`):

```bash
agents=$(mktemp) && claude agents --json --all > "$agents"   # once; stop here if it fails
jq --arg dir "$launch_dir" --argjson ps '["<prefix>", "<alternate prefix>"]' \
  '[.[] | select(.cwd == $dir)
        | select((.name // "") as $n | any($ps[]; . as $p | $n | startswith($p)))]
   | sort_by(.startedAt)' "$agents"
```

End a prefix at a delimiter (`"widgets #26: "`, with the colon and space) so it
can't also match `#263`. If the listing itself fails (non-zero exit, output that
isn't JSON), **you don't know**, so don't spawn fresh on it: report the error
and let the caller decide.

**Drop your own row** (`sessionId` equal to `$CLAUDE_SESSION_ID`). When that
variable is unset and your own name could match the prefix (a coordinator
looking for an earlier coordinator of the same work), presume one running
match is you and drop it; if more than one running row matches, one of them is
another live session you can't tell apart from yourself, so stop and report
them rather than carry on. Then **decide by `status`**:

- **A match that is running** (`busy`, `blocked`, or another status saying it is
  working or waiting on input): the unit already has a live session. Resume
  nothing and don't launch a duplicate; report it, and message it via
  SendMessage if the caller needs it to change course.
- **Only `stopped` / `done` matches**: resume one (below), the newest
  (`startedAt`, last after the sort) when there are several, and name the
  others in the report.
- **Several units with one name** ("spawn 3 agents to each do X", retried):
  a row answers at most one unit. Pair units with matching rows one-to-one,
  newest first, applying the rules above per pair, and launch fresh only for
  the units left over.
- **A status you can't place** (anything else, e.g. a failure state): you can't
  tell whether it is running, so do nothing for that unit and report the row.
- **No match**: launch fresh (next section).

**Resume** from the row's `cwd`, the directory it was launched from, with a
short **re-briefing** prompt:

```bash
( cd "<row cwd>" && claude --bg --resume <sessionId> "<re-brief>" )
```

`--bg --resume` continues the session in the background **under the same
`sessionId`**, with its saved options (`--name`, `--model`), so its handle and
name stay what the caller recorded. The re-brief is not the original prompt,
which the session already holds: say that it was resumed, what changed while it
was down (a base branch that moved, a PR merged, a restack, a raised budget), and
to re-derive its state from the durable record (branch, PR, tracker) before
carrying on. Quote it the way *Launch* below says.

A session belongs to the directory it was launched from, so if that `cwd` no
longer exists, don't resume from somewhere else: launch fresh and say why in the
report. Do the same when the resume command errors. If its output says it
**started a copy** because the session is already running, the session was
live after all: stop the copy (`claude stop <the id it printed>`) and treat the
original as live.

## Launch

One Bash call per unit, **all in a single message** so they launch concurrently —
each wrapped in a subshell so the `cd` to the durable launch dir doesn't leak into
your session:

```bash
( cd "$launch_dir" && env -u CLAUDE_SESSION_ID claude --bg --name "<context> <desc>" "<prompt>" )
```

- `<desc>`: under 5 words, recognizable (e.g. `investigate flaky CI`). Spaces and
  special characters are fine — keep `--name`'s argument quoted.
- `<prompt>`: quote it so the shell can't mangle it. Plain prose in double quotes is
  fine (apostrophes are safe), but if the prompt contains `$`, backticks, or
  `$(...)`, double quotes will **expand** them and corrupt the spawned prompt. For
  those, feed the prompt through a single-quoted heredoc into a variable and pass
  the variable:
  ```bash
  read -r -d '' p <<'PROMPT'
  …prompt text, verbatim…
  PROMPT
  ( cd "$launch_dir" && env -u CLAUDE_SESSION_ID claude --bg --name "<context> <desc>" "$p" )
  ```
- `env -u CLAUDE_SESSION_ID` keeps the spawner's session identity out of the child.
  On CLIs older than Claude Code 2.1.132, the `ticket-workflow` plugin's
  SessionStart hook exports that variable to key its role markers, and a child
  launched from the Bash tool inherits every exported variable: a child whose own
  hook didn't run would key its marker to the spawner's session. Where the
  variable isn't set, the prefix does nothing.
- `claude --bg` prints a **session handle** at spawn — record it per unit; it
  survives the user renaming the session and is how you inspect a stuck one later.

## Report

Name column = the `--name` you passed (for a resumed unit, its existing name,
marked *resumed*). Point at the inspect commands: `claude agents` (list),
`claude attach "<name>"` (open), `claude logs "<name>"` (read-only). Quote
names — they contain spaces. Those are for the user's terminal; from a tool call,
list with `claude agents --json --all` (above).
