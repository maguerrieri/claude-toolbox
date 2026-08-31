# Harness: Claude Code

Use this adapter when the task currently executing ticket-workflow runs in
Claude Code. This selection describes the caller's runtime. It does not select
where generic `spawn` launches a child.

## RESOURCES

Treat the directory containing the active ticket-workflow `SKILL.md` as the
skill root. Read bundled support paths relative to that root: `roles/*.md`,
`messaging.md`, `harnesses/*.md`, `phases/*.md`, `trackers/*.md`, and bundled
`profiles/*.md`. When the package is opaque, use its resource reader with the
same relative path.

A required resource that cannot be read is a hard error for the current phase:
report the relative path and stop. Never recover by walking parent directories,
searching an installed-plugin cache, or guessing another copy of the package.

## ROLE_STATE

Valid `/role` values are `planner`, `epic-coordinator`, `implementer`, and
`none`. For `adopt` of a non-`none` role, validate the value, read
`roles/<role>.md` through `RESOURCES`, and adopt that charter as governing for
the current Claude session.

Claude's durable implementation is a marker keyed by `$CLAUDE_SESSION_ID`:

```bash
if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  roles_dir="${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}"
  mkdir -p "$roles_dir"
  printf '%s\n' "<role>" >"$roles_dir/$CLAUDE_SESSION_ID"
fi
```

The Claude-only SessionStart hook exports `CLAUDE_SESSION_ID`, re-injects a
marked charter after startup/resume/clear/compaction, and refreshes the marker.
The Claude-only PreToolUse hook turns file edits into an approval prompt while
`planner` is marked. These hooks are a drift guard, not a security boundary.

If `$CLAUDE_SESSION_ID` is unset, do not construct or write a marker path.
Report that the charter governs only the current context and that restarting a
Claude session lets SessionStart initialize durable state.

- `persist` writes the validated non-`none` role to the current session marker.
- `clear` removes that marker when the session ID exists and stops applying the
  charter in the current context.
- `report` returns the validated marker role when available, otherwise the role
  governing the current context and its non-durable limitation.

For an invalid or empty value, report the four valid values and the current
state when safely available; do not change state.

## IDENTITY

For local Claude work, a human-readable session name is a display label and the
spawn-reported handle/agentId is the durable address that survives renames. For
Claude cloud work, use the server-returned session ID as the durable address.
Do not interchange local handles, cloud session IDs, names, or Codex task IDs.

Generic `spawn` owns `LAUNCH`. For its exact creation, isolation, and reporting
mechanics, use the generic spawn skill's Claude harness router, which delegates
to `backends/local.md` or `backends/cloud.md`; do not copy either launcher into
ticket-workflow.

## MESSAGE

Read `messaging.md` for the shared state-change vocabulary and durable-record
rules.

- **Local Claude edge:** `SendMessage` is available. Address the receiver by the
  known name or durable handle. If a bare name is rejected pending
  confirmation, use `ListAgents` and resend to the exact `name [ref]` form.
  Local spawn edges may carry `Notify: <name-or-handle>`.
- **Claude cloud edge:** `ListAgents`/`SendMessage` cannot reach the sibling in
  either direction. Emit no `Notify:` directive. Poll the cloud session status
  and the durable PR/tracker state instead.

Messages are hints. Verify every state transition against PRs, issues, and
tracker `COORD` markers before acting.

## INSPECT

- **Local:** `claude agents` lists work; `claude logs "<name-or-handle>"` reads
  it; `claude attach "<name-or-handle>"` opens or steers it. In scripts use
  `claude agents --json` because the bare command needs a TTY.
- **Cloud:** use `list_sessions` to list and `get_session(<session-id>)` to read
  status. Open the Claude Code web task to inspect details that status omits.

Use the durable ID returned by generic `spawn`; names are only display labels.

## ATTRIBUTION

Use this generated-agent footer on PRs and other generated artifacts:

```markdown
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```
