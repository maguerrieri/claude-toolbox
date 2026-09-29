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
the session, prints its ID, and exits. Verified 2026-09-29 on macOS, four
times, from this repo. The third is the worked example below. The fourth
reran the final revision of these steps, launching from a throwaway
worktree.

- **macOS (BSD `script`):** `script -q /dev/null claude …`, with the command as
  argv. It exits with the child's status: the probe that hit `--cloud requires
  a description` returned `exit=1`.
- **Linux (util-linux `script`):** `script -qec '<command string>' /dev/null`.
  The command is a single string run by a shell, so pass the prompt and name
  in environment variables and reference them inside single quotes (below),
  not by splicing them into the string. `-e` makes `script` return the child's
  exit status; without it, util-linux reports 0 whatever `claude` returned.
  **Unverified**: no Linux host was available when this path was written.
  Check the first Linux run against the output below.
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
  not prompt. For the current repo, its **main checkout** (the first entry of
  `git worktree list`) is the natural choice. For work in another repo, use a
  trusted checkout of *that* repo. There's no field to point elsewhere.
- **A throwaway worktree when the main checkout won't do.** If the preflight
  (below) finds the main checkout dirty, behind origin, or on the wrong
  branch, don't pull, stash, or switch branches in it; that checkout is the
  user's. Cut a launch worktree under its `.claude/worktrees/` instead, which
  inherits its trust: `git worktree add <main>/.claude/worktrees/launch-<nonce>
  -b launch-<nonce> origin/<base>`. That is an unpushed branch at a commit
  origin has, the combination the worked example launched from. Remove it
  (`git worktree remove`, `git branch -D`) once the launch has printed its
  URL. The session never needs the directory again.
- **Its current branch is the session's starting point.** Per the docs, the VM
  clones the remote "at your current branch", so push first. When that branch
  isn't on GitHub, the CLI says so and starts from the checkout's commit
  instead, provided origin has it. Verified: `Branch <b> is not on GitHub, so
  the cloud session starts from its own commit, which origin/main has
  (<sha>).` It is only a starting point. The session doesn't work *on* that
  branch (next bullet).
- **The session names its own branch.** Every probe started on a fresh
  `claude/<slug>-<random>` branch (`claude/noop-probe-7dnwk4`,
  `claude/probe-195-b-81ykxe`, `claude/probe-c-issue-195-qi1qjh`,
  `claude/toolbox-195-probe-d-51rbh1`), whether the
  launch branch was on GitHub or not. There is no flag to choose it. The
  sessions could still **push a second, differently named branch**, despite
  the proxy's documented "push works only against the session's current
  working branch". The third probe did this the way ticket-workflow START Step
  3 path (a) does: `git worktree add .claude/worktrees/<b> -b <b> origin/main`,
  `EnterWorktree` into it (the tool exists in the cloud session), commit, then
  `git push -u origin <b>`. That is what lets a ticket child push its assigned
  `Worktree:` branch (the ticket-workflow skill's SPAWN Step 3).

## Launch

Shell variables don't survive from one Bash call to the next, so every call
below starts by setting the two paths it needs: `<out>`, the directory step 1
creates and prints, and `<launch_dir>`, the checkout chosen above. Write each
as a **single-quoted literal**, `out='/path/…'` (a `'` inside a path becomes
`'\''`), and let the rest of the call use `"$out"` and `"$launch_dir"`. A path
spliced raw into double-quoted shell text would expand any `$(…)`, backtick,
or `"` in it, the same hazard the prompt and name files avoid.

**1. Set up (one call, then files).** Create `<out>`:

```bash
mktemp -d "${CLAUDE_JOB_DIR:-${TMPDIR:-/tmp}}/spawn-cloud.XXXXXX"
```

Then write each unit's prompt to `<out>/prompt-<n>.txt` and its session name
(`<context> <desc>`) to `<out>/name-<n>.txt` **with your file-writing tool,
not the shell**. **Make every name unique.** Timeout recovery (under *Parse
the result*) finds a unit by its name, both in the local process list and in
the session picker. So when two units of a fan-out share a `<desc>` ("N
agents to each do X"), suffix an ordinal (`toolbox fix CI 1`,
`toolbox fix CI 2`). A name must also differ from any other `--cloud` launch
running on this machine. Both can carry caller or issue text, and neither should pass
through shell parsing: a `$(…)`, a backtick, or a quote in a name spliced into
a command runs or breaks it. A heredoc is only a fallback, when no such tool
exists. Give it a single-quoted delimiter you've checked doesn't occur as a
line of the text (e.g. `PROMPT_<random hex>`), because a line equal to a fixed
delimiter like `PROMPT` ends the heredoc early and the shell runs the rest.

Start the prompt with a word, not `-`: the prompt is the value of `--cloud`,
and a leading dash would be parsed as a flag.

Then preflight `<launch_dir>`. For the current repo it's the main checkout
(`git worktree list --porcelain | head -1 | sed 's/^worktree //'`); for
another repo, a trusted checkout of that one. Stop if any warning prints,
rather than launch. The last line names the starting branch, to check against
what the unit needs:

