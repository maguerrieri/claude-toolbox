---
name: ledger
description: 'Use when instructions (a ticket-workflow charter or step, a briefing) or the owner ask this session to record a decision the owner made or something it needs from the owner, or when the owner asks "status?" or what this session needs from them. Keeps the per-session ledger that /ledger shows.'
---

# Ledger: decisions made, and what a session needs from the owner

Each session keeps a **ledger**: the decisions the owner made in it, and what
it needs from the owner, each with a line saying why the work exists. `/ledger`
prints it. So when the owner asks this session "status?", the answer starts
there instead of being rebuilt from GitHub and memory, and what the owner has
to do is written down before they ask. (A view of every local session's
ledger at once, a glanceable mod among them, is #316.)

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
days later, and a small in-the-weeds issue is easy to forget the reason for.
The script refuses an entry without one. The entry's own text goes on the
lines after it.

- **A decision**, whenever the owner decides something in this session: a scope
  change, a defer, a merge authorized, a design pick, a review-round cap raised,
  a follow-up declined. One line saying what was decided and why. The owner's
  decisions, not your own choices along the way.
- **A need**, whenever this session stops for something only the owner can
  give: a review or a merge, a design decision, a permission prompt, a credential
  to unlock (1Password), an answer to a question. Say what is needed and the
  **exact unblock step**, so the owner can act without reading back through
  the session: `review PR #212, then claude attach 5864ecfd and say finish`,
  `approve the Bash prompt in claude attach 5864ecfd`. When the need is about a
  PR, give that PR as `--ref`, so the merge that answers it can resolve it.
  Record each need once: check `list` before adding one that may already be
  open.
- **Only your own needs.** A need lives in the ledger of the session that needs
  the owner. When a session you spawned pings that it needs the owner, that
  child records it in its own ledger; don't copy it into yours, and relay it
  to the owner as before.
- **Resolve a need** once the owner has answered: they replied, approved or
  merged. Resolve a need that no longer applies too (its PR closed, the plan
  changed). When a PR lands, `resolve --ref` resolves every open need of this
  session's under it.

## When to read

When the owner asks this session "status?", "what's left?" or what it needs
from them, run `list` first: its open needs, decisions and resolved needs,
newest first, each under its Why line. Then verify what may have moved since
(PR state, the sessions you spawned), and lead the answer with what needs the
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
bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" list
```

- `add-decision` and `add-need` print the new entry's id (`d1`, `n1`); `--ref`
  is optional (an issue or PR: `#212`, `owner/repo#12`, `ABC-12`). A bare
  `#212` is written as `owner/repo#212`, from the checkout's origin remote, so
  every session in one repo records the same ref and two repos' `#12` don't
  collide. Outside a checkout of the ref's repo a bare `#212` stays as it is,
  and in a fork's checkout `origin` names the fork, so there pass the full
  `owner/repo#212`. An `owner/repo#212` ref is stored with its owner and repo
  lowercased, as GitHub ignores their case. The first line must be the Why
  line, `Why:` and then at most 200 bytes; it's stored as the entry's `why`,
  and `list` prints it above the text. The text after it is at most 4000
  bytes. Neither may hold a control character but tab and newline.
- `resolve <need id>` marks one of this session's needs resolved.
- `resolve --ref <ref>` resolves every open need of this session's with that
  ref, the hand-back's and any `blocked:` one, and prints their ids. It's for a
  PR that landed (ticket-workflow's FINISH runs it), since the merge answers
  all of them.
- `list` prints this session's open needs, decisions and resolved needs.
- A body line that is exactly `LEDGER_EOF` would end the heredoc early: use
  another delimiter, the same word in both places. Don't also pipe into the
  command: under zsh a pipe and a heredoc on one command both feed stdin.
- Your attach handle, for an unblock step (the session id falls back as the
  script's does, on a CLI before 2.1.132):
  `claude agents --json --all | jq -r --arg s "${CLAUDE_CODE_SESSION_ID:-$CLAUDE_SESSION_ID}" '.[] | select(.sessionId == $s) | .id'`
  (nothing for an interactive session, which the owner is already in).

`CLAUDE_LEDGER_ROOT` is set by the plugin's SessionStart hook. When it is unset
(the plugin installed mid-session, hooks off) a command stops with
`parameter not set`; when it is stale (a mid-session update) it fails with
`No such file`. Then find the script with the Glob tool
(`cache/*/ledger/*/scripts/ledger.sh` under your Claude config's `plugins/`
directory, the highest version if several match) and run it by that path.

A ledger is keyed on the session id, so after `/clear` or a fork (which start
a new one) entries recorded earlier stay under the old id, out of `list`'s
reach. Resuming the session (`claude --resume`) keeps its id and its ledger.
The SessionStart hook reaps a ledger untouched for 30 days only when it has no
open need.

A ledger write that fails never blocks the work it describes: carry on, and
say in your next report what wasn't recorded and why.
