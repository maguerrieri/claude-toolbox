# Software factory — Design

**Date:** 2026-09-11
**Issue:** none yet — this spec is reviewed via PR first; the epic and child
issues below are filed once it's approved
**Status:** proposed

## Problem

`claude-toolbox` already ships the skeleton of a ticket-driven software
factory: `ticket-workflow` (START → PR → review-bot → CI → FINISH), `spawn`
(local `claude --bg` / cloud `create_session` fan-out), and the planner /
epic-coordinator / implementer role charters. `toolbox` consumes it as a
monorepo with a root `CLAUDE.md` plus per-project instruction files.

What's missing is the part that lets it run **unattended in cloud sessions**:

- no machine-checked definition of done — FINISH's gate greps for merge
  blockers but doesn't verify that tests, docs, and review actually happened;
- no per-ticket evidence, so there is no data to decide which classes of
  change can be trusted without a human;
- no risk classification on tickets;
- no repo-side permission boundaries (`toolbox/.claude/settings.json` has no
  `permissions` block at all);
- no branch rules distinguishing agent pushes from human pushes;
- cloud environments are created by hand in the claude.ai GUI and nothing in
  the repo records which environment a session should run in.

The intended outcome is a trust ladder: each rung below is unlocked by the one
under it, and the first rung produces the measurements that justify every later
one. The user acts as product owner at the top; implementers run in cloud
sessions with a bounded blast radius.

## Constraints and decisions

- **Layout stays hybrid.** Conventions and workflow live in `claude-toolbox`
  (the marketplace); product code lives in the `toolbox` monorepo with per-
  project instruction files. New repos only when a permissions or ownership
  boundary needs one.
- **Personal-first, Team-optional.** The user has both a Pro/Max personal
  account and a Team account. Everything below works on the personal account
  (Anthropic-hosted environments, `claude[bot]`/user identity through the git
  proxy). Team-only capabilities — self-hosted environments with per-session
  minted git tokens, organization-shared environments — are noted as optional
  upgrades, never as prerequisites.
- **Environments are GUI-only.** There is no API, CLI, or config-as-code path
  for Anthropic-hosted cloud environments (verified against the docs, below).
  So: keep them few (one per **execution tier** — implementer vs. coordinator,
  not one per risk class; the risk→tier mapping is in 2c), make each a thin
  pointer, and put everything else in the repo.
- **First auto-merge class is docs-only** (diff touches only `*.md` and
  `docs/**`).
- **No plugin behavior changes ride in this spec's PR.** Each child issue bumps
  the plugin it touches (the `plugin versions` CI check enforces it).

## Design

### Rung 1 — Evidence and gates (do first)

**1a. Evidence block in the PR body.** Extend the START Step 7 PR template in
`plugins/ticket-workflow/skills/ticket-workflow/SKILL.md` with an `## Evidence`
section. The block is a **record of what the session did, never an
authorization**: anything a gate decides on (CI state, review threads, risk
class, critic result) is re-derived from live, protected sources at gate time
(1b, 3b); the body only has to be present, well-formed, and free of
placeholders. It is fenced JSON (strict, one object, all scalars quoted) so a
checker can parse it without a YAML grammar:

```json
{
  "schema": "ticket-workflow/evidence/1",
  "tests": "uv run pytest plugins/x/tests -q (passed)",
  "docs": "no doc impact",
  "context_reads": ["AGENTS.md", "plugins/ticket-workflow/profiles/default.md"],
  "session": "cse_01…",
  "role": "implementer",
  "wall_clock_min": "23",
  "critic": "not run"
}
```

Required keys: `schema`, `tests`, `docs`, `context_reads`, `session`, `role`,
`wall_clock_min`. `tests` and `docs` must be non-empty and must not match the
placeholder set (`TODO`, `TBD`, `<…>`, `n/a` without a reason). `critic` is
added in rung 3. Exactly one `## Evidence` block per PR; duplicates fail.

**1b. Machine-checked FINISH gate.** FINISH Step 1 gains
`plugins/ticket-workflow/scripts/check-evidence.sh <pr>` (same idiom as
`.github/scripts/check-plugin-versions`). It fails (exit non-zero) when any of
these holds, each checked against the **current head**, not the body:

