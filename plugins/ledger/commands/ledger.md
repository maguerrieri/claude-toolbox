---
description: "Show every local session's open needs and this session's decisions (the session ledger), or resolve a need: /ledger resolve <session> <need id>"
argument-hint: '[resolve <session> <need id>]'
---
Show or update the session ledger: **$ARGUMENTS**

The ledger is the `ledger` plugin's per-session record of the owner's
decisions and what each session needs from the owner (the `ledger` skill has
the details). Run its script from `$CLAUDE_LEDGER_ROOT`, which the plugin's
SessionStart hook sets. If a command stops with `parameter not set` or
`No such file`, find the script with the Glob tool
(`cache/*/ledger/*/scripts/ledger.sh` under your Claude config's `plugins/`
directory, the highest version if several match) and run it by that path.

- **No arguments:** run

  ```bash
  bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" list --all
  ```

  and show its output as it printed, in a code block. Add nothing but, when
  there are open needs, one line pointing at `/ledger-pane` (the pane, with a
  Resolve button per need) where the ledger mod is loaded.
- **`resolve <session> <need id>`:** the owner dismissing a need, theirs to
  make for any session. Substitute the two values only when the session is
  letters, digits, `.`, `_` and `-`, at least four characters (a session id or
  the short id `list --all` shows), and the need id is `n` and digits; anything
  else, say what's wrong and run nothing. Then run

  ```bash
  bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" resolve <need id> --session <session>
  ```

  and report what it said, then the `list --all` output as above.
- **Anything else:** show the two forms above and stop.
