---
name: ledger
description: 'Use when instructions (a ticket-workflow charter or step, a briefing) or the owner ask this session to record a decision the owner made or something it needs from the owner, or when the owner asks "status?" or what needs them. Keeps the per-session ledger that the ledger mod and /ledger show across every local session.'
---

# Ledger: decisions made, and what a session needs from the owner

Each session keeps a **ledger**: the decisions the owner made in it, and what
it needs from the owner. The ledger plugin's mod shows every local session's
open needs at a glance (a band above the prompt, and the `/ledger-pane` pane),
and `/ledger` prints the same. So when the owner asks "status?", the answer
starts there instead of being rebuilt from GitHub and memory, and nothing the
owner has to do waits for them to ask.

A ledger is one file per session, written only by that session through
`scripts/ledger.sh`. An in-process subagent shares its parent's session, so a
hook denies its writes: as a subagent, report a decision or need in your final
answer and let the parent record it.

## When to record

Every entry starts with a **Why line**: `Why: <history and goal>`, one short
line (at most 200 bytes) on why the work the entry is about exists and what
it's for. Take it from the issue's motivation, or the epic or request it
serves: `Why: #208: "status?" answers are rebuilt from scratch each time, so
this keeps a durable list of decisions and needs`. The owner reads an entry
days later, among other sessions' needs, and a small in-the-weeds issue is
easy to forget the reason for. The script refuses an entry without one. The
entry's own text goes on the lines after it.

- **A decision**, whenever the owner decides something in this session: a scope
  change, a defer, a merge authorized, a design pick, a review-round cap raised,
  a follow-up declined. One line saying what was decided and why. The owner's
  decisions, not your own choices along the way.
- **A need**, whenever this session stops for something only the owner can
  give: a review or a merge, a design decision, a permission prompt, a credential
  to unlock (1Password), an answer to a question. Say what is needed and the
  **exact unblock step**, so the owner can act from the pane without opening
  the session: `review PR #212, then claude attach 5864ecfd and say finish`,
  `approve the Bash prompt in claude attach 5864ecfd`. Record each need once:
  check `list` before adding one that may already be open.
- **Not a child's need.** A need lives only in the ledger of the session that
  needs the owner. When a session you spawned pings that it needs the owner
  (`blocked: merge needs the owner`, a `declined: … needs the owner` line),
  that child records the need itself, and `list --all` and the mod read every
  local ledger, so it already reaches your "status?" answer. Don't copy it
  into yours: a copy would show the same need twice. What you stop for
  yourself, such as a whole stack that's ready for the owner, is yours to
  record.
- **Resolve a need** once the owner has answered: they replied, approved or
  merged. Resolve a need that no longer applies too (its PR closed, the plan
  changed). When a PR lands, `resolve --ref` resolves every open need under
  it, in every local ledger.

## When to read

When the owner asks "status?", "what's left?" or what needs them, run
`list --all` first: every session's open needs, newest first, then this
session's decisions, each under its Why line. Then verify what may have moved
since (PR state, `claude agents`), and lead the answer with what needs the
owner, each with its why.

## The commands

The text goes on stdin through a quoted heredoc, so quotes, backticks and `$`
stay literal. Quote a `--ref` that starts with `#`: unquoted, the shell reads it
as a comment.

```bash
bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" add-decision --ref '#208' <<'LEDGER_EOF'
Why: <history and goal: why this work exists>
<what the owner decided, and why>
LEDGER_EOF
bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" add-need --ref '#212' <<'LEDGER_EOF'
Why: <history and goal: why this work exists>
<what the owner needs to do, and the exact step>
LEDGER_EOF
bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" resolve n1
bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" resolve --ref '#212'
bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" list --all
```

- `add-decision` and `add-need` print the new entry's id (`d1`, `n1`); `--ref`
  is optional (an issue or PR: `#212`, `owner/repo#12`, `ABC-12`). A bare
  `#212` is written as `owner/repo#212`, from the checkout's origin remote, so
  every session in one repo records the same ref and two repos' `#12` don't
  collide. Outside a checkout of the ref's repo, a bare `#212` stays as it is,
  so there pass the full `owner/repo#212`. The first line must be the Why line, `Why:` and then at most 200
  bytes; it's stored as the entry's `why`, and the listings print it above the
  text. The text after it is at most 4000 bytes. Neither may hold a control
  character but tab and newline.
- `resolve <need id>` marks one of this session's needs resolved;
  `--session <session id or a unique prefix of 4+ characters>` resolves another
  session's, which is for the owner dismissing a need whose session is gone,
  never for a need that session can still answer itself.
- `resolve --ref <ref>` resolves every open need with that ref in every local
  ledger: the hand-back's, and any `blocked:` one. It's for a PR that landed
  (ticket-workflow's FINISH runs it), since the merge answers all of them. It
  prints one line per ledger it resolved; if any ledger couldn't be resolved,
  it says which on stderr and exits 1, and the ledgers it printed were still
  resolved.
- `list` prints this session's open needs, decisions and resolved needs;
  `list --all` prints every session's open needs and this session's decisions.
  Each need is its own row, even when two share a ref, and the pane's Resolve
  resolves the one pressed.
- A body line that is exactly `LEDGER_EOF` would end the heredoc early: use
  another delimiter, the same word in both places. Don't also pipe into the
  command: under zsh a pipe and a heredoc on one command both feed stdin.
- Your attach handle, for an unblock step:
  `claude agents --json --all | jq -r --arg s "$CLAUDE_CODE_SESSION_ID" '.[] | select(.sessionId == $s) | .id'`
  (nothing for an interactive session, which the owner is already in).

`CLAUDE_LEDGER_ROOT` is set by the plugin's SessionStart hook. When it is unset
(the plugin installed mid-session, hooks off) a command stops with
`parameter not set`; when it is stale (a mid-session update) it fails with
`No such file`. Then find the script with the Glob tool
(`cache/*/ledger/*/scripts/ledger.sh` under your Claude config's `plugins/`
directory, the highest version if several match) and run it by that path.

A ledger is keyed on the session id, so after `/clear` or a fork (which start
a new one) entries recorded earlier stay under the old id. `list --all` still
shows them, under the directory and the old short id, and `resolve --ref` or
`resolve --session <old id>` reaches them.

A ledger write that fails never blocks the work it describes: carry on, and
say in your next report what wasn't recorded and why.
