# Session role pinning (`/role` + hooks) — Design

**Date:** 2026-07-08
**Issue:** claude-toolbox #32 (extends the charter layer already on PR #33)
**Status:** approved; implemented in the same PR

## Problem

PR #33's charter layer covers the spawned tiers: `Role:` briefing directives
propagate `epic-coordinator` / `implementer` down the spawn edges. Two gaps
remain:

1. **The top planner is manual and mechanism-less.** `roles/planner.md` said
   "output style / `--append-system-prompt` alias / SessionStart marker" —
   none built, and none of the launch-time options work when sessions are
   started from `claude agents` (no shell in front of the session, so no env
   var or flag).
2. **Charters are honor-system and volatile.** Nothing mechanically stops a
   planner from drifting into implementation, and a charter adopted from a
   briefing directive lives only in conversation context — `/compact`,
   `/clear`, and `--resume` all lose it.

## Design

A pinned role is a **marker file keyed by session id**:
`~/.claude/session-roles/<session_id>`, containing the role name. Set and
cleared by the `/role` command; consumed by two plugin hooks. No env vars in
the user's launch path — works from `claude agents`.

### `/role <planner | epic-coordinator | implementer | none>` (command)

- Writes (or, for `none`, deletes) the marker, then reads the charter into
  context and adopts it — same semantics as START Step 1 adopting a `Role:`
  directive.
- Keys the marker by `$CLAUDE_SESSION_ID`, which the Bash tool does not
  natively have; the SessionStart hook exports it (below).

### SessionStart hook (`hooks/role-session-start.sh`)

Fires on `startup|resume|clear|compact`:

1. Appends `export CLAUDE_SESSION_ID=…` and
   `export CLAUDE_TICKET_WORKFLOW_ROOT=…` to `$CLAUDE_ENV_FILE` (writable from
   SessionStart only; vars reach all subsequent Bash commands) — this is what
   lets `/role` key its marker and find the charters.
2. If a marker exists for this session, cats the matching
   `roles/<role>.md` to stdout, which Claude Code injects as session context —
   making the role durable across resume/`/clear`/compaction.
3. Opportunistically deletes markers older than 30 days (nothing else reaps
   them).

### PreToolUse hook (`hooks/role-guard.sh`)

Matcher `Edit|Write|MultiEdit|NotebookEdit`. If this session's marker says
`planner`, emits `permissionDecision: "ask"` with a reason pointing at
`/make-ticket` / `/spawn-*` and `/role none`. **Soft gate, not hard deny**, by
design: an unattended planner can't silently drift into implementation, while
a human at the wheel approves with one keystroke — the charters' escape-hatch
philosophy ("the guard bounds unattended sessions, not a person") made
mechanical. Other roles and unmarked sessions: no-op. All failure modes fail
open — the guard is a drift nudge, not a security control.

Bash is deliberately NOT gated: planners legitimately run `gh`, `git worktree
list`, greps, and `/make-ticket` itself shells out.

