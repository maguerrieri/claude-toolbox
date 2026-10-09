# Role marker: the marker, the hooks, and session identity

Reference for `SKILL.md`'s **Session roles** section. That section and the steps it names carry everything a normal run does: the roles, how `Role:` propagates, the self-pin and notify commands, the spawn guard's marker read, and the Glob retry when the plugin root is unset or stale. This file holds the detail behind them: what the marker holds and who writes each line, exactly what each hook does, which session id keys the marker and where that id and the session don't line up, and what the hook-level guards can't see.

## The marker

`/role <role>`, and a spawned tier's self-pin, write a per-session marker at `~/.claude/session-roles/<session_id>`. Every read and write of it that a session makes goes through one script, `scripts/role-marker.sh` (the hooks read it directly, through the script's helper `scripts/marker-lib.sh`, since they take the session id from their input): `show` prints it, `pin <role> [--issue <id>]` pins, `unpin` deletes it, and `notify` records the `Notify:` target. The script writes through a temp file and a rename, always ends the marker with a newline, and exits 1 with the reason on stderr when it writes nothing.

- **First line: the role.** Everything that checks the role reads that line only. `/role` by hand writes only this line; START Step 1 and EPIC Step 1 write it when they adopt a `Role:` directive. A marker that already holds the role being pinned is kept, so its other lines survive; a different role (or none) is replaced, dropping the other lines with it.
- **`issue: <id>` lines.** An implementer's self-pin adds one, recording the one issue it owns; a human override in START Step 1 adds another rather than replacing the first. START Step 1 checks them (the one-issue guard). `--issue` is for `implementer` only: for another role the script pins the role, skips the issue line, and says so on stderr, and it does the same for a malformed id that reaches it anyway (START Step 1 drops `--issue` for an id that doesn't match the tracker's `ID format`).
- **`notify: <session name>` line.** A self-pinned session briefed with a `Notify:` directive records it here (START Step 1, EPIC Step 1), and SessionStart re-injects it next to the charter, so the pings survive compaction too. It is also the one sender a `finish:` clearance is accepted from (the FINISH intro). `notify` replaces an earlier `notify:` line and keeps the others; it writes nothing, and says why, with no marker, no session id, or a name the hook would refuse (`messaging.md` has the details).

`/role none` deletes the marker with all its lines.

## The hooks

- **SessionStart** re-injects the charter, and any recorded `notify:` line, after resume and compaction. A `Role:` directive read at START or EPIC Step 1 doesn't survive those. It also sets `CLAUDE_TICKET_WORKFLOW_ROOT` (below), and on CLIs that don't set the harness's session id it exports one of its own (*Session identity*).
- **UserPromptSubmit** adds a one-line reminder of the tier's actor test to every prompt while `planner` or `epic-coordinator` is pinned. The charter in context can be turns old when a request arrives, and a skill's own procedure then takes over.
- **PreToolUse**, while `planner` is pinned, turns file edits and `EnterWorktree` into a permission prompt: drift-proof unattended, one keystroke for a human, the charter's escape hatch made mechanical. The prompt's reason reaches only the human, so the call also carries one line of context telling the model to file and spawn if it was rejected. An edit under a scratch or memory directory (the background job's directory, `/tmp`, `$TMPDIR`, or an auto-memory directory `<config>/projects/*/memory/`) is a planner's own work and gets no prompt from it.
- **PreToolUse**, while `implementer` is pinned, denies a `claude --bg`/`-p` or cloud `create_session` launch whose prompt leads with an issue-spawning command. That backstops `SKILL.md`'s implementer spawn guard against a hand-rolled spawn.
- **PreToolUse**, in any session, pinned or not, denies an in-process subagent's marker write (*Session identity*).

## The plugin root

The docs run the script from `$CLAUDE_TICKET_WORKFLOW_ROOT`, which the SessionStart hook sets. Two things break that, and `SKILL.md`'s *Pinning* has the error each one gives and what a write and a read do then (the read's Glob retry is the one `/role` uses for each of its commands). The variable is unset when the plugin was installed mid-session or hooks are off. It is stale after a mid-session update: the plugin cache keeps versions side by side, so it can name an older version that doesn't have the script.

