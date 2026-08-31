# Ticket Workflow Harness Portability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ticket-workflow's role, resource, messaging, inspection, epic-spawn, and attribution behavior portable between Claude Code and Codex without duplicating generic spawn or managed-worktree lifecycle logic.

**Architecture:** Select a ticket-workflow harness adapter beside the existing tracker and profile adapters. Generic `spawn` from #63 remains the only launcher; harness references own the remaining runtime-specific session/task mechanics, while the EPIC phase moves to a read-on-demand file to keep the main skill focused.

**Tech Stack:** Markdown agent skills and commands, Claude Code hook shell scripts/JSON, JSON plugin manifest, pytest-backed behavioral pressure fixtures with fresh agent runs.

**Spec:** `docs/superpowers/specs/2026-08-31-ticket-workflow-harness-portability-design.md`

## Global Constraints

- Base this work on `codex/63-inherit-caller-harness`; generic spawn owns launch selection and native task/session creation.
- Keep issue #64's managed-worktree detection, reuse, and cleanup implementation out of this branch; integrate its final vocabulary after rebase if needed.
- Preserve tracker/profile semantics and the complete `SPAWN_CAP`/role directives.
- Codex must never invoke `claude` CLI commands or use `~/.claude/session-roles`.
- Unsupported parity is explicit: Codex has prompt-durable roles but no plugin hook/edit guard, and no reverse notifier without a known parent thread ID.
- Bump ticket-workflow from the #63 base version `0.13.0` to feature version `0.14.0`.
- Do not merge, deploy, publish, or reinstall the plugin during START.

---

### Task 1: Harness Portability Behavioral Fixture

**Files:**
- Create: `plugins/ticket-workflow/tests/harness-portability-scenarios.md`

**Interfaces:**
- Consumes: the #63-base ticket-workflow skill, commands, role files, messaging guide, and hooks.
- Produces: fresh-context scenarios scored on observable resource lookup, role state, launch delegation, messaging/inspection controls, and attribution.

- [ ] **Step 1: Run the failing baseline scenarios**

Dispatch fresh read-only agents against the #63 base for at least these cases:

1. A Codex implementer receives `Role: implementer`, then must locate the charter and explain persistence without using Claude paths or variables.
2. A Codex planner launches an epic and later inspects/steers a child.
3. A Codex START run drafts a PR body and chooses generated-agent attribution.
4. A Claude Code local coordinator repeats the role and messaging cases to prove existing behavior is preserved.

Expected RED: Codex cases search guessed package paths, write/test Claude role state, emit `claude --bg`/`claude agents`, use `SendMessage` addressing, or produce Claude Code attribution.

- [ ] **Step 2: Record the fixture and evaluator contract**

Write `harness-portability-scenarios.md` with input context, expected decisions, and pass/fail observations. Score runtime behavior rather than exact prose: selected resource origin, touched state path, launch owner, identifier type, inspection/message operation, and footer.

- [ ] **Step 3: Commit the RED fixture**

```bash
git add plugins/ticket-workflow/tests/harness-portability-scenarios.md
git commit -m "[#65] (Codex + GPT-5.6) ticket-workflow: capture harness portability regressions"
```

### Task 2: Shared Harness Contract and Role/Message Adapters

