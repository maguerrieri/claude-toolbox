# Repository Instructions Convention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `AGENTS.md` the conventions plugin's canonical shared repository-instruction file, with a pure `CLAUDE.md` import shim and clear migration guidance.

**Architecture:** Add one self-contained, automatically discoverable `repo-instructions` reference skill beside `commit-conventions`. Keep the policy in that skill, update the existing commit skill and marketplace README to point to it, and bump the conventions plugin's minor version so installed copies receive the new behavior.

**Tech Stack:** Markdown skills with YAML frontmatter, JSON plugin manifests, shell-based structural validation, and the bundled Codex skill validator.

**Spec:** [GitHub issue #68](https://github.com/maguerrieri/claude-toolbox/issues/68)

## Global Constraints

- Root `AGENTS.md` is the canonical source for shared, harness-neutral instructions.
- Root `CLAUDE.md` is a pure compatibility shim whose entire content is `@AGENTS.md`.
- Harness-specific mechanics belong in harness-owned surfaces such as `.claude/` and `.codex/`.
- Nested instruction files must be described conservatively because harness support differs.
- Codex fallback filenames are migration aids, not portable repository contracts.
- Update ticket-workflow's repository-directive discovery to consume this policy; leave #65's broader harness/session portability work and unrelated repository migrations out.
- Bump `plugins/conventions/.claude-plugin/plugin.json` from `0.1.1` to `0.2.0`.

---

### Task 1: Capture failing policy checks

**Files:**
- Inspect: `plugins/conventions/skills/commit-conventions/SKILL.md`
- Inspect: `plugins/conventions/skills/repo-instructions/SKILL.md`
- Inspect: `plugins/conventions/.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: issue #68 acceptance criteria.
- Produces: a reproducible RED result showing that the new skill is absent, the commit skill still names `CLAUDE.md` as canonical, and the plugin is still version `0.1.1`.

- [ ] **Step 1: Run the pre-implementation structural check.**

  ```bash
  test -f plugins/conventions/skills/repo-instructions/SKILL.md
  ! rg -n "repo's own CLAUDE.md" plugins/conventions/skills/commit-conventions/SKILL.md
  test "$(jq -r .version plugins/conventions/.claude-plugin/plugin.json)" = "0.2.0"
  ```

  Expected: FAIL before implementation because the skill is missing and the old policy/version remain.

### Task 2: Implement the conventions policy

**Files:**
- Create: `plugins/conventions/skills/repo-instructions/SKILL.md`
- Modify: `plugins/conventions/skills/commit-conventions/SKILL.md`
- Modify: `plugins/conventions/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `README.md`

**Interfaces:**
- Consumes: the policy constraints in issue #68.
- Produces: discoverable `conventions:repo-instructions` guidance, a canonical override pointer in `commit-conventions`, accurate marketplace discoverability text, and plugin version `0.2.0`.

- [ ] **Step 1: Author the new skill.** Cover the baseline file pair, pure-shim compatibility rationale, shared versus harness-owned content, migration sequence, always-loaded context versus on-demand skills, fallback-setting limits, conservative nested-file guidance, and first-party links.
- [ ] **Step 2: Update `commit-conventions`.** Replace the `CLAUDE.md` canonical-override wording with `AGENTS.md`, while pointing readers to the compatibility policy.
- [ ] **Step 3: Update discoverability and release metadata.** Mention both conventions skills in the marketplace description and README, then bump `0.1.1` to `0.2.0`.
- [ ] **Step 4: Parse both skill frontmatters.** Assert their exact `name` and non-empty string `description` values with PyYAML.

### Task 3: Adopt the convention in ticket-workflow

**Files:**
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/SKILL.md`
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/profiles/default.md`
- Modify: `plugins/ticket-workflow/skills/ticket-workflow/trackers/jira.md`
- Modify: `plugins/ticket-workflow/commands/start-ticket.md`
- Modify: `plugins/ticket-workflow/.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: `conventions:repo-instructions` canonical/fallback policy.
- Produces: project memory → canonical `AGENTS.md` → legacy/shim `CLAUDE.md` directive discovery without changing ticket-workflow's broader session or adapter mechanics.

- [ ] **Step 1: Capture the RED state.** Confirm ticket-workflow still names repo `CLAUDE.md` as its primary shared directive source and remains version `0.11.0`.
- [ ] **Step 2: Update directive discovery and adjacent documentation.** Make `AGENTS.md` canonical, retain `CLAUDE.md`/`.claude/CLAUDE.md` compatibility fallbacks, and update the command, Jira adapter, profile guidance, docs checks, and stack-convention wording consistently.
- [ ] **Step 3: Bump ticket-workflow to `0.12.0`.** This is a new repository-instruction discovery capability.
- [ ] **Step 4: Validate the plugin and assert no primary-source wording remains.** Keep legacy/fallback mentions where they are intentional.

### Task 4: Verify behavior, docs, and package shape

**Files:**
- Verify: `plugins/conventions/skills/repo-instructions/SKILL.md`
- Verify: `plugins/conventions/skills/commit-conventions/SKILL.md`
- Verify: `plugins/conventions/.claude-plugin/plugin.json`
- Verify: `.claude-plugin/marketplace.json`
- Verify: `README.md`
- Verify: `plugins/ticket-workflow/**`

**Interfaces:**
- Consumes: Tasks 2–3's finished plugin surfaces.
- Produces: evidence that the convention is valid, concise, discoverable, and consumed by ticket-workflow with the intended fallback behavior.

- [ ] **Step 1: Re-run the structural check.** Expected: PASS.
- [ ] **Step 2: Run the bundled skill validator.** Run `quick_validate.py` against both conventions skill folders. Expected: both valid.
- [ ] **Step 3: Validate JSON.** Parse the plugin manifest and marketplace, assert version `0.2.0`, and assert the marketplace description mentions repository instructions.
- [ ] **Step 4: Manually evaluate representative decisions.** Confirm the guidance yields: new repo → canonical root `AGENTS.md` plus pure shim; conflicting files → reconcile before reducing the shim; Claude-only rule → `.claude/` surface; required every-session guidance → repository instructions rather than a skill; nested scope → check harness behavior rather than claiming portability.
- [ ] **Step 5: Inspect the diff.** Confirm ticket-workflow changes are limited to repository-directive discovery/documentation, no unrelated repositories changed, and no documentation touched by the diff remains stale.

### Task 5: Publish the reviewed PR

**Files:**
- Commit: all files from Tasks 1–3.

**Interfaces:**
- Consumes: a verified issue #68 diff.
- Produces: an open PR based on `main`, with green CI and no unresolved automated-review threads.

- [ ] **Step 1: Commit with the conventions skill.** Use `[#68] (Codex + GPT-5) conventions: Make AGENTS.md canonical repository instructions`.
- [ ] **Step 2: Push `68-canonical-repo-instructions` and open a PR.** Use a `Closes #68` footer and document the manual policy scenarios in the test plan.
- [ ] **Step 3: Run the review-bot cycle.** Address or explain every thread, resolve it, and re-request/recheck as needed.
- [ ] **Step 4: Wait for CI green.** Stop at the reviewed PR; do not merge or deploy.