## Session identity

`role-marker.sh` finds the session id itself. It takes the harness's `CLAUDE_CODE_SESSION_ID`, which every Bash call gets (Claude Code 2.1.132+) as this session's own id, the same `session_id` the hooks read; a child `claude` session sets its own even when it inherited its parent's (checked with a `claude -p` child). Else it takes `CLAUDE_SESSION_ID`, which this plugin's SessionStart hook exports only when the harness doesn't set the first (older CLIs).

That one is an ordinary exported variable, so a `claude --bg` child launched from the Bash tool inherits it: on an older CLI, a child whose own hook didn't run would write its self-pin into its parent's marker. So every local spawn edge strips it (`env -u CLAUDE_SESSION_ID claude --bg …`), and such a child has no id and writes nothing. No id at all → the script skips the write, says why, and the charter governs from context.

Three cases where the key and the session don't line up:

- **An in-process subagent** (started by the Agent tool, not a separate `claude`; also `/fork` with agent view off) runs inside its parent's session and shares its id, so it never self-pins: the marker is its parent's. The harness tells its tool calls apart by one field, an `agent_id` in the hook input (checked on Claude Code 2.1.282). So the PreToolUse hook, pinned session or not, denies a subagent's call that would write the marker: a Bash command that names `role-marker.sh` (or a variable set to it) followed by any word but `show` anywhere outside quotes and heredocs, unless that word is a path or an option (`hooks/role-guard-marker-write.jq`), or a file edit in the roles directory. Reads pass (`show`), so the guards still see the parent's role, which is the one that governs a subagent. That is why the spawn edges hand ticket work to sessions, never to subagents or teammates (EPIC Step 3, *No agent teams*): each tier then has a session id of its own, and so a marker of its own wherever an id resolves.
- **`/clear` and forks** (`--fork-session` with `--resume` or `--continue`, `/branch`, and `/fork` with agent view on, which starts a background session) start a new session id, and the marker stays under the old one. Nothing links the two for a hook to follow: SessionStart's input has no predecessor field, the environment holds only the new id, and a fork's transcript isn't written yet when SessionStart runs (checked with `--resume --fork-session` on 2.1.282; `/clear` per the Claude Code docs). So the pin doesn't follow: re-pin with `/role <role>` after `/clear` or a fork. A fork still has the charter text in its copied conversation, but not the guards; `/clear` keeps neither. `/role` writes no `issue:` line, so a re-pinned implementer's one-issue guard stays unarmed.
- **A teleported session** (`claude --teleport`) has no marker on its new machine, since the marker stayed where the session ran, and a teleport launch doesn't deliver SessionStart output (traced in Claude Code 2.1.282). So nothing re-attaches the charter on its own: re-pin with `/role <role>` after teleporting.

## Known limits of the hook-level guards

The guards are the charters' default posture made mechanical, not a lock.

- **The Bash tests read the command text.** Like the launch check, the subagent marker-write test passes a run inside a quoted string (`bash -c '…'`) or one whose subcommand arrives on stdin, and so does a write improvised without the script, which no doc shows. The launch check likewise passes a launch written to a file and run later, and a cloud prompt that opens with prose naming the skill instead of a slash command.
- **A subagent runs under its parent's role.** It has no marker of its own, so the hook-level guards read its parent's role, and a charter it was briefed with governs from context only. Handing ticket work to sessions rather than subagents is by convention; nothing stops a session from briefing a subagent `/start-ticket … Role: implementer`, and such a subagent runs under its parent's guards.
- **The pin is keyed on the session id**, so it doesn't follow `/clear`, a fork or a teleport (above). The charter text may still be in context there, but until `/role` re-pins, no hook enforces it.
