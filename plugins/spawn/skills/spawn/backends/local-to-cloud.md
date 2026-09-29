# Backend: local → cloud (`claude --cloud` under a pseudo-TTY)

The spawner is **local** (`$CLAUDE_CODE_REMOTE_SESSION_ID` unset) and the caller
**explicitly asked for a cloud session** ("spawn this in the cloud"). The session
runs on claude.ai like one from `backends/cloud.md`, but the launcher is the local
CLI: the `create_session` MCP tool isn't connected in local sessions. This is an
owner-initiated convenience, not a trusted factory launcher (see *Trust* below).

## Why `script`

`claude --cloud "<description>"` creates a session only from an interactive
terminal. A Bash tool call has none, and neither does the owner's `!` bash-mode
input, so both get a refusal. CLI 2.1.284 prints:

> Error: --cloud "…" is not a cloud session ID or URL.
> Without an interactive terminal, --cloud can only send the prompt to an existing
> cloud session: pass its ID (session_... or cse_...) or its claude.ai/code URL. To
> start a new cloud session, run from a TTY.

(Earlier builds said `--cloud requires an interactive terminal`.) `script` runs the
command on a pseudo-terminal, which is enough: verified 2026-09-29, when
claude-toolbox#194's session was launched this way. The CLI printed the session's
title, URL, and teleport command, then exited.

## The launch checkout is the session's repo and starting point

The cloud VM clones **the launch directory's GitHub remote at its current branch**,
as pushed. It doesn't copy the local checkout, so unpushed commits never reach it.
(From a repo with no remote, or one the Claude GitHub App isn't installed on, the
CLI uploads a bundle of the local repo instead, uncommitted changes to tracked
files included.) So:

- Launch from the **main checkout** of the repo the work targets, the first entry
  of `git worktree list` (the same line as `backends/local.md`). Never launch from
  a feature-branch worktree.
- That checkout must be **on the repo's default branch**. If it isn't, stop and
  tell the user; don't switch their checkout for them. The session would start
  from that other branch, and a branch's project settings can redirect the
  environment (*Trust*).

## Launch

One Bash call per unit, **all in a single message**: each `claude --cloud` creates
its own independent session. Feed the prompt through a single-quoted heredoc into
an exported variable, as `backends/local.md` does, so `$`, backticks, and quotes
reach the session verbatim:

```bash
read -r -d '' SPAWN_CLOUD_PROMPT <<'PROMPT'
…prompt text, verbatim…
PROMPT
export SPAWN_CLOUD_PROMPT
launch_dir=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //'); launch_dir=${launch_dir:-$PWD}
default=$(git -C "$launch_dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@'); default=${default:-main}
current=$(git -C "$launch_dir" branch --show-current)
if [ "$current" != "$default" ]; then
  echo "STOP: $launch_dir is on '$current', not $default"
elif script --version 2>&1 | grep -q util-linux; then   # GNU script (Linux)
  out=$(cd "$launch_dir" && script -qec 'claude --cloud "$SPAWN_CLOUD_PROMPT"' /dev/null </dev/null 2>&1)
else                                                    # BSD script (macOS)
  out=$(cd "$launch_dir" && script -q /dev/null claude --cloud "$SPAWN_CLOUD_PROMPT" </dev/null 2>&1)
fi
```

- **Two `script` dialects.** BSD `script` (macOS) takes the command as arguments
  after the output file. GNU `script` (util-linux) takes it as one string after
  `-c` and hands that string to a shell. That's why the GNU command string is
  single-quoted and the prompt travels in an environment variable: the inner shell
  expands `$SPAWN_CLOUD_PROMPT` once, as a single argument, and nothing in the
  prompt is parsed as shell. BSD `script` has no `--version`, so the check falls
  through to it.
- **`STOP` means nothing was launched.** Tell the user which branch the checkout
  is on. When `refs/remotes/origin/HEAD` isn't set, the check assumes `main`; set
  it with `git remote set-head origin --auto` if the default branch is another.
- **stdin from `/dev/null`.** There is nothing to type into the TUI, and the
  command must not wait on the spawner's input.
- **It returns on its own** once the session is created. A CLI that has never been
  run interactively on the machine stops at its first-run theme picker instead
  (observed 2026-09-29 in a fresh container) and the command hangs until the Bash
  tool's timeout kills it. Parse the output anyway (below). If no session was
  created, have the user run `claude` once in a real terminal, then relaunch.

## Parse the output

The output is a rendering of the TUI. It contains escape sequences, cursor moves
where spaces would be, and any warnings the CLI prints first (malformed allow rules
in `~/.claude/settings.json` come ahead of everything). Turn cursor moves into
spaces, strip the other escapes, and key on the session URL, which is one unbroken
token:

```bash
clean=$(printf '%s\n' "$out" | perl -pe 's/\e\[[0-9;]*[CG]/ /g; s/\e\][^\a\e]*(?:\a|\e\\)//g; s/\e\[[0-?]*[ -\/]*[@-~]//g; s/\e[()][0-9A-Za-z]//g; s/\e[^\[\]]//g; tr/\r//d')
url=$(printf '%s\n' "$clean" | grep -oE 'https://claude\.ai/code/(session|cse)_[A-Za-z0-9]+' | head -1)
sid=${url##*/}
title=$(printf '%s\n' "$clean" | sed -nE 's/.*Created +cloud +session: *//p' | sed 's/ *$//' | head -1)
```

