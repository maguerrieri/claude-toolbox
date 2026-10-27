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
  `plugins/ledger/`. `ticket-workflow` lists it under `dependencies` and its
  charters, START and FINISH point to the skill. `defaults` pulls it in.
- **One JSONL file per session**, keyed like the role marker:
  `~/.claude/session-ledger/<session id>.jsonl` (`CLAUDE_SESSION_LEDGER_DIR`
  overrides it for tests). The session id is `CLAUDE_CODE_SESSION_ID`, else the
  `CLAUDE_SESSION_ID` ticket-workflow's SessionStart hook exports on older CLIs.
  Each line is one entry:
  `{kind: "decision"|"need", id, text, ref?, at, cwd, resolved_at?}`. `id` is
  `d<n>` or `n<n>`, numbered per kind within the file. `cwd` is where the
  session wrote from, so a reader can name a session that `claude agents`
  doesn't list (an interactive one).
- **One writer per file.** A session writes only its own ledger. A child's
  `blocked:` ping becomes a need in the spawner's ledger because the spawner
  records it there. The exceptions resolve another session's need
  (`resolve --session`): the owner dismissing one (the pane's Resolve button,
  `/ledger resolve`), and a FINISH that landed another session's PR. Every write goes
  through a temp file and a rename, so a reader never sees half a line.
- **Writes go through `scripts/ledger.sh`**: `add-decision` and `add-need` (text
  on stdin through a quoted heredoc, `--ref` optional), `resolve <id>`, and
  `list [--all]`. Text on stdin keeps quotes and `$` literal, the same way
  `role-marker.sh notify` takes a session name.
- **Subagents can't write their parent's ledger.** A subagent's Bash runs with
  the same environment as its parent (checked on 2.1.312: the variable names
  match), so the script can't tell it apart. The PreToolUse hook can: a
  subagent's call carries an `agent_id`. It denies a subagent's Bash that runs
  `ledger.sh` with a writing subcommand. Reads (`list`) pass.
- **Reader: a mod plus `/ledger`.** The mod (a hooks module in the same plugin)
  polls the ledger directory, joins session names from
  `claude agents --json --all`, and draws a one-line band above the prompt
  while any session has an open need, and a pane (`/ledger-pane`) listing open
  needs across every local session plus this session's recent decisions, each
  need with a Resolve button. `/ledger` prints the same through
  `ledger.sh list --all` for a session without mods.
- **"status?" reads the ledger first.** The planner and coordinator charters
  answer from `ledger.sh list --all` and verify against GitHub, instead of
  sweeping first.
- **Garbage collection**: the SessionStart hook deletes ledger files untouched
  for 30 days, as ticket-workflow's does for role markers.

## Out of scope

Cloud sessions (they can't see local ledgers, and SendMessage doesn't reach
them), and anything synced off-machine.
