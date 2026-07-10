---
description: Pin this session to a role charter (planner / epic-coordinator / implementer) or drop it with "none" — persists across resume and compaction, and (for planner) arms the edit drift-guard
argument-hint: <planner | epic-coordinator | implementer | none>
---
Pin (or unpin) this session's role charter: **$ARGUMENTS**

A role set here is durable: it's recorded in a per-session marker file that the
plugin's hooks consume — the SessionStart hook re-injects the charter after
`--resume`, `/clear`, and compaction, and the PreToolUse guard turns file edits
into a permission prompt while the `planner` charter is pinned. This is the
manual step `roles/planner.md` describes for the top session; the tiers below
are normally injected by spawn edges (`Role:` directives), not by hand.

The marker directory is `${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}`
(the override exists for testing; the hooks honor the same variable) — called
`$roles_dir` below.

1. Take the first token of "$ARGUMENTS" as the role. Valid: `planner`,
   `epic-coordinator`, `implementer`, `none`. Anything else (or empty): report
   the valid values and the current marker's content if one exists
   (`cat "$roles_dir/$CLAUDE_SESSION_ID"`), and stop.

2. If `$CLAUDE_SESSION_ID` is unset, this plugin's SessionStart hook didn't
   run (plugin installed mid-session, or hooks disabled) — say so, note the
   fix (restart the session so SessionStart fires), skip the marker write in
   step 3/4, but still do step 5 so the charter at least governs the current
   context.

3. **`none` — unpin:**

   ```bash
   rm -f "$roles_dir/$CLAUDE_SESSION_ID"
   ```

   State that the role is dropped and no charter governs the session; stop.

4. **Pin:** write the marker, keyed by session id (`$CLAUDE_SESSION_ID` is
   exported by this plugin's SessionStart hook via `CLAUDE_ENV_FILE`):

   ```bash
   mkdir -p "$roles_dir"
   printf '%s\n' "<role>" >"$roles_dir/$CLAUDE_SESSION_ID"
   ```

5. Read the charter at
   `$CLAUDE_TICKET_WORKFLOW_ROOT/skills/ticket-workflow/roles/<role>.md` (fall
   back to locating `roles/<role>.md` under this plugin's skill directory if the
   env var is unset) and **adopt it as governing for this session**, exactly as
   START Step 1 does for a spawned `Role:` directive.

6. Confirm to the user: role pinned, what it binds (`planner` also arms the
   edit guard — edits prompt for approval until `/role none`), and that it
   survives resume/compaction.