**Files:**
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/SKILL.md`
- Create: `plugins/ticket-workflow/skills/ticket-workflow/harnesses/claude.md`
- Create: `plugins/ticket-workflow/skills/ticket-workflow/harnesses/codex.md`
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/messaging.md`
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/roles/planner.md`
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/roles/epic-coordinator.md`
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/roles/implementer.md`
- Modify: `plugins/ticket-workflow/commands/role.md`
- Modify: `plugins/ticket-workflow/hooks/hooks.json`
- Modify: `plugins/ticket-workflow/hooks/role-session-start.sh`
- Modify: `plugins/ticket-workflow/hooks/role-guard.sh`

**Interfaces:**
- Consumes: active runtime identity and the selected skill root.
- Produces: `RESOURCES`, `ROLE_STATE`, `IDENTITY`, `MESSAGE`, `INSPECT`, and `ATTRIBUTION` operations with explicit Claude/Codex behavior.

- [ ] **Step 1: Add harness selection to Step 0**

Document that the active runtime selects `harnesses/claude.md` or
`harnesses/codex.md` before tracker/profile work. Distinguish this from generic
spawn's launch override. Require all support resources to resolve relative to
the active `SKILL.md` package; a missing resource stops the phase instead of
triggering an ad-hoc filesystem search.

- [ ] **Step 2: Write the Claude adapter**

Move the existing Claude-specific contracts into one reference:

- role markers keyed by `$CLAUDE_SESSION_ID` and reinjected by hooks;
- local `SendMessage`/`ListAgents` names, handles, and confirm-with-ref;
- cloud polling degradation;
- Claude task/session inspection controls; and
- Claude Code PR attribution.

Link to existing generic spawn backends rather than copying launch commands.

- [ ] **Step 3: Write the Codex adapter**

Specify relative skill-resource reads, prompt-durable role adoption without a
marker/edit guard, stable `threadId` + `hostId` addressing, queued
`clientThreadId` limits, native list/read/wait/follow-up/navigation controls,
poll-based parent observation, and Codex attribution. Explicitly prohibit
Claude CLI commands, Claude marker paths, title-based addressing, and invented
reverse notification when the parent thread ID is unknown.

- [ ] **Step 4: Route role adoption and `/role` through `ROLE_STATE`**

Replace the inline marker snippet in START/EPIC with the adapter operation. The
role command validates the same four values but delegates persistence/clear and
charter lookup. Claude keeps its marker behavior; Codex applies or clears the
charter only in current task context and reports the missing mechanical guard.

- [ ] **Step 5: Make messaging and role charters harness-aware**

Keep state-change vocabulary and durable-record rules shared. Move Claude
address confirmation and cloud limits into the Claude adapter; describe Codex
native follow-up plus poll fallback in the Codex adapter. Update role files to
say "task/work item" generically and point helper/inspection mechanics to the
active harness rather than `claude --bg`, attach handles, or `ListAgents`.

- [ ] **Step 6: Label hooks as the Claude implementation**

Preserve executable behavior while making comments/descriptions explicit that
the hooks implement Claude `ROLE_STATE` only. Do not add Codex filesystem state
or a fake Codex hook.

- [ ] **Step 7: Run GREEN role/resource/message scenarios**

Re-run Task 1's resource and role scenarios against both adapters. Expected:
Codex touches no Claude state and reports its limitations; Claude retains
marker reinjection, edit guard, and local messaging behavior.

- [ ] **Step 8: Commit the adapter layer**

```bash
git add plugins/ticket-workflow/skills/ticket-workflow plugins/ticket-workflow/commands/role.md plugins/ticket-workflow/hooks
git commit -m "[#65] (Codex + GPT-5.6) ticket-workflow: add harness session adapters"
```

### Task 3: Harness-Neutral Epic Routing and Phase Split

**Files:**
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/SKILL.md`
- Create: `plugins/ticket-workflow/skills/ticket-workflow/phases/epic.md`
- Modify: `plugins/ticket-workflow/commands/spawn-epic.md`

**Interfaces:**
- Consumes: generic spawn named-unit contract from #63 and active harness `INSPECT` operations.
- Produces: an EPIC phase with no hardcoded launcher or inspection backend and a thin `/spawn-epic` generic-spawn unit.

- [ ] **Step 1: Extract EPIC without semantic changes**

Move the full `## EPIC phase` through `### EPIC does NOT` block into
`phases/epic.md`. Replace it in `SKILL.md` with an index that says to read the
phase file completely before acting and summarizes only its routing purpose.
Verify internal START/FINISH/SPAWN step references still resolve.

- [ ] **Step 2: Replace EPIC child launch commands**

Describe each wave as named generic spawn units carrying the exact issue prompt,
`SPAWN_CAP`, base/worktree directives, and `Role: implementer`. Remove
`claude --bg` and durable-launch-directory mechanics; generic spawn owns those.
Keep deterministic branch/lifecycle semantics as references to #64's contract,
not a new implementation.

- [ ] **Step 3: Replace EPIC inspection commands**

Use `INSPECT` for task/session liveness, logs/status, waits, and redirects.
Continue grounding START-complete decisions in PR base, checks, and review
threads. Preserve tracker `COORD` markers as the durable shared state.

- [ ] **Step 4: Route `/spawn-epic` through generic spawn**

Build one unit with name `<repo> <epic-id>: epic — <desc>` and prompt
`/start-epic <full arguments> Role: epic-coordinator`. Pass any explicit harness
override as launch metadata, never child prompt text. Delegate stable ID and
inspect/open reporting to generic spawn.

- [ ] **Step 5: Run GREEN spawn/epic scenarios**

Re-run the Codex epic scenario and a Claude local control. Expected: generic
spawn selects the launch harness, Codex returns task IDs/native controls,
Claude keeps session handles/controls, and neither ticket path duplicates the
launcher.

- [ ] **Step 6: Commit the phase routing**

```bash
git add plugins/ticket-workflow/skills/ticket-workflow/SKILL.md plugins/ticket-workflow/skills/ticket-workflow/phases/epic.md plugins/ticket-workflow/commands/spawn-epic.md
git commit -m "[#65] (Codex + GPT-5.6) ticket-workflow: route epic work through active harness"
```

### Task 4: Attribution, Documentation, and Release Metadata

