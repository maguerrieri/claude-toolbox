# Backend: local → cloud (`claude --cloud` under a pseudo-TTY)

The spawner is a **local** session, and the caller explicitly asked for the work
to run **in the cloud** ("spawn it in the cloud", "as a cloud session", "on the
web"). Siblings are cloud sessions, the same kind `backends/cloud.md` creates,
but a local session has no `create_session` tool (the session-management MCP
server isn't connected locally), so the launch goes through the CLI instead:
`claude --cloud "<description>"` creates a cloud session for the current
checkout's repository and returns.

This is its own backend rather than a section of `backends/cloud.md` because
almost every mechanic differs: the launch is a shell command, the launch
checkout decides the repo and the starting revision, the result is parsed
from terminal output, and the inspect and redirect paths are CLI commands.
`cloud.md` describes a spawner that is itself a cloud session, and none of
its `create_session` fields exist on this path.

## `--cloud` needs a TTY, so wrap it in `script`

Run without an interactive terminal (a Bash tool call, or the user's `!` input),
`claude --cloud "<description>"` refuses to create a session. Claude Code 2.1.283
prints:

```
Error: --cloud "<description>" is not a cloud session ID or URL.
Without an interactive terminal, --cloud can only send the prompt to an existing
cloud session: pass its ID (session_... or cse_...) or its claude.ai/code URL.
To start a new cloud session, run from a TTY.
```

(earlier builds said `--cloud requires an interactive terminal`). `-p` doesn't help:
with `--print`, `--cloud` also only posts to an existing session. Running it
under a pseudo-TTY works: `script` gives `claude` a terminal, `claude` creates
the session, prints its ID, and exits. Verified 2026-09-29 on macOS, twice, from
this repo.

- **macOS (BSD `script`):** `script -q /dev/null claude …`, with the command as
  argv.
- **Linux (util-linux `script`):** `script -qc '<command string>' /dev/null`. The
  command is a single string run by a shell, so pass the prompt and name in
  environment variables and reference them inside single quotes (below), not
  by splicing them into the string. **Unverified**: no Linux host was available
  when this path was written. Check the first Linux run against the output
  below.
- **Detect which one you have:** `script --version` prints `script from
  util-linux …` on Linux and fails with `illegal option` on BSD.

## Choose the launch checkout

`--cloud` takes its repository and starting point from the directory it runs
in, so pick it deliberately. Unlike `backends/local.md`, durability doesn't
matter here, because the session lives on the server and `claude --teleport`
works from any checkout of the repo. What does matter:

- **The target repo, with a GitHub remote.** The cloud session clones the
  checkout's GitHub remote, not the local files. A checkout with no remote, or
  a github.com repo the Claude GitHub App isn't installed on, is uploaded as a
  **bundle** instead: full history plus uncommitted changes to tracked files
  (the platform docs, *Send local repositories without GitHub*). So launch
  from a clean checkout. In-progress edits would otherwise travel to the
  cloud.
- **A folder Claude Code already trusts.** In an untrusted directory `claude`
  stops at the *Quick safety check: Is this a project you created or one you
  trust?* dialog, and with stdin at `/dev/null` it waits there until killed.
  Observed 2026-09-29 from a fresh clone under a temp dir. Trust is
  inherited: a worktree under a trusted checkout's `.claude/worktrees/` did
  not prompt. The repo's **main checkout** (the first entry of `git worktree
  list`) is the natural choice.
- **Its current branch is the session's starting point.** Per the docs, the VM
  clones the remote "at your current branch", so push first. When that branch
  isn't on GitHub, the CLI says so and starts from the checkout's commit
  instead, provided origin has it. Verified: `Branch <b> is not on GitHub, so
  the cloud session starts from its own commit, which origin/main has
  (<sha>).` It is only a starting point. The session doesn't work *on* that
  branch (next bullet).
- **The session names its own branch.** Both probes worked on a fresh
  `claude/<slug>-<random>` branch (`claude/noop-probe-7dnwk4`,
  `claude/probe-195-b-81ykxe`), whether the launch branch was on GitHub or not.
  There is no flag to choose it. Both could still **push a second, differently
  named branch**, despite the proxy's documented "push works only against the
  session's current working branch". That is what lets a ticket child push its
  assigned `Worktree:` branch (the ticket-workflow skill's SPAWN Step 3).

## Launch

Write the prompt to a file with a single-quoted heredoc, so the shell never
touches `$`, backticks, or quotes in it (the hazard `backends/local.md`
describes). Then launch one unit per Bash call, all in a single message.
Each call is bounded by `perl`'s `alarm`, so a trust dialog or a stalled
provision can't hang the spawner. `alarm` survives `exec`, and perl ships with
macOS and most Linux distributions.

```bash
out_dir=${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}; out_dir=${out_dir:-$(mktemp -d)}
cat >"$out_dir/prompt-<n>.txt" <<'PROMPT'
…prompt text, verbatim…
PROMPT
launch_dir=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //'); launch_dir=${launch_dir:-$PWD}
( cd "$launch_dir" && p=$(cat "$out_dir/prompt-<n>.txt") && name="<context> <desc>" &&
  if script --version 2>/dev/null | grep -q util-linux; then
    P="$p" N="$name" perl -e 'alarm 180; exec @ARGV' script -qc 'claude --name "$N" --cloud "$P"' /dev/null
  else
    perl -e 'alarm 180; exec @ARGV' script -q /dev/null claude --name "$name" --cloud "$p"
  fi </dev/null >"$out_dir/launch-<n>.out" 2>&1 )
```

- **`--cloud` takes the description as its own value**, so every other flag goes
  *before* it. `claude --cloud --name "<x>" "<prompt>"` fails with `Error: --cloud
  requires a description.`
- **`--name` sets the session's title** (verified: `Created cloud session:
  <name>`, and the same title in the `claude --teleport` picker), so the
  `<context> <desc>` convention holds.
- **stdin from `/dev/null`**: the CLI queues anything typed during provisioning
  as a message to the session. An empty stdin sends nothing, and the process
  exits once the session exists. BSD `script` echoes that EOF as a harmless
  `^D` at the top of the output.
- **What the CLI takes and what it doesn't.** Compared with `create_session`,
  only a description, the checkout, and a few session flags are available:
  - no `source_url`: the repo is the launch checkout's;
  - no `source_revision`: the start is its current branch or commit;
  - no `outcome_branch`: the session names its own `claude/…` branch, so a
    branch the caller needs to know travels in the prompt (for ticket work, a
    `Worktree:` directive);
  - no `tags`;
  - no `environment_id`: the environment is the `remote.defaultEnvironmentId`
    setting, which `/remote-env` writes to user settings and a repo's project
    settings can override. `--environment ccpool_…` picks a
    *self-hosted* pool and rejects Anthropic-hosted `env_…` IDs.

  `--name` is the only other flag verified alongside `--cloud`. Check the
  current `claude --help` before relying on another one.
- **Repo attribution.** Without `outcome_branch`, `backends/cloud.md` found that
  `create_session` children land under "Other" in the claude.ai/code sidebar.
  Sessions launched this way did show up in `claude --teleport`'s picker, which
  is scoped to the repo (its header names `maguerrieri/claude-toolbox`), so
  the platform resolved their repo. Confirm the sidebar placement on the first
  launch in a new repo.

## Parse the result

The output is TUI text, wrapped in escape sequences and preceded by any
settings warnings (for example, malformed permission allow rules in
`~/.claude/settings.json`). Grep for the lines, never parse by position:

```
Created cloud session: <title>
View: https://claude.ai/code/session_01…?from=cli&m=0
Resume with: claude --teleport session_01…
```

```bash
f="$out_dir/launch-<n>.out"
url=$(grep -Eo 'https://claude\.ai/code/session_[A-Za-z0-9]+' "$f" | head -1); id=${url##*/}
[ -n "$id" ] && echo "launched $id" ||
  perl -pe 's/\e\[\d*[CG]/ /g; s/\e\[[0-9;?<>=]*[ -\/]*[@-~]//g; s/\e\][^\a\e]*(\a|\e\\)//g; s/\e[()][A-Za-z0-9]//g; s/\e[78=>]//g; s/\r/\n/g' "$f" |
  grep -v '^\s*$' | tail -20
```

The URL survives the escape sequences, so the grep needs no cleanup. The perl
filter makes the rest readable; the TUI draws spaces as cursor moves
(`\e[<n>G`), which is why it turns those into spaces rather than deleting them.

No URL means no session. The readable tail says why: the TTY refusal, a trust
dialog (the `alarm` killed it; exit 142), `requires a description` (flag
order), a policy or auth error from the platform docs' table, or the `is not
on GitHub` notice with no commit to fall back on. Fix it and relaunch that
unit. Don't retry blind, since each successful launch is a new session.

Record the `session_…` id per unit. It is the durable handle.

## Prompt contents

- **Don't lead with a slash command.** A prompt that *begins* with one is
  dispatched before the model runs, and an environment without the command
  rejects the whole launch with "Unknown command" (`backends/cloud.md` has the
  evidence). On this path the local test doesn't carry over: `cloud.md`'s
  child inherits its spawner's environment, but here the spawner is local and
  the session runs in a cloud environment whose plugins you can't see from
  here. So lead with prose that names the skill (and its file, when the target
  checkout carries it), and put the rest of the briefing after it. A slash
  command mid-prompt is only text.
- **No `Notify:` directive.** A cloud session can't message a local one. The
  probes' sessions weren't in this session's `ListAgents` either. The child's
  PR, tracker, and branch are the record you read back.
- **Say whether it may arm PR check-ins.** A child that opens a PR follows the
  cloud harness's PR-driving rules, including a recurring self check-in,
  unless its prompt says otherwise (`backends/cloud.md`, *What a child wakes on
  by itself*).

## Report

Same table as `backends/cloud.md`, with the session ID column:

| Session | ID | Scope |
|---|---|---|
| `toolbox investigate flaky CI` | `session_01ABC…` | <one-line summary> |

Point at: the `View:` URL (the session's page on claude.ai/code); `claude
--teleport <id>` to pull it into a terminal later (from a checkout of the same
repo, once its branch is pushed); and, for a one-way follow-up or redirect,

```bash
claude -p --cloud <id> --output-format json <"$out_dir/followup.txt"
```

That posts the message and exits with `{ok, session_id, url}`. It needs no
TTY: with `-p` and a session ID, `--cloud` posts to that existing session.
Verified 2026-09-29: the probe session received and acted on a follow-up
sent this way. `get_session` / `list_sessions` aren't available locally, so
a caller polling for completion reads the PR, tracker, or branch on origin,
as `backends/cloud.md` does for its children.

## Trust boundary

This is an **owner-initiated convenience**, not the software factory's tiered
launcher (#100). The environment comes from `remote.defaultEnvironmentId` through
the settings stack of the launch checkout, and a branch's project settings can
change it (the software-factory spec's section 2c). So a `claude --cloud` from
a branch checkout isn't a trusted factory launch path. Use it when a human
asked for a cloud session, and don't pass an environment chosen from briefing
text.
