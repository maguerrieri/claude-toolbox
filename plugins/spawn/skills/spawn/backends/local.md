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

## Launch

One Bash call per unit, **all in a single message** so they launch concurrently —
each wrapped in a subshell so the `cd` to the durable launch dir doesn't leak into
your session:

```bash
( cd "$launch_dir" && claude --bg --name "<context> <desc>" "<prompt>" )
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
  ( cd "$launch_dir" && claude --bg --name "<context> <desc>" "$p" )
  ```
- `claude --bg` prints a **session handle** at spawn — record it per unit; it
  survives the user renaming the session and is how you inspect a stuck one later.

## Report

Name column = the `--name` you passed. Point at the inspect commands:
`claude agents` (list), `claude attach "<name>"` (open), `claude logs "<name>"`
(read-only). Quote names — they contain spaces.