```bash
launch_dir='<launch_dir>'
git -C "$launch_dir" fetch -q --prune origin || echo "fetch failed: can't confirm origin has HEAD"
[ -z "$(git -C "$launch_dir" status --porcelain --untracked-files=no)" ] || echo "tracked changes: a bundle upload would carry them"
b=$(git -C "$launch_dir" branch --show-current)
if [ -n "$b" ] && git -C "$launch_dir" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null; then
  [ "$(git -C "$launch_dir" rev-parse HEAD)" = "$(git -C "$launch_dir" rev-parse "refs/remotes/origin/$b")" ] || echo "HEAD differs from origin/${b}: the session would start from origin's tip; push it, or launch from a throwaway worktree"
else
  [ -n "$(git -C "$launch_dir" branch -r --list 'origin/*' --contains HEAD)" ] || echo "HEAD isn't on origin: push it first"
fi
echo "starting branch: ${b:-detached HEAD}"   # the session's starting point; is it the one you want?
```

The two cases match the two ways the CLI picks a start. When the branch is on
GitHub, the clone takes **origin's tip**, so HEAD must equal it; a local branch
ahead of or behind origin would hand the child a different revision than the
one checked. When it isn't, the CLI falls back to HEAD's commit, so origin
only has to contain it. The `--prune` and the `origin/*` scope keep a stale
ref to a deleted branch, or the commit on another remote, from passing a
check the clone can't honor. Both cases were checked on 2026-09-29: an in-sync
branch passes, and a branch whose origin ref points elsewhere warns.

**2. Launch (one call per unit, all in a single message).** Each call is
bounded by `perl`'s `alarm`, so a trust dialog or a stalled provision can't
hang the spawner. `alarm` survives `exec`, and perl ships with macOS and most
Linux distributions. util-linux `script -c` runs its string through `$SHELL`,
so the Linux branch pins that to `/bin/sh` for POSIX quoting:

```bash
out='<out>'; launch_dir='<launch_dir>'
( cd "$launch_dir" && p=$(cat "$out/prompt-<n>.txt") && name=$(cat "$out/name-<n>.txt") &&
  if script --version 2>/dev/null | grep -q util-linux; then
    P="$p" N="$name" SHELL=/bin/sh perl -e 'alarm 180; exec @ARGV' script -qec 'claude --name "$N" --cloud "$P"' /dev/null
  else
    perl -e 'alarm 180; exec @ARGV' script -q /dev/null claude --name "$name" --cloud "$p"
  fi </dev/null >"$out/launch-<n>.out" 2>&1; echo "exit=$?" )
```

