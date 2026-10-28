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
  exports on older CLIs. A write holds a per-file lock (a symlink naming the
  holder's PID: `ln -s` is atomic, and a dead holder's lock is taken over at
  once) from its read to its rename, since parallel tool calls and the
  owner's Resolve can write one ledger at once.
  Each line is one entry:
  `{kind: "decision"|"need", id, text, ref?, at, cwd, resolved_at?}`. `id` is
  `d<n>` or `n<n>`, numbered per kind within the file. `cwd` is where the
  session wrote from, so a reader can name a session that `claude agents`
  doesn't list (an interactive one). A bare `#<n>` ref is written as
  `<owner>/<repo>#<n>` from the checkout's origin, so a repo's sessions agree
  on a ref and two repos' `#12` stay apart.
- **A session writes its own ledger.** A child's `blocked:` ping becomes a
  need in the spawner's ledger because the spawner records it there. Two
  writes reach another session's: `resolve --session`, the owner dismissing a
  need (the pane's Resolve button, `/ledger resolve`); and `resolve --ref`,
  which FINISH runs when a PR lands, resolving the child's need and every
  spawner's copy at once. Every write goes through a temp file and a rename,
  so a reader never sees half a line.
- **Writes go through `scripts/ledger.sh`**: `add-decision` and `add-need` (text
  on stdin through a quoted heredoc, `--ref` optional), `resolve <id>`,
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
  `claude agents --json --all`, and draws a one-line band above the prompt
  while any session has an open need, and a pane (`/ledger-pane`) listing open
  needs across every local session plus this session's recent decisions, each
  need with a Resolve button. `/ledger` prints the same through
  `ledger.sh list --all` for a session without mods. Open needs that share a
  ref (a child's need and its spawner's copy) are one row in both, so a
  bubbled need isn't counted once per tier.
- **"status?" reads the ledger first.** The planner and coordinator charters
  answer from `ledger.sh list --all` and verify against GitHub, instead of
  sweeping first.
- **Garbage collection**: the SessionStart hook deletes ledger files untouched
  for 30 days, as ticket-workflow's does for role markers.

## Out of scope

Cloud sessions (they can't see local ledgers, and SendMessage doesn't reach
them), and anything synced off-machine.
