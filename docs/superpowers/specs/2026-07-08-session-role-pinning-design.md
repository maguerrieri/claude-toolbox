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

### Which tiers pin

- **planner** — always via `/role planner`; it's the tier with no spawn edge
  and the only one with a guard.
- **spawned tiers** — don't need pinning (their charter arrives with every
  (re-)briefing), but MAY `/role <role>` after adopting a directive to become
  compaction-proof.

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
