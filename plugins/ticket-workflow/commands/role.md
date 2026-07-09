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

1. Take the first token of "$ARGUMENTS" as the role. Valid: `planner`,
   `epic-coordinator`, `implementer`, `none`. Anything else (or empty): report
   the valid values and the current marker's content if one exists
   (`cat "$HOME/.claude/session-roles/$CLAUDE_SESSION_ID"`), and stop.

2. **`none` — unpin:**

   ```bash
   rm -f "$HOME/.claude/session-roles/$CLAUDE_SESSION_ID"
   ```

   State that the role is dropped and no charter governs the session; stop.

3. **Pin:** write the marker, keyed by session id (`$CLAUDE_SESSION_ID` is
   exported by this plugin's SessionStart hook via `CLAUDE_ENV_FILE`):

   ```bash
   mkdir -p "$HOME/.claude/session-roles"
   printf '%s\n' "<role>" >"$HOME/.claude/session-roles/$CLAUDE_SESSION_ID"
   ```

   If `$CLAUDE_SESSION_ID` is unset, the hook didn't run (plugin installed
   mid-session, or hooks disabled) — say so, note the fix (restart the session
   so SessionStart fires), and still do step 4 so the charter at least governs
   the current context.

4. Read the charter at
   `$CLAUDE_TICKET_WORKFLOW_ROOT/skills/ticket-workflow/roles/<role>.md` (fall
   back to locating `roles/<role>.md` under this plugin's skill directory if the
   env var is unset) and **adopt it as governing for this session**, exactly as
   START Step 1 does for a spawned `Role:` directive.

5. Confirm to the user: role pinned, what it binds (`planner` also arms the
   edit guard — edits prompt for approval until `/role none`), and that it
   survives resume/compaction.