- **`--cloud` consumes the next argument as its value**, so the description
  goes right after it. `claude --cloud --name "<x>" "<prompt>"` hands `--cloud`
  no description and fails with `Error: --cloud requires a description.` Other
  flags can go before it, as here, or after its value, as in the follow-up
  command under *Report*.
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
out='<out>'; f="$out/launch-<n>.out"
url=$(grep -aEo 'View: https://claude\.ai/code/(session|cse)_[A-Za-z0-9]+' "$f" | tail -1); id=${url##*/}
[ -n "$id" ] && echo "launched $id" ||
  perl -pe 's/\e\[\d*[CG]/ /g; s/\e\[[0-9;?<>=]*[ -\/]*[@-~]//g; s/\e\][^\a\e]*(\a|\e\\)//g; s/\e[()][A-Za-z0-9]//g; s/\e[78=>]//g; s/\r/\n/g' "$f" |
  grep -av '^[[:space:]]*$' | tail -20
```

The `View:` line survives the escape sequences intact (checked on all three
probe outputs), so the grep needs no cleanup. It anchors on `View: ` and takes
the **last** match because the `Created cloud session: <title>` line comes
first, and a title built from caller or issue text could itself contain a
session URL. The perl
filter makes the rest readable; the TUI draws spaces as cursor moves
(`\e[<n>G`), which is why it turns those into spaces rather than deleting them.

With no URL, classify by the **readable tail, not the exit status**. The
status isn't a reliable signal: a fired `alarm` shows up as `exit=142` under
BSD `script`, but util-linux can report something else (134 was reported for
this wrapper). Only these tails mean the CLI stopped before creating
anything. Fix the cause and relaunch that unit:

- the TTY refusal;
- `requires a description` (the prompt isn't right after `--cloud`);
- a policy or auth error from the platform docs' table;
- the `is not on GitHub` notice with no commit to fall back on;
- the trust dialog (launch from a trusted checkout instead).

**Any other no-URL result is ambiguous.** That covers a stalled provision
killed by the `alarm`, a signal, or a tail you don't recognize. The platform
may have created the session before the CLI printed its URL, so look before
relaunching. Don't retry blind, since each successful launch is a new session.
First make sure the timed-out `claude` is gone. The `alarm` signals `script`,
and `claude` exits on the hangup that follows when the pty closes: no
`claude` process survived either timeout observed here. But a survivor could
still create the session after you've decided. Look for **this unit's**
process only. Other units of the same fan-out may still be launching, and a
broad `pgrep 'claude .*--cloud'` would match them too. The unit's name is
unique (step 1), so its exact `--name <name> --cloud` argv identifies it.
Match that as a fixed string, and kill only the PIDs it prints:

```bash
out='<out>'; ( S="claude --name $(cat "$out/name-<n>.txt") --cloud"; export S
  ps -ax -o pid=,command= | awk 'index($0, ENVIRON["S"]) { print $1 }' )
```

`index` does a plain substring match, so regex characters in a name are
harmless. The pattern reaches awk through the environment, so neither the
awk nor the ps command line contains it. Tested 2026-09-29 against two
stand-in launches, one named `toolbox #42: fix [x] (y)`: only that unit's
PID printed.
The `claude --teleport` picker lists the repo's sessions by title, and it also
needs a TTY. Capture it with the same `script` dispatch as the launch, and let
a short `alarm` kill it before anything is selected:

```bash
out='<out>'; launch_dir='<launch_dir>'
( cd "$launch_dir" &&
  if script --version 2>/dev/null | grep -q util-linux; then
    SHELL=/bin/sh perl -e 'alarm 25; exec @ARGV' script -qec 'claude --teleport' /dev/null
  else
    perl -e 'alarm 25; exec @ARGV' script -q /dev/null claude --teleport
  fi </dev/null >"$out/picker.out" 2>&1 )
```

Read `<out>/picker.out` through the perl filter above. On macOS this listed
both probe sessions by title without selecting one; the util-linux branch is
unverified, like the launch's. You can also check claude.ai/code.

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
- **Don't brief it to fan out.** A session started this way has none of the
  session-management tools. Probe D (`session_01T7PVazzGELNx7GSpgH433h`,
  2026-09-29) looked for `create_session`, `list_sessions`, `get_session` and
  `send_later`, through ToolSearch too, and found none. So it can't spawn
  cloud siblings or re-wake itself. That rules it out as an epic
  orchestrator, and out of any task that `/spawn`s in the cloud. Leaf work
  (one ticket, one investigation) is what this path carries.
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
out='<out>'; claude -p --cloud <id> --output-format json <"$out/followup.txt"
```

That posts the message and exits with `{ok, session_id, url}`. It needs no
TTY: with `-p` and a session ID, `--cloud` posts to that existing session.
Verified 2026-09-29: the probe session received and acted on a follow-up
sent this way. `get_session` / `list_sessions` aren't available locally, so
a caller polling for completion reads the PR, tracker, or branch on origin,
as `backends/cloud.md` does for its children.

## Worked example

The third probe, run on 2026-09-29 with the steps above copied verbatim
under zsh, placeholders filled. It ran an earlier revision, which wrote the
prompt with a `'PROMPT'` heredoc and set the name inline. Review then moved
both into files and tightened the preflight. The fourth probe (probe D) ran
the final snippets, extracted straight from this file with only the
placeholders filled and the SSH `fetch` line dropped. It launched from a
throwaway worktree and printed `launched session_01T7PVazzGELNx7GSpgH433h`.

1. `mktemp -d …` printed `<out>` = `…/spawn-cloud.Z2n42H`. `<out>/prompt-1.txt`
   started `Probe C for claude-toolbox issue #195, …` and asked for a worktree
   on an assigned branch and a push of it.
2. `<launch_dir>` was a clean worktree of this repo on an unpushed branch at
   `origin/main`'s tip. The preflight printed only that branch name.
3. The launch, with the name `claude-toolbox 195 probe C`, printed `exit=0`.
   `<out>/launch-1.out` held:
   ```
   Created cloud session: claude-toolbox 195 probe C
   View: https://claude.ai/code/session_018onHVVrLtgfqAb1m3gnWfb?from=cli&m=0
   Resume with: claude --teleport session_018onHVVrLtgfqAb1m3gnWfb
   ```
4. The parse printed `launched session_018onHVVrLtgfqAb1m3gnWfb`. The report
   row was `claude-toolbox 195 probe C` | `session_018onHVVrLtgfqAb1m3gnWfb` |
   probe. The session's pushed commit (`probe-195-c: enterworktree=used;
   cwd=/home/user/claude-toolbox/.claude/worktrees/probe-195-c;
   starting-branch=claude/probe-c-issue-195-qi1qjh`) came back as the only
   record, read with `gh api …/commits?sha=probe-195-c`.

## Trust boundary

This is an **owner-initiated convenience**, not the software factory's tiered
launcher (#100). The environment comes from `remote.defaultEnvironmentId` through
the settings stack of the launch checkout, and a branch's project settings can
change it (the software-factory spec's section 2c). So a `claude --cloud` from
a branch checkout isn't a trusted factory launch path. Use it when a human
asked for a cloud session, and don't pass an environment chosen from briefing
text.
