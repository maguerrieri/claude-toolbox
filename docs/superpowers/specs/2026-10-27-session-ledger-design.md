# Session ledger: decisions made and what a session needs from the owner (#208)

## Problem

The owner keeps asking planners and coordinators "status?". Each answer is
rebuilt from GitHub sweeps, `claude agents`, and the session's memory of the
conversation. The two things the owner wants from that answer aren't kept
anywhere durable:

- **Decisions made**: scope changes, defers, merges authorized, design picks,
  caps raised. They're scattered across chat turns and issue comments, and lost
  when a session compacts or exits.
- **What a session needs from the owner**: a review or merge, a design decision,
  a permission prompt, an unlocked 1Password. Today these surface only when the
  owner asks, or when a child's `blocked:` ping reaches the planner's chat.

## Decisions

- **Its own plugin, `ledger`.** A non-ticket session can keep a ledger too, so
  the script, the hooks, the mod, `/ledger` and a short skill live in
  `plugins/ledger/`. `ticket-workflow`'s charters, START and FINISH point to
  the skill where the plugin is installed, and `defaults` pulls it in.
  `ticket-workflow` doesn't list it under `dependencies`: the install that
  repo settings trigger doesn't resolve dependencies (`AGENTS.md`), so a repo
  whose settings predate `ledger` would lose `ticket-workflow` entirely.
- **One JSONL file per session**, keyed like the role marker:
  `~/.claude/session-ledger/<session id>.jsonl` (`CLAUDE_SESSION_LEDGER_DIR`
  overrides it for tests). The session id is `CLAUDE_CODE_SESSION_ID`, else the
  `CLAUDE_SESSION_ID` the plugin's SessionStart hook (and ticket-workflow's)
  exports on older CLIs. A write holds the ledger directory's one lock from
  its read to its rename, since parallel tool calls and the owner's Resolve
  can write one ledger at once. The lock is `flock(2)` on `.lock` in the
  ledger directory, taken by perl on a descriptor the script's shell keeps
  open, so the kernel drops it when the holder dies. A lock file that can be
  deleted and remade (`mkdir`, a symlink naming the holder) needs stale-lock
  reclaiming, and a reclaiming waiter can remove a successor's live lock:
  Codex reproduced lost entries that way on PR #272. For the same reason the
  lock file is never deleted, so the 30-day reaping skips it. Copilot found
  that reaping the per-ledger lock files an earlier version kept could unlink
  one a writer had just opened. One lock for the whole directory leaves
  nothing to reap, and writes are few and brief enough that sharing it costs
  nothing.
  Each line is one entry:
  `{kind: "decision"|"need", id, why, text, ref?, at, cwd, resolved_at?}`. `id` is
  `d<n>` or `n<n>`, numbered per kind within the file. `cwd` is where the
  session wrote from, so a reader can name a session that `claude agents`
  doesn't list (an interactive one). A bare `#<n>` ref is written as
  `<owner>/<repo>#<n>` from the checkout's origin, so a repo's sessions agree
  on a ref and two repos' `#12` stay apart. Outside such a checkout a bare ref
  stays bare, and a fork's origin names the fork, so START's hand-back and
  FINISH spell out the PR's own `<owner>/<repo>#<pr>`.
- **A session writes its own ledger, and a need lives only in the ledger of
  the session that needs the owner.** A spawner doesn't copy a child's
  `blocked:` into its own: `list --all` and the mod read every local ledger,
  so the child's need already reaches the "status?" answer of the session the
  owner talks to. (The first version did copy it up the tree and showed open
  needs that shared a ref as one row. The self-review on the rebased PR found
  that this also merged two different needs under one PR, hiding the second
  one's text, and that Resolve then dismissed both.) Two writes reach another
  session's: `resolve --session`, the owner dismissing a need (the pane's
  Resolve button, `/ledger resolve`); and `resolve --ref`, which FINISH runs
  when a PR lands, resolving every open need under the PR in every ledger.
  Every write goes through a temp file and a rename, so a reader never sees
  half a line.
- **Every entry opens with a Why line** (the owner's request on PR #272,
  2026-11-14): `Why: <history and goal>`, one short line on why the work the
  entry is about exists, since a small in-the-weeds issue is easy to forget
  the reason for when its need shows up days later among other sessions'.
  It's the first line of the text on stdin, stored as `why` (at most 200
  bytes), and the script refuses an entry without one, so writers can't skip
  it. The listings and the pane print it above the entry's text; the band
  keeps showing the text, which is the action. Entries written before it have
  no `why` and still list.
- **Writes go through `scripts/ledger.sh`**: `add-decision` and `add-need` (a
  Why line, then the text, on stdin through a quoted heredoc, `--ref`
  optional), `resolve <id>`,
  `resolve --ref <ref>`, and `list [--all]`. Text on stdin keeps quotes and `$`
  literal, the same way `role-marker.sh notify` takes a session name.
- **Subagents can't write their parent's ledger.** A subagent's Bash runs with
  the same environment as its parent (checked on 2.1.312: the variable names
  match), so the script can't tell it apart. The PreToolUse hook can: a
  subagent's call carries an `agent_id`. It denies a subagent's Bash that runs
  `ledger.sh` with a writing subcommand. Reads (`list`) pass. The rule is
  ticket-workflow's marker-write rule with the script and its read swapped;
  the plugins install separately, so it's a copy, and a test fails if the two
  drift apart.
- **Reader: a mod plus `/ledger`.** The mod (a hooks module in the same plugin)
  polls the ledger directory, joins session names from
  `claude agents --json --all` (asked only while another session has an open
  need, since names label only those), and draws a one-line band above the
  prompt while any session has an open need, and a pane (`/ledger-pane`)
  listing open needs across every local session plus this session's recent
  decisions, each need with a Resolve button. `/ledger` prints the same
  through `ledger.sh list --all` for a session without mods.
- **"status?" reads the ledger first.** The planner and coordinator charters
  answer from `ledger.sh list --all` and verify against GitHub, instead of
  sweeping first.
- **Garbage collection**: the SessionStart hook deletes ledger files untouched
  for 30 days, as ticket-workflow's does for role markers, under the
  directory's lock: unlocked, it could check a ledger's age just before a
  write renamed an updated one into place, and delete the new entry with the
  old ones. When a write holds the lock past two seconds, it skips its turn.

## Out of scope

Cloud sessions (they can't see local ledgers, and SendMessage doesn't reach
them), and anything synced off-machine.
