# Ticket Workflow Harness Portability Design

## Context

Issue #65 removes Claude Code-specific session mechanics from ticket-workflow's
otherwise harness-neutral phases. The work is stacked on #63, whose generic
`spawn` harness router already owns native task/session creation, launch-time
harness selection, stable child identifiers, and harness-specific inspection
controls. Ticket-workflow must consume that contract rather than build another
launcher.

Issue #64 remains the owner of managed-worktree detection, reuse, and cleanup.
This change may consume its final lifecycle vocabulary after integration, but it
does not define or duplicate that behavior.

## Harness Adapter Dimension

Tracker, engineering profile, and execution harness are three orthogonal
dimensions:

| Dimension | Owns | Does not own |
|---|---|---|
| Tracker | issue operations, branch/reference syntax, coordination records | build policy or session mechanics |
| Profile | tests, docs, review bot, release and safety policy | tracker or session mechanics |
| Harness | skill-resource lookup, role persistence, task identity, messaging, follow-up/inspection, attribution | ticket semantics, launch routing, or worktree lifecycle |

At Step 0 the active runtime selects exactly one ticket-workflow harness adapter:
`harnesses/claude.md` or `harnesses/codex.md`. This active-harness selection is
not generic spawn's optional launch override: a Codex caller that explicitly
launches a Claude child still executes the parent workflow through the Codex
adapter.

The adapter contract has six operations:

- `RESOURCES` — locate files relative to the active `SKILL.md`; never search
  guessed package roots.
- `ROLE_STATE` — adopt, persist, clear, and report the current role with the
  strongest mechanism the harness supports.
- `IDENTITY` — represent the current task/session and child addresses.
- `MESSAGE` — send supported state-change notifications or declare the poll
  fallback when no reverse channel is addressable.
- `INSPECT` — read/wait/steer child work using native controls.
- `ATTRIBUTION` — render the generated-agent footer for PRs and other artifacts.

Generic `spawn` remains authoritative for `LAUNCH`; ticket-workflow passes it a
complete named unit and consumes the adapter-specific identifier/report it
returns.

## Resource Resolution

Every support path is relative to the selected ticket-workflow skill root:
`roles/*.md`, `messaging.md`, `harnesses/*.md`, `phases/*.md`, tracker adapters,
and profiles. A filesystem-backed skill resolves against the directory that
contains `SKILL.md`; a runtime with an opaque skill package uses that package's
resource reader. Failure to read a required resource is an explicit error. An
agent must not walk parent directories or search an installed plugin cache for
a guessed copy.

This directly addresses the observed Codex run that looked under the package
root even though `roles/implementer.md` was correctly packaged under the skill.

## Role State

Claude Code retains the existing durable marker and hook implementation:
`$CLAUDE_SESSION_ID`, `${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}`,
SessionStart charter reinjection, and the planner PreToolUse edit guard. Those
hooks are explicitly labeled as the Claude adapter's implementation.

Codex has no equivalent plugin hook or writable per-thread environment contract.
It adopts the charter from `Role:` in the task prompt (or a manual role request)
for the current task and relies on task history/context preservation. It must not
write `~/.claude/session-roles`, test `$CLAUDE_SESSION_ID`, or claim that the
planner edit guard is armed. The limitation is explicit: Codex role state is
prompt-durable within the task but has no out-of-band marker or mechanical edit
guard; every spawned/forked task therefore receives its own `Role:` directive.

The `/role` command routes through `ROLE_STATE`. `none` clears the current
harness's supported state; on Codex it stops applying the charter in the current
task without pretending to delete a marker that does not exist.

## Task Identity, Messaging, and Inspection

Claude local sessions keep names/handles plus `SendMessage`/`ListAgents`, with
the existing confirm-with-ref behavior. Claude cloud edges continue to degrade
to polling, as #57 specifies.

Codex uses `threadId` plus `hostId` for ready tasks and treats a
`clientThreadId` only as queued setup state. Parent-to-child steering uses native
task follow-up controls; listing, reading, waiting, and navigation use native
task controls. Titles are display labels, never addresses.

Codex task creation currently does not expose the caller's own `threadId` to the
generic spawn unit, so a child cannot reliably address its parent. Codex edges
therefore carry no reverse `Notify:` directive by default. The parent observes
progress with native wait/read controls and verifies durable PR/tracker state.
If a future runtime supplies an explicit parent thread ID, the adapter may add a
stable task-address directive without changing ticket semantics.

All notifications remain hints. PRs, issues, and tracker `COORD` markers are the
durable record on both harnesses.

## Spawn and Epic Routing

SPAWN continues to build `/start-ticket` units and hand them to generic `spawn`.
This change extends the same rule to the remaining Claude-specific paths:

- `/spawn-epic` builds one named `/start-epic ... Role: epic-coordinator` unit
  and delegates launch/reporting to generic `spawn`.
- EPIC wave scheduling builds named child units and delegates every wave to
  generic `spawn`; it never emits `claude --bg` commands.
- EPIC aggregation uses the active harness adapter for task/session inspection,
  while PR state remains the completion authority.

Deterministic branch/worktree directives used for stacking remain part of issue
#64's lifecycle contract. If #64 changes their representation, this branch must
rebase and adopt it before #65 is merged.

## Attribution and Terminology

PR templates request `ATTRIBUTION` from the active harness:

- Claude Code: `Generated with Claude Code` and its existing link.
- Codex: `Generated with Codex`.

Shared prose says "task" or "work item" when the concept spans harnesses.
Adapter-specific instructions may say Claude "session" or Codex "task". The
repository remains a Claude plugin marketplace, so packaging paths such as
`.claude-plugin/plugin.json` are not renamed merely because the workflow can run
from Codex.

## Skill Layout

The #63 base leaves ticket-workflow's `SKILL.md` at 576 lines. The repository
guidance says a phase-sized addition beyond the 500-line marker should trigger a
read-on-demand split, extracting EPIC first. This change therefore moves the
complete EPIC phase to `phases/epic.md`. `SKILL.md` retains Step 0, invocation
discipline, shared adapter contracts, START/FINISH/SPAWN, and an EPIC index that
requires reading the phase file before execution.

## Validation

A checked-in behavioral fixture will exercise fresh agents against these
observable scenarios:

- support resources resolve from the active skill root without cache searching;
- Claude and Codex role adoption use only their own state mechanisms;
- Codex never emits Claude CLI/session commands or Claude role paths;
- `/spawn-epic` and EPIC child waves delegate to generic `spawn`;
- Claude local messaging remains functional while Claude cloud and Codex use
  explicit polling fallbacks;
- task/session identifiers are not interchanged, especially queued Codex IDs;
- PR attribution matches the active harness; and
- tracker/profile selection and ticket safety caps are unchanged.

The final gate also parses changed YAML frontmatter and JSON manifests, runs the
repository test suite and skill validator, and records manual scenario results.

## Integration and Release

This PR is stacked on #63 (and therefore #57) because generic harness-aware
launch is a prerequisite. It must be rebased after #63 review changes. Issue #64
runs independently and may overlap START worktree wording; before review is
complete, rebase or manually integrate #64's final lifecycle contract without
bringing its implementation into this issue.

The ticket-workflow plugin receives a minor version bump from #63's `0.13.0` to
`0.14.0`. No plugin is published, deployed, or merged as part of START.
