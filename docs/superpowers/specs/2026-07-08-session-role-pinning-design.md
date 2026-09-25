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
that compacts or is `/clear`ed keeps pinging its spawner instead of dropping to
the poll. The name is whitelisted (letters, digits, spaces, `._:#/()@+,-`, at
most 100 characters) by both the writer and the hook, since the hook prints it
into context. The alternative considered was the PR body. It was rejected
because reading it back depends on the session remembering to look, which is
what compaction breaks, and because there is no PR before START Step 7, when a
long implementation may already have compacted. The marker is re-injected
without the session doing anything.

### Which tiers pin

- **planner** — always via `/role planner`; it's the tier with no spawn edge
  and the only one with a guard.
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
  (`UserPromptExpansion` does), so no prompt-sniffing hook.
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
