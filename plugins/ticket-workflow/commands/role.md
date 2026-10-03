---
description: Pin this session to a role charter (planner / epic-coordinator / implementer) or drop it with "none" — persists across resume and compaction, and arms a drift guard for planner (edits prompt for approval) and implementer (issue-spawning launches are denied)
argument-hint: <planner | epic-coordinator | implementer | none>
---
Pin (or unpin) this session's role charter: **$ARGUMENTS**

A role set here is durable: it's recorded in a per-session marker file that the
plugin's hooks consume — the SessionStart hook re-injects the charter after
`--resume` and compaction, and the PreToolUse guard turns file edits
into a permission prompt while the `planner` charter is pinned, and denies a
`claude --bg`/`-p` or `create_session` launch that leads with an issue-spawning
command while `implementer` is. This is the
manual step `roles/planner.md` describes for the top session; the tiers below
are normally injected by spawn edges (`Role:` directives), not by hand.
It is also how a session gets its pin back where the marker doesn't follow
it (the skill's Session roles: *Session identity*). `/clear` and forks
(`--fork-session`, `/branch`, and `/fork` with agent view on) start a new
session id that nothing links to the old one. With agent view off, `/fork`
runs in-process under this session's pin, so there's nothing to re-pin. After
`claude --teleport` the marker is still on the machine the session ran on (a
teleport launch doesn't deliver SessionStart output either). Re-run
`/role <role>` in the new or teleported session. An in-process subagent (or
any other agent running inside the session) can't pin at all: it shares its
parent's session, so the PreToolUse hook denies its marker write.

Every marker read and write goes through the plugin's `scripts/role-marker.sh`
(the skill's Session roles), which finds this session's id itself: the
harness's `CLAUDE_CODE_SESSION_ID` (Claude Code 2.1.132+), else the
`CLAUDE_SESSION_ID` this plugin's SessionStart hook exports on older CLIs. The
commands below run it from `$CLAUDE_TICKET_WORKFLOW_ROOT`, which the same hook
sets. If that variable is empty, a command stops with `parameter not set`:
find the script with the Glob tool instead
(`**/ticket-workflow/scripts/role-marker.sh` under your Claude config's
`plugins/` directory, taking the highest version if several match) and run
the same command with that path in place of
`${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/role-marker.sh`.

1. Take the first token of "$ARGUMENTS" as the role. Valid: `planner`,
   `epic-coordinator`, `implementer`, `none`. Anything else (or empty): report
   the valid values, plus the current pin when there is one, and stop. The
   pin is what this prints: the role on its first line, then any `issue:`
   lines an implementer recorded and a `notify:` line naming its `Notify:`
   target (nothing, and a note on stderr, when the session has no marker):

   ```bash
   bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/role-marker.sh" show
   ```

2. If the script reports no session id (both variables unset), this is a
   Claude Code older than 2.1.132 whose SessionStart hook didn't run (plugin
   installed mid-session, or hooks disabled) — say so, note the fix (upgrade
   Claude Code, or restart the session so SessionStart fires), and note that
   the marker was not written in step 3/4, but still do step 5 so the charter
   at least governs the current context.

3. **`none` — unpin:**

   ```bash
   bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/role-marker.sh" unpin
   ```

   This deletes the whole marker, so any `issue:` lines and the `notify:`
   line go with it: after the next compaction the session no longer has its
   `Notify:` target re-injected. State that the role is dropped and no charter
   governs the session; stop.

4. **Pin:** write the marker, unless its first line already names this role:

   ```bash
   bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/role-marker.sh" pin <role>
   ```

   A hand pin writes the role line only. The `issue:` and `notify:` lines a
   spawned session's self-pin adds (START Step 1) have no source here, so a
   fresh hand pin leaves START's one-issue guard unarmed and re-injects no
   `Notify:` target. Re-pinning the role the marker already holds (compared as
   the hooks read it: first line, whitespace stripped) leaves the marker
   untouched, so a spawned implementer that runs `/role implementer` keeps its
   issue and notify lines. Pinning a different role rewrites the marker and
   drops them.

5. Read the charter at
   `$CLAUDE_TICKET_WORKFLOW_ROOT/skills/ticket-workflow/roles/<role>.md` and
   **adopt it as governing for this session**, exactly as START Step 1 does
   for a spawned `Role:` directive. Read it **whole with the Read tool** at the
   absolute path the variable expands to (`echo "$CLAUDE_TICKET_WORKFLOW_ROOT"`
   for the value). If the variable is empty, find the file with the Glob tool
   (`**/ticket-workflow/skills/ticket-workflow/roles/<role>.md` under your
   Claude config's `plugins/` directory), from the same version directory as
   the script above, and Read that path. Never `cat`, `sed`, `grep`, or `find`
   your way through the plugin cache instead: it's a protected path, and Bash
   commands that read it can stop on a permission prompt that no allow rule
   can pre-approve.

6. Confirm to the user: role pinned, what it binds (`planner` also arms the
   edit guard — edits prompt for approval until `/role none`; `implementer`
   arms the spawn guard — issue-spawning entry points refuse and issue-spawn
   launches are denied until `/role none`), and that it survives
   resume/compaction but not `/clear` or a fork, after which `/role` is run
   again.