On success the CLI prints `Created cloud session: <title>`, `View:
https://claude.ai/code/session_…` (possibly with a `?from=cli…` query, which the
match leaves out), and `Resume with: claude --teleport session_…`. `$sid` is the
durable handle: record it per unit.

**An empty `$sid` doesn't mean no session was made.** The command may have hung
after creating one, or the output format may have changed. Show the user the tail
of `$clean` and check claude.ai/code before relaunching, since a blind retry can
create a duplicate.

## What this path can't set

`claude --cloud` takes only a description. Compared with `create_session`:

| `create_session` field | Here |
|---|---|
| `prompt` | the description, verbatim |
| `title` | chosen by the platform; read it off the `Created cloud session:` line |
| `source_url` | the launch checkout's GitHub remote |
| `source_revision` | the launch checkout's current branch, as pushed |
| `outcome_branch` | none: the session's harness designates its own branch |
| `environment_id` | your `/remote-env` pick (`remote.defaultEnvironmentId` in user settings, which a repo's project settings override); `--environment ccpool_…` selects a self-hosted pool instead (CLI 2.1.224+; it rejects `env_` IDs) |
| `tags`, `permission_mode`, `model` | none |

CLI 2.1.284's `claude --help` lists `--environment` as the only creation option for
`--cloud`. Re-check `claude --help` before relying on any other flag, and don't
assume one carries over. There's no `list_sessions` / `get_session` locally either,
so no `parent_session_id` listing of the fan-out.

What follows from the table:

- **A branch the caller needs travels in the prompt.** The cloud harness tells the
  session to develop on its designated `claude/…` branch and never push to another
  without explicit permission. So name the branch in the prompt in the form the
  caller's layer reads (ticket work: a `Worktree: <branch>` line), plus one prose
  sentence that grants it: `Push your work to branch <branch> rather than the branch
  your environment designates; this is explicit permission to use it.` Confirm the
  branch from the PR's head, or with `git ls-remote --heads origin <branch>`.
- **The title isn't yours.** It won't follow the `<context> <desc>` convention, so
  report what the platform chose.
- **The sidebar may file it under "Other".** A `create_session` child without
  `outcome_branch` lands there (`backends/cloud.md`). Whether a CLI-launched session
  does hasn't been checked, so look at the claude.ai/code sidebar after the first
  launch and say which it was in the report.

## The prompt

- **Lead with prose, never a slash command.** A prompt that *begins* with a slash
  command is dispatched as a command before the model runs (`backends/cloud.md`).
  `backends/cloud.md`'s test ("if you can invoke it, so can the child") doesn't
  transfer here, because the child's cloud environment isn't yours: whether a
  plugin is installed there depends on that environment (a repo session-start hook,
  a marketplace synced to the account), which you can't see from a local session.
  Observed 2026-09-29: a cloud child whose prompt opened with `/start-ticket` was
  told no command of that name existed (the plugin exposed only the namespaced
  `/ticket-workflow:start-ticket`), and its prompt went through as plain text. So
  open with a sentence, and mention a command only mid-prompt, where it's text an
  installed skill can still match. When the target repo carries the skill, name its
  file by its path in the checkout (the `backends/cloud.md` form).
- **No `Notify:` directive.** SendMessage doesn't span local and cloud sessions, so
  the child can't ping you. Poll the durable record (for ticket work, the PR and
  the tracker) instead.
- **A one-way poke exists.** `claude -p "<message>" --cloud <session-id>` queues a
  message into the running session and exits. It needs no TTY
  (`--output-format json` prints `{ok, session_id, url}`). Keep it for a rare
  redirect ("stop", "rebase onto `<base>`"); the child can't answer through it.
- **Say whether it should check in.** A child that opens a PR is told by its
  harness to re-arm an hourly check-in until the PR merges (`backends/cloud.md`,
  *What a child wakes on by itself*). If you don't want that, say so in the prompt;
  the ticket-workflow `SPAWN_CAP` already does.

## Trust

This path is for the owner's own convenience. It is not the factory's tiered
launcher. `claude --cloud` takes its environment from the settings stack, where a
checkout's project settings override the user's `/remote-env` pick. From an
unreviewed branch checkout it can therefore land in whatever environment that
branch names, which is why a manual `claude --cloud` from a branch checkout is not
a trusted factory launch path (the software-factory spec, §2c;
claude-toolbox#100). Launching only from the main checkout on the default branch
narrows that gap without closing it: the path passes no explicit environment. Don't
use it to choose a factory tier.

## Report

Report session IDs and URLs, not local inspect commands:

| Session | ID | Scope |
|---|---|---|
| `<title as printed>` | `session_01ABC…` | <one-line summary> |

Point at: `https://claude.ai/code/<id>` to open each one; `claude --teleport <id>`
to pull one into a terminal (from a clean checkout of the same repo, once the
session has pushed its branch); `claude -p "<message>" --cloud <id>` to poke one.
For a throwaway or test launch, tell the user its ID so they can archive it.