1. `gh pr checks <pr>` reports any non-success check on the head SHA;
2. the paginated `reviewThreads` GraphQL query (the one `REVIEW_BOT` already
   uses) returns any unresolved thread;
3. the linked issue carries no `risk:<class>` label (from 1c) — the body's
   text is never consulted for risk;
4. the Evidence block is absent, duplicated, malformed, or fails the
   required-key / placeholder rules in 1a.

The step stays report-and-stop, never auto-fix, matching the rest of the gate.
A shell test under the plugin exercises: green + complete (pass), red check,
unresolved thread, missing label, missing block, placeholder `tests`.

**1c. Risk label on tickets.** `/make-ticket` accepts
`--risk docs|low|normal|high`; the GitHub tracker adapter applies a
`risk:<class>` label. Today the adapter's `--label` is best-effort (retries
without the label if it doesn't exist), which would silently drop the class.
So: (i) the four `risk:*` labels are provisioned once per repo
(`gh label create`, recorded with the rulesets in 1d); (ii) for `--risk`
specifically, a missing label is a **hard error** surfaced to the user, not a
silent retry — the adapter's `CREATE` grows a `required_labels` argument. The
gate (1b) reads the class from the issue label; the Evidence block does not
carry it. No behavior change beyond labeling — this is the data rung 3
consumes.

**1d. Branch rulesets on both repos** (manual, one-time, done alongside 1a).
Two rulesets on `main`, kept separate so 3b can bypass one without the other:

| Ruleset | Rules | Bypass actors |
|---|---|---|
| `main-integrity` | require PR; require the repo's CI checks; block force-push and deletion | none |
| `main-review` | require 1 approving review; dismiss stale approvals | *(none until 3b; then only the auto-merge App)* |

Agent-pushable branch patterns must match what the workflow actually
generates, not just cloud-session defaults: `claude/**` (cloud sessions),
`issue-*` and `[0-9]*-*` (the GitHub `BRANCH` adapter), `epic-*` (EPIC). A
third ruleset, `agent-branches`, targets those patterns and permits creation
and push by the actors named in 2d, and nothing else is restricted there.
The `risk:*` labels (1c) are provisioned in the same manual step. The exact
ruleset JSON is recorded here once applied so it's reproducible.

### Rung 2 — Identity and boundaries

**2a. Blast radius is credentials + network, not command names.** The
security boundary for an unattended implementer is what its session *can
reach*, in this order:

1. **Credentials.** Sessions hold no deploy credentials. The only GCP identity
   in a cloud session is the existing read-only `logs-viewer` service account;
   deploys happen in GitHub Actions on merge, never from a session. API keys
   for services a project calls go in the environment's API credentials
   (proxy-attached, invisible to the session) scoped to read-only endpoints
   where the provider offers them.
2. **Network.** The environment allowlist (2b) admits only the hosts the tier
   needs; an implementer that can't reach the Cloud Run API can't deploy by
   any spelling of the command.
3. **Git.** Rulesets (1d) bound what a push can do.

