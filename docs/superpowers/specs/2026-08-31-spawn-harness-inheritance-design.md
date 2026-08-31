# Spawn Harness Inheritance Design

## Context

Issue #63 fixes a routing bug in which a spawn initiated from Codex falls through
to `claude --bg`. The work is stacked on #57 / PR #58, which already introduces
Claude's independent local-versus-cloud backend selection. This design adds the
orthogonal harness axis without reimplementing that backend work.

## Scope

The generic `spawn` skill selects a harness before it selects any
environment-specific launch backend:

1. Consume an explicit `--harness codex|claude` override, or an equally explicit
   natural-language request.
2. Otherwise inherit the active execution harness.
3. Read exactly one harness adapter.
4. Let that adapter launch, report its stable identifier, and provide its own
   inspection controls.

An unavailable explicitly selected harness is a launch error. The workflow
reports the missing native capability and stops; it never falls back to another
harness because that would violate the user's explicit choice.

## Routing Model

Harness and backend remain separate axes:

| Harness | Default detection | Launch routing |
|---|---|---|
| Codex | Codex thread/session runtime or native Codex task tools | Native Codex task creation |
| Claude | Claude Code session runtime | Claude harness adapter, then #57's local/cloud backend selection |

The Claude harness adapter owns no launch mechanics. It evaluates #57's existing
`CLAUDE_CODE_REMOTE_SESSION_ID` predicate and reads either
`backends/local.md` or `backends/cloud.md`.

The Codex harness adapter uses the native task APIs. For repository work it
resolves the saved project first and creates an isolated worktree task when the
project is a Git repository; otherwise it uses the supported local/projectless
target. It preserves the user's configured model and reasoning settings unless
the request explicitly overrides them. The stable task/thread ID and Codex
sidebar/open controls replace Claude session handles and CLI attach commands.

## Ticket Workflow Integration

The ticket workflow continues to own only ticket semantics:

- parse issue IDs and briefing text;
- append `SPAWN_CAP` and `Role: implementer`;
- construct the full `/start-ticket` prompt and short task name;
- consume the harness override as launch metadata; and
- pass each unit to generic `spawn`.

`--harness` is never forwarded into the spawned `/start-ticket` prompt. Both
`/spawn-tickets` and `/make-ticket --spawn` use the same delegation path. The
ticket skill does not duplicate task creation, backend detection, identifiers,
or inspection instructions.

EPIC cloud execution, Claude cloud source propagation, and cross-session
messaging are outside #63. PR #58 remains authoritative for Claude's backend
axis.

## Validation

A checked-in behavioral fixture covers:

- Codex and Claude default inheritance;
- Claude local and cloud backend preservation;
- both explicit cross-harness selections, including unavailable-tool failure;
- generic and ticket spawn reporting contracts; and
- preservation of ticket caps, roles, and prompt text.

Fresh-context agents run the scenarios before and after the skill changes. JSON
manifests and YAML frontmatter are parsed, all repository tests run, and the
skill is validated with the available skill validator.
