---
description: Pin this session to a role charter (planner / epic-coordinator / implementer) or drop it with "none" — persists across resume and compaction, and arms a drift guard for planner (edits prompt for approval) and implementer (issue-spawning launches are denied)
argument-hint: <planner | epic-coordinator | implementer | none>
---
Pin (or unpin) this session's role charter: **$ARGUMENTS**

A role set here is durable: it's recorded in a per-session marker file that the
plugin's hooks consume — the SessionStart hook re-injects the charter after
`--resume`, `/clear`, and compaction, and the PreToolUse guard turns file edits
into a permission prompt while the `planner` charter is pinned, and denies a
`claude --bg` or `create_session` launch that leads with an issue-spawning
command while `implementer` is. This is the
manual step `roles/planner.md` describes for the top session; the tiers below
are normally injected by spawn edges (`Role:` directives), not by hand.

In every snippet below, first assign the marker directory (the override exists
for testing; the hooks honor the same variable):

```bash
roles_dir="${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}"
```

1. Take the first token of "$ARGUMENTS" as the role. Valid: `planner`,
   `epic-coordinator`, `implementer`, `none`. Anything else (or empty): report
   the valid values — plus, when `$CLAUDE_SESSION_ID` is set and a marker file
   exists, the current pin (`cat "$roles_dir/$CLAUDE_SESSION_ID"`) — and stop.

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
   `$CLAUDE_TICKET_WORKFLOW_ROOT/skills/ticket-workflow/roles/<role>.md` and
   **adopt it as governing for this session**, exactly as START Step 1 does
   for a spawned `Role:` directive. Read it **whole with the Read tool** at the
   absolute path the variable expands to (`echo "$CLAUDE_TICKET_WORKFLOW_ROOT"`
   for the value). If the variable is empty (step 2's case), find the file
   with the Glob tool (`**/ticket-workflow/skills/ticket-workflow/roles/<role>.md`
   under your Claude config's `plugins/` directory) and Read that path. Never
   `cat`, `sed`, `grep`, or `find` your way through the plugin cache instead:
   it's a protected path, and Bash commands there can stop on a permission
   prompt that no allow rule can pre-approve.

6. Confirm to the user: role pinned, what it binds (`planner` also arms the
   edit guard — edits prompt for approval until `/role none`; `implementer`
   arms the spawn guard — issue-spawning entry points refuse and issue-spawn
   launches are denied until `/role none`), and that it survives
   resume/compaction.