**Update (#218):** edits under a scratch or memory directory make no decision,
since they're a planner's own work (an issue body for FILE, a memory note), not
implementation: the background job's directory (`$CLAUDE_JOB_DIR`), the system
temp directory (`/tmp`, `/private/tmp`, `$TMPDIR`), and the auto-memory
directories (`<config>/projects/*/memory/`, `<config>` being
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}`). Both the path and the directories are
resolved first: symlinks are followed (a dangling one too) and `..` is taken
both as the OS takes it and as a tool that normalizes the path first does, and
both readings must land inside. So a symlinked `~/.claude` still matches, while
`/tmp/../<repo>/file` and a link out of `/tmp` into a repo still prompt. No
decision leaves Claude Code's own permission checks in force. The same issue
moved the docs' issue bodies, disposition comments and cap raises to stdin
(`gh … --body-file -`), so FILE writes no file at all.

**Update (#147):** the matcher now also covers `Bash` and the cloud
`create_session` tool, for a second guard: while `implementer` is pinned, a
`claude --bg`/`-p` or `create_session` launch whose prompt *leads* with an
issue-spawning command (`/start-ticket`, `/start-epic`, `/spawn-tickets`,
`/spawn-epic`, or their `/ticket-workflow:` forms, or `/make-ticket` with
`--spawn`/`--start`) gets `permissionDecision: "deny"` with a file-and-ping
redirect. The Bash check (`hooks/role-guard-launch.jq`) tokenizes the command
and reads only the words that can be the launch's prompt (the positional
prompt, the word after an option `claude --help` doesn't list, and stdin as
far as the command shows it), so a launch that is only quoted inside a
message or a comment doesn't count. Naming `mcp__.*__create_session` makes the
matcher a regex, which Claude Code tests unanchored, so it is anchored
(`^(…)$`) to keep `TodoWrite` or `BashOutput` out. The hook finds the session id
with a bash regex and exits before starting jq when the session has no marker,
since the matcher now runs it before every Bash call. The planner's Bash
stays ungated, as above. It denies rather than asks because an implementer
usually runs unattended, where nobody would answer a prompt. It backstops the
phase-entry *implementer spawn guard* in `SKILL.md`, and its tests are
`plugins/ticket-workflow/tests/test-role-guard.sh`.

**Update (#148):** the marker's role is now its **first line** only. When
START Step 1 self-pins `implementer`, it adds a second line, `issue: <id>`, so
START's *one-issue guard* can tell the implementer's own issue (a resume or
re-brief) from a second one it must refuse. A human override of that refusal
appends the new issue's line and keeps the old one. `/role` by hand writes no
issue line, and re-pinning the role a marker already holds leaves it intact.
Both hooks read the role with `head -n 1`: the old `tr -d '[:space:]'`
over the whole file would run the issue line into the role
(`implementerissue:52`) and silently turn both guards off.

**Update (#156):** a session that self-pins also records its briefing's
`Notify:` target as a `notify: <session name>` line (START Step 1's *Note your
notifier*; EPIC Step 1 for a coordinator's own), replacing any earlier one.
`role-session-start.sh` re-injects it after the charter, so a spawned session
that compacts or resumes keeps pinging its spawner instead of dropping to
the poll. The write is a script, `scripts/record-notify.sh`, that reads the
name from a quoted heredoc: a name can hold anything a spawn name holds (the
em dash in `/spawn-epic`'s coordinator name, an apostrophe, a ` [ref]`
suffix), so it must never be spliced into shell text, and the check must be
code rather than prose. The writer and the hook source one check,
`scripts/notify-name.sh`, which refuses a control character, a backtick, a
Unicode line break, surrounding whitespace, or over 200 bytes. It runs in the
C locale so the two can't disagree about a name, and it keeps the re-injected
name one code span on one line. That check is about format, not trust: the
session writes the line from its own briefing, so re-injecting it opens no
channel the briefing didn't. The alternative considered was the PR body. It was rejected
because reading it back depends on the session remembering to look, which is
what compaction breaks, and because there is no PR before START Step 7, when a
long implementation may already have compacted. The marker is re-injected
without the session doing anything.

**Update (#203):** every marker read and write a session makes now goes through one script,
`scripts/role-marker.sh`: `show` prints the marker, `pin <role> [--issue <id>]`
pins (keeping a marker whose first line already names the role, and appending
an `issue:` line only when it's missing), `unpin` deletes it, and `notify`
records the `Notify:` target, absorbing `scripts/record-notify.sh`. Before, each
was a shell snippet the model copied out of the docs, and the session-id lookup
was copied nine times; one copy had already drifted. The script owns the one
lookup (`CLAUDE_CODE_SESSION_ID`, else `CLAUDE_SESSION_ID`, then a plain-token
check), writes through a temp file and a rename, always ends the marker with a
newline (an append onto a marker without one used to turn `implementer` into
`implementerissue: 52`), and exits 1 with the reason on stderr when it writes
nothing. A bad `--issue` still pins the role and skips only the issue line.
The docs run it as `bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/role-marker.sh" …`.
With the plugin root unset, or stale (the cache keeps plugin versions side by
side, so after a mid-session update it can name one without the script), START
and EPIC skip the pin and the notify record and say why, while the guards
retry a failed read by the path the Glob tool finds (a failed read is never
clearance), as `/role` does for all its commands. Skipping the
pin is a regression from the inline snippets, which pinned with only
`CLAUDE_CODE_SESSION_ID`. The hooks take the session id from
their input, so they don't run the script; they source its helper,
`scripts/marker-lib.sh`, for the roles directory, the id check, and the
first-line role read.

The subagent guard changed with it. It used to infer a marker write from
command text (a session-id variable, the roles directory, and a write, all in
one command), which missed a path carried over from an earlier command and
falsely denied harmless commands such as a grep redirected to a file. Now a
subagent's Bash call is denied when it names `role-marker.sh` (or a variable
set to it) followed by any word but `show`, anywhere outside quotes and
heredocs, unless that word is a path or an option; the file-edit check on the
roles directory stays. Review shaped that rule. A first version required the
script to be in a command position (a command word, or the argument of bash,
env and the like), and review kept finding positions it missed (an `if`
condition, a `case` branch, an option's operand before the script), so the
position test was dropped. A second listed the writing subcommands, and
review kept finding ways to hide one (`{pin,}`, `&>/dev/null pin`), so the
list became an allow-list of `show`, which also covers a writing subcommand
added later. Its cost is a false deny when the path and a plain word are only
data to another command (`cp …/role-marker.sh backup`).
The docs show no hand-written marker write, so a subagent would have to
improvise one to get past the guard: that leftover risk was accepted.

**Update (#217):** a freshly pinned planner skipped its charter. Asked to "add
that to AGENTS.md", it ran a skill whose job is writing AGENTS.md, entered a
worktree and wrote the file, and only the `Write` hit the edit gate. The guard
worked but fired at the third step, so three changes move it earlier:

- **A `UserPromptSubmit` hook** (`hooks/role-prompt-reminder.sh`). The charter
  enters context at SessionStart and when `/role` reads it, which can be turns
  before the request it governs. For a marker whose first line is `planner` or
  `epic-coordinator`, the hook prints one line, which Claude Code adds to the
  prompt's context, with the tier's actor test: a request to fix, add, change
  or build something names an outcome, so hand it down (a planner files it and
  runs `/spawn-epic` or `/spawn-tickets`; a coordinator re-briefs the child
  that owns it, or files it and runs `/spawn-tickets`), unless the owner names
  the session itself or runs the command for it there (`/start-ticket`, which
  matters since a slash command fires `UserPromptSubmit` too). An implementer,
  no marker, an unknown role, and a missing or unsafe session id print
  nothing. Every prompt pays for the line, so it stays one line, and the hook
  starts no jq: a bash regex reads the session id (the input has no nested
  objects, and a JSON string can't hold the unescaped quotes the pattern needs,
  so the prompt can't supply a match), `marker-lib.sh` checks it and reads the
  role, and the line goes out as plain stdout. It never reads the prompt text.
- **`EnterWorktree` is gated for a planner.** The matcher gains
  `EnterWorktree`, and `role-guard.sh` asks for `planner:EnterWorktree` as it
  does for the edits. Planner-only: no other tier's documented flow needs it
  gated, and checked against `SKILL.md` and `phases/epic.md`, every temporary
  worktree outside START (EPIC's, the FINISH intro's) goes through
  `git worktree add` in Bash. Only START, an implementer's phase, calls
  `EnterWorktree`. The gate catches the route the incident took
  (`EnterWorktree` by name, which also creates the worktree). A worktree made
  with `git worktree add` in Bash, as START makes its own, isn't gated, since
  gating a planner's Bash stays out of scope. There the edit gate is still the
  first prompt, and the reminder is what moves the decision earlier.
- **The planner gates carry one line for the model.** An `ask`'s
  `permissionDecisionReason` is shown only in the prompt, so a rejected call
  told the model only "The user doesn't want to proceed with this tool use".
  PreToolUse also accepts `additionalContext`. Checked on Claude Code 2.1.293
  in a `claude -p` run whose `--permission-prompt-tool` denied the call (the
  headless stand-in for a human's rejection): the transcript carries the
  context as a `hook_additional_context` attachment ahead of the rejected
  tool result, and the model quoted it, while the reason never reached it.
  The attachment is recorded when the hook runs, before the prompt is
  answered, and the docs place it beside the tool result when the call runs,
  so it should arrive either way; only the rejected path was run. A second
  run, calling `EnterWorktree`, showed PreToolUse firing for it under that
  tool name, with the same result. Both planner gates now attach `Pinned
  planner: … If they approved it, go ahead. If they rejected it, don't retry
  it or make the change another way: file the work … and hand it down …`. The
  implementer's deny needs none, since a deny's reason reaches the model. Only
  2.1.293 was checked; the plugin otherwise runs on older CLIs too.

A smoke test on 2.1.293 (one Opus run each, so consistent with the change, not
proof of it): a headless session pinned as planner and asked to "add a line
saying hello to notes.md" read the file, called `Edit` and hit the gate
without the reminder. With it, the session only located the file, made no
edit, and answered with the actor test.

### Which tiers pin

- **planner** — always via `/role planner`; it's the tier with no spawn edge.
- **spawned tiers** — self-pin on adoption: START Step 1 / EPIC Step 1 write
  the marker themselves when they adopt a `Role:` directive (#36; originally
  this was an optional `/role <role>` follow-up), so every tier is
  compaction-proof, not just the planner.

## Verified mechanisms (claude-code docs, 2026-07-08)

- All hooks receive `session_id` (and `cwd`, `transcript_path`) on stdin.
- SessionStart stdout is injected as context; fires on
  `startup`/`resume`/`clear`/`compact` (the `source` field distinguishes).
- `CLAUDE_ENV_FILE`: SessionStart-only, `export KEY=value` lines, vars visible
  to all subsequent Bash tool calls.
- PreToolUse decision schema: `hookSpecificOutput.permissionDecision` ∈
  `allow|deny|ask|defer`.
- Rejected en route: `CLAUDE_SESSION_ID` is not natively in Bash env (hence
  the env-file export); `UserPromptSubmit` does not fire for slash commands
  (`UserPromptExpansion` does), so no prompt-sniffing hook. (No longer so on
  Claude Code 2.1.293, checked headless for #217: a slash command fires
  `UserPromptExpansion` and then `UserPromptSubmit`. #217's
  `UserPromptSubmit` hook ignores the prompt and only adds a reminder.)
- Plugin hook packaging: `plugins/<name>/hooks/hooks.json`, paths via
  `${CLAUDE_PLUGIN_ROOT}` (idiom confirmed against official plugins).

## Alternatives rejected

- **`CLAUDE_ROLE` env var + `plan()` shell wrapper** — dead on arrival for
  sessions launched from `claude agents`; env propagation through `claude
  --bg` was also unverified.
- **Hard deny for planner edits** — fights the attached human; `ask` gives the
  same unattended protection at one keystroke of interactive cost.
- **Guarding mutating Bash** — false-positive-prone (planners shell out
  constantly); scope stays lateral-drift-into-editing.
- **Separate `roles` plugin** — YAGNI while roles are a ticket-workflow
  concept; charters and hooks live together in that plugin.
- **Mid-session `/role` as context-only (no marker)** — wouldn't survive
  compaction and couldn't drive a guard; the marker is what makes it real.

## Testing

Smoke-tested by piping crafted hook payloads (isolated
`CLAUDE_SESSION_ROLES_DIR`): planner+Edit → `ask`; planner+Bash, other roles,
no marker → allow; marker+charter → injection on resume; env-file gets both
exports; no-marker startup silent. Behavioral pass (reviewer, optional):
`/role planner`, attempt an edit, expect a permission prompt; `/role none`,
edit flows freely.
