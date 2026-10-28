# Backend: local (`claude --bg`)

The spawner is running on a machine the user has a shell on. Sessions are
background jobs of the local CLI, recorded under the running macOS user's own
`~/.claude/jobs/`, and the user inspects them with `claude agents`,
`claude attach`, and `claude logs`, as that same macOS user (*Report*).

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

A background session whose process is gone (a machine restart, `claude stop`, a
crash, or a finished session that exited) still exists and can be continued
**with its context**. A
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
`name`, `sessionId`, `state`, `cwd` (the recorded launch dir), `kind`,
`startedAt` (epoch milliseconds), and `id` (the job's short id; resume takes
`sessionId`), and a row whose process is alive adds `pid` and `status`. Both
are verified on Claude Code 2.1.312, where every row with a `pid` was a live
process and no row without one was. **The lifecycle is `state`, not
`status`**: `state` is `working`, `blocked`, `done` or `stopped`, while
`status` (`busy`, `idle`, `waiting`) only says what a live session is doing
right now. A `stopped` row never has a `pid` or a `status`; a `done` row has
them while the session sits idle after its turn, and a `blocked` row loses
them when its process dies at a prompt (a restart, say). **List once per run**
and match every unit against that one listing, rather than re-listing per unit:
the list grows with every session ever run, across every project this macOS
user has run on the machine.

**The listing is per macOS user.** It reads the running user's own
`~/.claude/jobs/`, and `ListAgents` and SendMessage reach only that user's
sessions too. A session another user launched never appears, so it can't be
found, resumed or messaged from here: the spawner and every session it resumes
are always the same user.