Repo-side `permissions` in `.claude/settings.json` are then **ergonomics and
drift control**, not the boundary: allow the repos' own test/lint/`terraform
plan` commands (seeded with `/fewer-permission-prompts`) so implementers don't
stall on prompts, and deny `terraform apply`, `gcloud run deploy`,
`firebase deploy`, and un-leased force-pushes so a drifting session fails fast
and legibly. The existing role-guard hook is explicitly a nudge ("not a
security control", `hooks/role-guard.sh`) and stays that way. Add the block
to `toolbox/.claude/settings.json` (currently absent) and extend
`claude-toolbox/.claude/settings.json`.

**2b. Two cloud environments** (manual, one-time, personal account):

| Environment | Network | Setup script |
|---|---|---|
| `factory-implementer` | Trusted + the hosts a project needs (GCP APIs for log reading) | `bash .claude/cloud-setup.sh` |
| `factory-coordinator` | None beyond GitHub + Anthropic | none |

The setup script body lives in git. In `toolbox`, the plugin-install and
gcloud-activation steps move from `.claude/hooks/session-start.sh` into a
committed `.claude/cloud-setup.sh` (setup script = VM provisioning, cached;
SessionStart hook = per-session state such as the `CLOUDSDK` env unset). The
cache only rebuilds when the environment's own script or allowlist changes, so
the in-repo script must be idempotent and a stale cache is expected after
edits. If the Team account is used later, the same two definitions become
organization-shared environments; nothing else changes.

**2c. Environment selection in-repo.** Commit `remote.defaultEnvironmentId`
in each repo's project settings pointing at `factory-implementer`. The `spawn`
cloud backend passes `environment_id` explicitly from a new `Environment:`
briefing directive so a coordinator can pin children to a tier; ticket-
workflow's SPAWN Step 3 forwards it. Risk class → tier mapping:

| `risk:` | Runs unattended? | Environment |
|---|---|---|
| `docs`, `low`, `normal` | yes (merge gating differs per rung 3) | `factory-implementer` |
| `high` | no — START runs, but FINISH is always human-invoked and the session is interactive | `factory-implementer` |
| coordinators / planners | n/a | `factory-coordinator` |

Risk changes *who may finish*, not *where the code runs*; there is no
per-class network difference today, so two environments suffice.

**2d. Identity.** Verified against the docs: on Anthropic-hosted sessions the
git proxy authenticates *ordinary user sessions* as the session creator, and
*bot and agent sessions* (routines, Auto-fix, Claude Tag) with the GitHub App
installation token — those are the PRs that appear as `claude[bot]`. The
identity is not selectable per session on a personal plan, and per-session
minted tokens exist only in self-hosted environments (Team/Enterprise).
Therefore:

1. Rulesets bind both actors (the user and the `claude` app) identically.
2. Prefer launch paths that yield `claude[bot]`-authored PRs where they
   occur: a distinct author lets the user's own review satisfy "1 approval".
3. A spike issue confirms which launch paths produce `claude[bot]` on the
   personal account, and whether routines (`/schedule` + API fire) can be the
   standard implementer launcher for that reason.
4. **Team-account option:** a self-hosted environment with a wrapper script
   that mints a short-lived, least-scoped GitHub App installation token per
   session (`--capacity 1`, ephemeral container). This is the cleanest least-
   privilege story and is the one path that gives true per-session tokens.
   It's an optional rung-2 upgrade for repos that live under the Team org; it
   cannot serve personal repos, so the personal path above remains primary.

**2e. Budgets.** A `Budget:` briefing directive (wall-clock minutes, max
review rounds) is appended in `profiles/default.md`'s `SPAWN_CAP`; an
implementer stops and reports when exceeded instead of looping.

### Rung 3 — Risk classes and first auto-merge

**3a. Critic pass.** New profile op `REVIEW_CRITIC`: after the review-bot loop,
an adversarial reviewer examines the diff and its verdict is published as a
**GitHub check run** named `factory/critic` on the head SHA (`gh api
repos/…/check-runs`, conclusion `success` only when it found nothing
blocking). The Evidence block's `critic` key records that it ran; gates read
the check run, never the body. The reviewer is an explicit dependency, not an
assumption: the profile names the plugin that provides it, both repos declare
that plugin in `.claude/settings.json` (cloud sessions install project-declared
plugins; user-level `~/.claude` does not carry over), and if the skill is
unavailable the op **fails closed** — no check run is posted, so 3b can never
match. The default profile enables it for `risk:docs` and above.

**3b. Docs-only auto-merge.** Three parts, each independently checkable.

*Predicate.* Every input is a protected or immutable source:

- risk: the linked issue's `risk:docs` label (1c), read via the API;
- paths: the PR's changed-file list from the API matches an explicit
  **inert allowlist**, not "anything `*.md`": `docs/**`, `**/README.md`,
  `**/CHANGELOG.md`. Instruction and workflow files are excluded by
  construction — `AGENTS.md`, `CLAUDE.md`, `.claude/**`, `plugins/**`
  (SKILL.md, commands, hooks, profiles), `.github/**` — because in this
  repository "docs" can change the factory itself;
- CI: all required checks green on the head SHA;
- critic: `factory/critic` check run on the head SHA with `success` (3a);
- Evidence block well-formed (1a) — presence only, never trusted for state.

*Merge path.* A `docs-auto-merge` GitHub Actions workflow on `pull_request`
(`types: [labeled, synchronize]` plus `check_suite: completed`) that:

- runs only when `github.event.pull_request.head.repo.full_name ==
  github.repository` — same-repo branches only; the factory never pushes from
  forks, and this keeps the job off the `pull_request_target` footgun;
- performs **no checkout** and executes nothing from the PR — it reads the
  changed-file list, labels, checks, and the critic check run through the API
  and calls the merge endpoint;
- authenticates for the merge call with a short-lived installation token
  minted from a dedicated, minimal GitHub App (`factory-auto-merge`:
  permissions `contents: write`, `pull_requests: write`, installed only on
  these repos). `GITHUB_TOKEN` is not used for the merge, because it cannot
  satisfy the review ruleset.

*Ruleset compatibility.* `main-review` (1d) requires one approving review and
an Actions job cannot supply one. The `factory-auto-merge` App is added as the
**only** bypass actor on `main-review`; `main-integrity` (PR required, CI
required) keeps no bypass actors, so even the App cannot merge red CI. The
App's private key lives only in the repo's Actions secrets, so the bypass is
exercisable solely by that workflow. This is the compatible policy: humans
keep the review requirement, and the one unattended path is a narrowly scoped
App bypass whose predicate is enforced server-side in the workflow.

`SPAWN_CAP` lifts for `risk:docs` only, and only in the sense that FINISH may
*label* the PR `auto-merge: requested`; the workflow decides.

**3c. Metrics.** A weekly routine tallies Evidence blocks on merged PRs — review
rounds, reverts, critic findings per risk class — and posts the table as a
comment on the epic. This is the input for widening classes in rung 4.

### Rung 4 — Spec-driven planning

The planner role drafts a spec into `docs/superpowers/specs/` from a one-
paragraph intent, waits for approval, then `/spawn-epic`s it. Auto-merge
classes widen (`low`: test-only, version-only bumps) when rung 3 metrics show
zero reverts over a window the user chooses.

## Work items (filed as epic children after this spec is approved)

| # | Item | Rung | Deps |
|---|---|---|---|
| 1 | Evidence block (JSON contract) in START PR template | 1a | — |
| 2 | `check-evidence.sh` FINISH gate (live checks/threads/label + block validation) + tests | 1b | 1, 3 |
| 3 | `--risk` flag, `required_labels` in `CREATE`, `risk:*` label provisioning | 1c | — |
| 4 | Rulesets (`main-integrity`, `main-review`, `agent-branches`) on both repos; record JSON in this spec | 1d | — |
| 5 | Repo `permissions` blocks | 2a | — |
| 6 | `cloud-setup.sh`, two environments, `remote.defaultEnvironmentId` | 2b, 2c | 5 |
| 7 | `Environment:` directive through spawn and SPAWN | 2c | 6 |
| 8 | Spike: which launch paths yield `claude[bot]` on the personal account | 2d | — |
| 9 | `Budget:` directive in `SPAWN_CAP` | 2e | 1 |
| 10 | `REVIEW_CRITIC` profile op posting the `factory/critic` check run; plugin dependency declared in both repos | 3a | 2 |
| 11 | `factory-auto-merge` GitHub App + `main-review` bypass + `docs-auto-merge` workflow (no checkout, same-repo only, inert-path allowlist) | 3b | 3, 4, 10 |
| 12 | Metrics routine | 3c | 1 |
| 13 | Planner spec-drafting flow | 4 | 11, 12 |
| 14 | *(optional, Team)* self-hosted environment with per-session tokens | 2d | 4 |

## Verified mechanisms (code.claude.com docs, 2026-09-11)

- Cloud environments are created and edited only from the environment selector
  at claude.ai/code, the Desktop app, or the admin **Cloud environments** page
  for shared ones; no API/CLI. Each has a network level, `.env`-style
  variables, an optional setup script, and (Pro/Max) API credentials.
- What carries over into a cloud session from the repo: `.claude/settings.json`
  hooks, `.claude/rules/`, skills/agents/commands, and plugins declared in
  project settings. User-level `~/.claude` does not.
- Setup script runs after clone and before Claude Code launches; the resulting
  filesystem snapshot is cached and rebuilt only when the script or allowlist
  changes or after ~7 days.
- `/remote-env` writes `remote.defaultEnvironmentId` to user settings; a repo's
  project settings can set the same key at higher precedence.
- Git proxy identity: "For ordinary user sessions, the proxy uses the GitHub
  … OAuth token stored for the session creator; for bot and agent sessions, it
  uses your organization's GitHub App installation token."
- Per-session minted git tokens: self-hosted environments only (Team and
  Enterprise, public beta), via the runner wrapper script with `--capacity 1`.
- Routines: created via web, Desktop, or `/schedule`; API trigger fires via
  `POST …/routines/<id>/fire` with a bearer token; GitHub triggers on
  `pull_request` and `release` events. Runs are full cloud sessions with no
  permission prompts, so environment + connectors + repos are the whole
  boundary.

## Alternatives rejected

- **Ralph-style single loop as the whole factory.** Cheap and resilient to
  context rot, but no cross-step planning and no evidence trail; kept only as
  a possible inner loop for the implementer tier.
- **Separate bot GitHub account now.** Requires redoing the GitHub connection
  and Auto-fix; `claude[bot]` already exists for agent launch paths and
  rulesets can bind both actors. Revisit only if the spike (item 8) shows no
  personal launch path yields a distinct author.
- **Build identity/boundaries (rung 2) before evidence (rung 1).** Feels like
  the safety work, but every later trust decision needs rung 1's data, and the
  branch-ruleset half of rung 2 is an hour that rides along with rung 1.
- **Self-hosted environments as the primary path.** Team-only; personal repos
  cannot use it. Kept as an optional upgrade (item 14).
- **Treating the Evidence block as authorization.** A PR body is editable by
  the author after START; a gate that reads `ci: green` from it is trivially
  bypassed. Gates re-derive state from checks, review threads, issue labels,
  and check runs; the block is a record only.
- **Command-name deny lists as the blast-radius control.** Lexical denies are
  bypassable by a different spelling or a raw HTTP call; the boundary is
  credentials and network (2a). Denies stay for fast, legible failure.
- **`*.md` as the docs-only class.** In this repo Markdown *is* the workflow
  (`AGENTS.md`, `plugins/**/SKILL.md`); an explicit inert-path allowlist is
  used instead (3b).
- **`GITHUB_TOKEN` for the auto-merge.** Cannot satisfy a required-review
  ruleset and would force either a global bypass or dropping the review rule;
  a dedicated minimal App as the single bypass actor on the review ruleset
  keeps the integrity ruleset bypass-free.

## Testing

- Rung 1: run `/start-ticket` on a docs-only issue from a cloud session;
  confirm the PR body carries a well-formed Evidence block; run
  `/finish-ticket` and confirm the gate passes. Then on a scratch PR: strip
  the block (stops), put `"tests": "TODO"` (stops), leave one review thread
  unresolved (stops), remove the `risk:` label (stops), and edit the body to
  claim green while a check is red (stops — the body is not consulted).
- Rung 1 rulesets: an agent push to `issue-123-x` and `epic-1-2` succeeds; a
  direct push to `main` is rejected; a PR with no approval cannot merge.
- Rung 2: spawn two implementers from a coordinator session; confirm they land
  in `factory-implementer`, cannot run a deploy command, and their PRs are
  blocked on `main` without a review.
- Rung 3: a `risk:docs` PR touching only `docs/**` with green CI and a
  `success` critic check run merges via the workflow with no human approval;
  the same PR with a `failure` critic run does not; a PR that also touches
  `AGENTS.md` or `plugins/**` does not; a fork PR does not; editing the PR
  body to add `"critic": "clean"` changes nothing.
