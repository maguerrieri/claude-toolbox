---
description: "Show this session's ledger (the owner's decisions and what the session needs from them), or resolve one of its needs: /ledger resolve <need id>"
argument-hint: '[resolve <need id>]'
---
Show or update this session's ledger: **$ARGUMENTS**

The ledger is the `ledger` plugin's per-session record of the owner's
decisions and what this session needs from the owner, each with a line on why
the work exists. This command only shows the ledger or resolves a need: to
record a decision or a need, read the plugin's skill file,
`skills/ledger/SKILL.md` under `$CLAUDE_LEDGER_ROOT`, which has the Why line,
`--ref` and heredoc rules. Run its script from
`$CLAUDE_LEDGER_ROOT`, which the plugin's SessionStart hook sets. If a command
stops with `parameter not set` or `No such file`, find the script with the
Glob tool (`cache/*/ledger/*/scripts/ledger.sh` under your Claude config's
`plugins/` directory, the highest version if several match) and run it by
that path.

- **No arguments:** run

  ```bash
  bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" list
  ```

  and show its output as it printed, in a code block, adding nothing.
- **`resolve <need id>`:** the owner marking one of this session's needs
  answered. Substitute the id only when it is `n` and digits; anything else,
  say what's wrong and run nothing. Then run

  ```bash
  bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" resolve <need id>
  ```

  and report what it said, then the `list` output as above.
- **Anything else:** show the two forms above and stop.
