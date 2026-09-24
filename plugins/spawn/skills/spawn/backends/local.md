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

## Resuming a session after its cwd is gone

A different record from the bg job's recorded cwd above, so fixing one doesn't
fix the other. A session's transcript is filed under its launch cwd at
`~/.claude/projects/<slug>/<session-id>.jsonl`, where `<slug>` is the cwd's
**physical** path (symlinks resolved) with every non-alphanumeric character
(`/`, `.`, spaces, `~`) turned into `-`. What that means for a removed worktree,
verified on Claude Code 2.1.280 with headless `claude -p`:

- **`claude --resume <id>` finds the transcript by ID from any cwd**, even after
  the original cwd has been deleted. It appends to the original file in its
  original slug dir, and the resumed turns run in the **current** cwd.
- **`--fork-session`** writes the copy, under a new ID, into the current cwd's
  slug dir and leaves the original file untouched. Use it to try a recovery
  without mutating the original.
- **`claude --continue` is cwd-scoped**: it picks the most recent conversation
  *in the current directory*, so it can't reach a removed worktree's sessions.
  Resume those by ID.
- **`sessions-index.json` is dead weight.** A new session writes only the
  `.jsonl`, and the index files left in older project dirs were last written
  months earlier. Don't rely on one, and don't hand-edit one to make a session
  show up.

Older builds (as noted in July 2026) looked the ID up only in the current cwd's
slug dir, and a resume from the wrong cwd created an **empty transcript under
the same ID** there, which then shadowed later resumes from that cwd. That no
longer reproduces with `--resume <id>` on 2.1.280. Not re-verified here: the
interactive `--resume` picker and interactive `--resume <id>`. If either can't
find a session, recover it the old way: recreate the missing path
(`git worktree add --detach <path>`, after `git worktree prune` if the
directory was deleted without `git worktree remove`; or `mkdir -p <path>`) and
resume from there, or `cp -p` the `.jsonl` into a live cwd's slug dir. Locate
the file by ID rather than rebuilding its slug by hand:
`find ~/.claude/projects -name '<session-id>.jsonl'`. Test with
`--fork-session` first. A very large transcript may need a 1M-context model to
load.

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