**Files:**
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/SKILL.md`
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/trackers/github.md`
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/trackers/jira.md`
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/profiles/default.md`
- Modify: `plugins/ticket-workflow/.claude-plugin/plugin.json`
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: completed harness adapter behavior.
- Produces: active-harness PR attribution, neutral examples/terminology, an installable feature version, and repository guidance matching the split skill layout.

- [ ] **Step 1: Route PR attribution and neutralize examples**

Replace the literal Claude Code footer in START with `ATTRIBUTION`. Update
tracker commit examples to use the repository commit-conventions contract
rather than hardcoding Claude. Audit profile prose for session/launcher claims
that now belong to adapters.

- [ ] **Step 2: Update repository documentation**

Document that ticket-workflow can execute from Claude Code or Codex while the
marketplace remains Claude-packaged. Update `CLAUDE.md`'s skill-size section to
record the EPIC extraction and future split rule, plus the #63/#64 integration
boundary where it helps future contributors.

- [ ] **Step 3: Bump the plugin version**

Change `plugins/ticket-workflow/.claude-plugin/plugin.json` from `0.13.0` to
`0.14.0`. Do not change marketplace version fields because the plugin manifest
is authoritative.

- [ ] **Step 4: Parse changed YAML and JSON**

```bash
jq empty plugins/ticket-workflow/.claude-plugin/plugin.json
uv run --with pyyaml python3 -c 'import pathlib, yaml; expected={"plugins/ticket-workflow/commands/role.md":"<planner | epic-coordinator | implementer | none>","plugins/ticket-workflow/commands/spawn-epic.md":"<epic-id> [briefing] [--finish] [--coordinate | --team | --independent] [--harness codex|claude]"}; [(lambda path, want: (_ for _ in ()).throw(AssertionError((path, want))) if yaml.safe_load(pathlib.Path(path).read_text().split("---", 2)[1]).get("argument-hint") != want else None)(path, want) for path, want in expected.items()]; print("frontmatter ok")'
```

- [ ] **Step 5: Run full verification**

```bash
uvx pytest -q
uv run --with pyyaml python3 /Users/mario/.codex/skills/.system/skill-creator/scripts/quick_validate.py plugins/ticket-workflow/skills/ticket-workflow
git diff --check
```

Run the complete behavioral fixture with fresh agents. Review
`git diff codex/63-inherit-caller-harness...HEAD` and confirm no #64 lifecycle
implementation, no generic spawn launcher duplication, and no unresolved
Claude-specific mechanics outside the Claude adapter/hooks or historical docs.

- [ ] **Step 6: Commit release documentation**

```bash
git add plugins/ticket-workflow/.claude-plugin/plugin.json plugins/ticket-workflow/skills/ticket-workflow README.md CLAUDE.md
git commit -m "[#65] (Codex + GPT-5.6) docs: release portable ticket workflow sessions"
```

### Task 5: Stack Integration, Review, and START Completion

**Files:**
- No planned file changes; any later edit must be limited to a path already
  listed above and justified by verified #63/#64 integration or a concrete
  review finding.

**Interfaces:**
- Consumes: final #63 and #64 branch/PR state plus automated review feedback.
- Produces: a pushed stacked PR with green CI and zero unresolved review threads.

- [ ] **Step 1: Rebase onto final #63 head**

Fetch the #63 branch and rebase non-interactively. Resolve only #65 overlap;
preserve #63's generic launcher as authoritative.

- [ ] **Step 2: Integrate #64 vocabulary if available**

Inspect #64's final diff. If it changes START's worktree directives or cleanup
ownership, adapt #65 references without copying its implementation. If #64 is
not ready, record the integration dependency prominently in the PR body.

- [ ] **Step 3: Verify commit subjects and diff markers**

```bash
git log --oneline codex/63-inherit-caller-harness..HEAD
git diff codex/63-inherit-caller-harness...HEAD
git diff --check
```

Confirm every commit matches `[#65] (<flags>) <scope>: <description>` and no
hold/debug markers remain.

- [ ] **Step 4: Push and open the stacked PR**

Push `codex/65-harness-portability`; open the PR with base
`codex/63-inherit-caller-harness`, title
`ticket-workflow: abstract session mechanics across harnesses (#65)`, a
`Closes #65` footer, test evidence, and explicit #63/#64 integration notes.

- [ ] **Step 5: Complete automated review and CI**

Request/detect Copilot, address each thread with a new CRC commit when code or
prose changes are warranted, reply and resolve every thread, and repeat until
the unresolved-thread query is empty. Watch all checks to green; if the repo has
no checks, record that verified state rather than inventing a gate.

- [ ] **Step 6: Hand back without merging**

Report the PR URL, stack base, #64 integration status, non-trivial review
feedback, tests, and CI. Stop for Mario's review; do not merge or deploy.
