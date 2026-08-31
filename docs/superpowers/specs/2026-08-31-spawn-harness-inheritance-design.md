# Spawn Harness Inheritance Design

## Context

Issue #63 fixes a routing bug in which a spawn initiated from Codex falls through
to `claude --bg`. The work is stacked on #57 / PR #58, which introduced Claude
local/cloud launch mechanics. This design puts those mechanics behind two
orthogonal routing axes without absorbing #57's unrelated cloud-backend work.

## Scope

The generic `spawn` skill selects a harness and execution surface before it
selects an adapter:

1. Consume an explicit `--harness codex|claude` override, or an equally explicit
   natural-language request.
2. Consume an explicit `--surface desktop|cli|cloud` override.
3. Record caller harness and surface as launch metadata.
4. Inherit both for same-harness launches. For a cross-harness launch, map a
   local caller (`desktop` or `cli`) to the target CLI, and a cloud caller to the
   target cloud, unless step 2 explicitly selected a surface.
5. Read exactly one harness adapter and one surface/backend adapter.
6. Let that adapter launch, report its stable identifier, and provide its own
   inspection controls.

An unavailable selected harness-plus-surface pair is a launch error whether the
pair was inherited, mapped, or explicit. The workflow names the missing pair and
stops; it never falls back to another harness or surface.

## Routing Model

Harness and execution surface are separate axes:

| Pair | Launch routing |
|---|---|
| Codex + desktop | Native Codex app task creation |
| Codex + CLI | Capability error until a durable nonblocking CLI session launcher exists |
| Codex + cloud | Native cloud capability plus an unambiguous environment, otherwise capability error |
| Claude + desktop | Capability error until a durable desktop adapter exists |
| Claude + CLI | PR #58 local backend (`claude --bg`) |
| Claude + cloud | PR #58 cloud backend when its native session launcher is available |

The Claude harness adapter owns no launch mechanics. The already-selected CLI or
cloud surface routes to #57's `backends/local.md` or `backends/cloud.md`.
Consequently Codex desktop can cross to Claude CLI, while an explicit Claude
cloud request cannot silently become a local CLI launch.

Surface selection does not waive adapter prerequisites. In particular, a cloud
caller explicitly selecting Claude CLI receives an exact-pair capability error:
starting `claude --bg` inside its disposable container would leave the user
without durable attach/list controls.

The Codex harness adapter uses the native task APIs. For repository work it
resolves the saved project first and creates an isolated worktree task when the
project is a Git repository; otherwise it uses the supported local/projectless
target. It preserves the user's configured model and reasoning settings unless
the request explicitly overrides them. The stable task/thread ID and Codex
sidebar/open controls replace Claude session handles and CLI attach commands.
The adapter appends `Worktree: current`; ticket START treats that reserved value
as an instruction to reuse the native Codex worktree rather than nest another
checkout. START carries that harness ownership through submodule setup and a
hidden PR marker; FINISH leaves worktree/branch cleanup to Codex. A queued
`clientThreadId` is reported only as setup state and a UI
directive target; thread-only read/message/navigation controls wait for the real
`threadId`.

## Ticket Workflow Integration

The ticket workflow continues to own only ticket semantics:

- parse issue IDs and briefing text;
- append `SPAWN_CAP` and `Role: implementer`;
- construct the full `/start-ticket` prompt and short task name;
- pass that exact name through the generic unit contract;
- request the existing local-only notifier as optional adapter metadata;
- consume both launch overrides as metadata; and
- pass each unit to generic `spawn`.

Neither `--harness` nor `--surface` is forwarded into the spawned
`/start-ticket` prompt. Both
`/spawn-tickets` and `/make-ticket --spawn` use the same delegation path. The
ticket skill does not duplicate task creation, backend detection, identifiers,
or inspection instructions.

The ticket layer passes a lazy notification request. The Claude adapter resolves
the spawner identity and applies `Notify:` only when both caller and target are
Claude CLI sessions in the same local messaging graph. Cloud, desktop, and
cross-harness edges omit it without a `ListAgents` lookup. The PR/tracker remains
the durable completion record everywhere.

EPIC cloud execution and Claude cloud source propagation are outside #63. PR
#58 remains authoritative for Claude's backend axis.

## Validation

A checked-in behavioral fixture covers:

- Codex and Claude harness-plus-surface inheritance;
- Claude CLI and cloud backend preservation;
- local cross-harness CLI mapping and explicit surface selection;
- unavailable-pair errors with no fallback;
- generic and ticket spawn reporting contracts; and
- preservation of ticket caps, roles, prompt text, exact names, native worktree
  reuse, local notification, and queued-identifier control boundaries.

Fresh-context agents run the scenarios before and after the skill changes. JSON
manifests and YAML frontmatter are parsed, all repository tests run, and the
skill is validated with the available skill validator.
