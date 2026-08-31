# Spawn Harness Inheritance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make generic and ticket spawn inherit the caller's harness by default while supporting explicit cross-harness selection.

**Architecture:** Add a harness router above PR #58's Claude backend router. Harness adapters own native launch/report mechanics; ticket-workflow only constructs bounded units and delegates them to generic spawn.

**Tech Stack:** Markdown agent skills and commands, JSON plugin manifests, pytest behavioral fixtures exercised by fresh-context agents.

**Spec:** `docs/superpowers/specs/2026-08-31-spawn-harness-inheritance-design.md`

## Global Constraints

- Branch from PR #58's `claude/workflow-spawn-cloud-sessions-0filuk` branch.
- Keep #57's Claude local/cloud backend behavior intact.
- Do not add EPIC cloud support, publishing, deployment, or merge behavior.
- Consume harness overrides as launch metadata; never forward them to child task prompts.

---

### Task 1: Behavioral Harness Fixture

**Files:**
- Create: `plugins/spawn/tests/harness-routing-scenarios.md`

**Interfaces:**
- Consumes: the current spawn and ticket-workflow instructions.
- Produces: pressure scenarios with observable launcher, identifier, reporting, and prompt-preservation expectations.

- [ ] **Step 1: Run failing baseline scenarios**

Dispatch fresh read-only agents against the Codex-default, cross-harness override,
and Codex ticket-spawn cases. Expected RED: the current instructions select
`claude --bg` in all three cases.

- [ ] **Step 2: Add the scenario fixture**

Record the routing matrix and evaluator protocol in
`plugins/spawn/tests/harness-routing-scenarios.md` so later skill edits can be
pressure-tested against the same observable contract.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers plugins/spawn/tests/harness-routing-scenarios.md
git commit -m "[#63] (Codex + GPT-5.6) spawn: specify caller-harness inheritance"
```

### Task 2: Generic Spawn Harness Router

**Files:**
- Modify: `plugins/spawn/skills/spawn/SKILL.md`
- Create: `plugins/spawn/skills/spawn/harnesses/claude.md`
- Create: `plugins/spawn/skills/spawn/harnesses/codex.md`
- Modify: `plugins/spawn/commands/spawn.md`

**Interfaces:**
- Consumes: optional `--harness codex|claude`, active runtime identity, and `(prompt, desc)` units.
- Produces: exactly one selected harness adapter, native task/session handles, and harness-specific inspection controls.

- [ ] **Step 1: Add the harness router**

Place selection before launch: explicit override first, otherwise current
harness. Reject invalid or ambiguous selections and never silently cross
harnesses.

- [ ] **Step 2: Add the Claude adapter**

Delegate unchanged to #57's `backends/local.md` or `backends/cloud.md` based on
`CLAUDE_CODE_REMOTE_SESSION_ID`.

- [ ] **Step 3: Add the Codex adapter**

Use native Codex task creation, select the saved project and isolated worktree
target for Git repositories, preserve configured model/reasoning defaults, and
report task IDs plus sidebar/open/inspection controls.

- [ ] **Step 4: Update the command wrapper**

Add the explicit harness argument and point the command at harness selection,
without duplicating adapter mechanics.

- [ ] **Step 5: Run GREEN pressure scenarios**

Fresh agents evaluate every generic-spawn case in the fixture. Expected GREEN:
default inheritance and explicit overrides select the requested adapter; target
capability absence reports an error rather than falling back.

- [ ] **Step 6: Commit**

```bash
git add plugins/spawn/skills plugins/spawn/commands
git commit -m "[#63] (Codex + GPT-5.6) spawn: inherit the active harness"
```

### Task 3: Ticket Spawn Delegation

**Files:**
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/SKILL.md`
- Modify: `plugins/ticket-workflow/commands/spawn-tickets.md`
- Modify: `plugins/ticket-workflow/commands/make-ticket.md`

**Interfaces:**
- Consumes: issue IDs, optional briefing, profile `SPAWN_CAP`, role directive, and optional harness override.
- Produces: generic spawn units whose prompts contain ticket semantics but no harness flag.

- [ ] **Step 1: Make SPAWN harness-neutral**

Remove duplicated Claude backend examples and reporting instructions. Document
the exact unit handed to generic spawn and let the selected harness adapter own
launching, identifiers, and inspection controls.

- [ ] **Step 2: Route command overrides**

Teach `/spawn-tickets` and `/make-ticket --spawn` to consume and pass the
explicit harness selection to generic spawn while preserving the child prompt.

- [ ] **Step 3: Run ticket pressure scenarios**

Fresh agents evaluate `/spawn-tickets` and `/make-ticket --spawn` from Codex and
with explicit Claude selection. Expected: caps, roles, and full briefings remain
in the child prompt; launch metadata stays outside it.

- [ ] **Step 4: Commit**

```bash
git add plugins/ticket-workflow/skills plugins/ticket-workflow/commands
git commit -m "[#63] (Codex + GPT-5.6) ticket-workflow: delegate harness selection"
```

### Task 4: Release Metadata and Verification

**Files:**
- Modify: `plugins/spawn/.claude-plugin/plugin.json`
- Modify: `plugins/ticket-workflow/.claude-plugin/plugin.json`
- Modify: `README.md`

**Interfaces:**
- Consumes: completed behavior changes.
- Produces: installable feature versions and user-facing documentation matching the new defaults.

- [ ] **Step 1: Update versions and README**

Bump `spawn` from `0.3.0` to `0.4.0` and `ticket-workflow` from `0.12.0` to
`0.13.0`. Describe harness inheritance without claiming EPIC cloud support.

- [ ] **Step 2: Parse and validate artifacts**

```bash
jq empty plugins/spawn/.claude-plugin/plugin.json plugins/ticket-workflow/.claude-plugin/plugin.json
uvx --from pyyaml python -c '<parse changed markdown frontmatter and assert exact values>'
uvx pytest -q
```

Run the available skill quick validator against both changed skill directories,
then rerun the full behavioral fixture with fresh agents.

- [ ] **Step 3: Review the stacked diff**

```bash
git diff origin/claude/workflow-spawn-cloud-sessions-0filuk...HEAD
git log --oneline origin/claude/workflow-spawn-cloud-sessions-0filuk..HEAD
```

Confirm the diff contains no #57 backend implementation and no EPIC cloud work.

- [ ] **Step 4: Commit**

```bash
git add plugins/spawn/.claude-plugin/plugin.json plugins/ticket-workflow/.claude-plugin/plugin.json README.md
git commit -m "[#63] (Codex + GPT-5.6) docs: release harness-aware spawning"
```
