---
name: ledger
description: 'Use when instructions (a ticket-workflow charter or step, a briefing) or the owner ask this session to record a decision the owner made or something it needs from the owner, when a child session pings that it needs the owner, or when the owner asks "status?" or what needs them. Keeps the per-session ledger that the ledger mod and /ledger show across every local session.'
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
- **A child's need**, when a session you spawned pings that it needs the owner
  (`blocked: merge needs the owner`, a `declined: … needs the owner` line, a
  stack `ready; needs the owner`). Record it as a need of yours, naming the
  child and its unblock step, with the `--ref` the child used (its PR). That
  puts it in the ledger of the session the owner talks to, so a "status?"
  there has it, and the shared ref lets the listings show the child's need and
  your copy once, as one row naming both.
- **Resolve a need** once the owner has answered: they replied, approved,
  merged, or the child pinged `merged:` or `resumed:`. Resolve a need that no
  longer applies too (its PR closed, the plan changed).

## When to read

When the owner asks "status?", "what's left?" or what needs them, run
`list --all` first: every session's open needs, newest first, then this
session's decisions. Then verify what may have moved since (PR state,
`claude agents`), and lead the answer with what needs the owner.

## The commands

The text goes on stdin through a quoted heredoc, so quotes, backticks and `$`
stay literal. Quote a `--ref` that starts with `#`: unquoted, the shell reads it
as a comment.

```bash
bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" add-decision --ref '#208' <<'LEDGER_EOF'
<what the owner decided, and why>
LEDGER_EOF
bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" add-need --ref '#212' <<'LEDGER_EOF'
<what the owner needs to do, and the exact step>
LEDGER_EOF
bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" resolve n1
bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" list --all
```

- `add-decision` and `add-need` print the new entry's id (`d1`, `n1`); `--ref`
  is optional (an issue or PR: `#212`, `owner/repo#12`, `ABC-12`). The text is
  at most 4000 bytes, with no control characters but tab and newline.
- `resolve <need id>` marks one of this session's needs resolved;
  `--session <session id or a unique prefix of 4+ characters>` resolves another
  session's. That is for the owner dismissing a need whose session is gone, and
  for a session that landed another session's PR (ticket-workflow's FINISH),
  never for a need that session can still answer itself.
- `list` prints this session's open needs, decisions and resolved needs;
  `list --all` prints every session's open needs and this session's decisions.
  Open needs that share a ref are one row there, under the first recorded,
  with an `also:` line naming the other copies. The pane's Resolve resolves
  every copy; `resolve` resolves one, so resolve the copy in your own ledger.
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

A ledger write that fails never blocks the work it describes: carry on, and
say in your next report what wasn't recorded and why.