**Match on the launch dir as well as the name.** The listing covers every
session this macOS user has run on this machine, and a name alone can collide: two clones, or two repos with the same basename
under different owners, produce the same `<repo> <ID>: …` names. Every unit is
launched from the durable launch dir (above), so keep only rows whose `cwd` is
exactly that dir (`claude agents --cwd` matches everything *under* a path, which
is too loose). If you recorded a unit's handle at spawn, match that `sessionId`
instead: it survives the user renaming the session, which a name match misses.
Otherwise match by name, exactly or by prefix when only part of the name is
deterministic; `$ps` takes several prefixes for one unit when its name has more
than one spelling (a caller's ID with and without a `#`):

`$launch_dir` is the durable launch dir from the section above: **resolve it
before the lookup**, since an empty value matches no row and reads as "none".

```bash
agents=$(mktemp) && claude agents --json --all > "$agents"   # once; stop here if it fails
jq --arg dir "$launch_dir" --argjson ps '["<prefix>", "<alternate prefix>"]' \
  '[.[] | select(.cwd == $dir)
        | select((.name // "") as $n | any($ps[]; . as $p | $n | startswith($p)))
        | .class = (if .pid != null then "running"
                    elif IN(.state; "working", "blocked", "done", "stopped") then "resumable"
                    else "unplaced" end)]
   | sort_by(.startedAt)' "$agents"
```

The filter tags each match with a `class`. `running`: the row has a `pid`, so
its process is alive, whatever its `state` (`working`, `blocked` on input or a
permission, or `done` and idle after its turn). `resumable`: no process, and
one of those four `state`s (a `working` or `blocked` row whose process died
mid-turn or at a prompt, a `done` session that exited, or a `stopped` one).
`unplaced`: no process and any other `state`, or none. End a prefix at a
delimiter (`"widgets #26: "`, with the colon and space) so it can't also match
`#263`. If the listing itself fails (non-zero exit, output that isn't JSON),
**you don't know**, so don't spawn fresh on it: report the error and let the
caller decide.

**Drop your own row**, by two checks, both always applied:

- its `sessionId` is the harness's `$CLAUDE_CODE_SESSION_ID` (Claude Code
  2.1.132+ gives every Bash call its own session's id). Never key on the older
  `CLAUDE_SESSION_ID` here: it is an ordinary exported variable, so a child can
  inherit its parent's, and matching it would drop the parent's row and keep
  yours;
- for a `running` row (only a live row has a `pid`; you are running, so your
  row has one), its `pid` is an ancestor of your shell (a Bash tool call runs
  under its session's process), which covers a CLI too old to set
  `CLAUDE_CODE_SESSION_ID`:

```bash
ancestors=" "; p=$$; while [ "${p:-1}" -gt 1 ]; do ancestors="$ancestors$p "; p=$(ps -o ppid= -p "$p" | tr -d ' '); done
# drop a row whose sessionId is this session's id (the first check), or a running row when case "$ancestors" in *" <row pid> "*) matches
```

If neither identifies your row and your own name could match the prefix (a
coordinator looking for an earlier coordinator of the same work), you can't
tell yourself from a live duplicate: stop and report the running matches rather
than carry on. Then **decide by `class`**, never by `status`:

- **A `running` match**: the unit already has a live session, even one that
  is `done` and idle. Resume nothing and don't launch a duplicate; report it,
  and message it via SendMessage if the caller needs it to change course.
- **Only `resumable` matches**: resume one (below), the newest (`startedAt`,
  last after the sort) when there are several, and name the others in the
  report.
- **Several units with one name** ("spawn 3 agents to each do X", retried):
  a row answers at most one unit. Pair units with matching rows one-to-one,
  newest first, applying the rules above per pair, and launch fresh only for
  the units left over.
- **An `unplaced` match**, alone or next to `resumable` ones (a `state` this
  list doesn't name, e.g. a failure state, or a row with none): you can't tell
  whether it is running, so do nothing for that unit and report its rows.
- **No match**: launch fresh (next section).

**Resume** from the row's `cwd`, the directory it was launched from, with a
short **re-briefing** prompt:

```bash
( cd "<row cwd>" && env -u CLAUDE_SESSION_ID claude --bg --resume <sessionId> "<re-brief>" )
```

`--bg --resume` continues the session in the background **under the same
`sessionId`**, with its saved options (`--name`, `--model`), so its handle and
name stay what the caller recorded. The re-brief is not the original prompt,
which the session already holds: say that it was resumed, what changed while it
was down (a base branch that moved, a PR merged, a restack, a raised budget), and
to re-derive its state from the durable record (branch, PR, tracker) before
carrying on. Quote it, and strip `CLAUDE_SESSION_ID`, the way *Launch* below says.

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
- **An untrusted launch dir is refused: don't launch from somewhere else.** A
  directory this macOS user has never trusted, such as a fresh clone, makes
  `claude --bg` exit 1 without launching anything, printing *Workspace not
  trusted. Run `claude` in <dir> once and accept the trust prompt, then retry.*
  (Claude Code 2.1.312). A session can't accept the trust prompt itself, and a
  retry from another directory breaks the durable launch dir rule above. So leave
  each unit refused this way unlaunched, and in the report give the user the
  one-time step, run as the user the spawner runs as (`id -un`), since trust is
  recorded per user:
  ```bash
  cd "<launch dir>" && claude   # accept the trust prompt, then /exit
  ```
  Then they re-run the spawn.

## Report

Name column = the `--name` you passed (for a resumed unit, its existing name,
marked *resumed*; for one the trust refusal left unlaunched, marked *not
launched*, with the one-time step from *Launch* under the table). Point at the inspect commands, and name the macOS user to run
them as and the directory to run them from: *as `<user>`, from `<launch dir>`:
`claude agents` (list), `claude attach "<name>"` (open), `claude logs "<name>"`
(read-only)*. `<user>` is `id -un` in the spawner's shell, and `<launch dir>` is
the durable launch dir every unit was launched or resumed from. Both matter
because the sessions are that user's alone (*Find and resume*), and because
`claude attach` asks to trust its own cwd first, which the launch dir already
is. A reader who is another user runs `sudo -iu <user>`, then `cd "<launch dir>"`.
Quote names — they contain spaces. Those are for the user's terminal; from a
tool call, list with `claude agents --json --all` (above).
