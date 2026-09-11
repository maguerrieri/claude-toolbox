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
`wall_clock_min`. `schema` must equal exactly `ticket-workflow/evidence/1`;
any other value, including a newer version the checker doesn't know, is
rejected (the checker carries the list of versions it supports). `tests` and
`docs` must be non-empty and must not match the placeholder set (`TODO`,
`TBD`, `<…>`, `n/a` without a reason). `critic` is added in rung 3. Exactly
one `## Evidence` block per PR; duplicates fail.

**1b. Machine-checked FINISH gate.** FINISH Step 1 gains
`plugins/ticket-workflow/scripts/check-evidence.sh <pr>` (same idiom as
`.github/scripts/check-plugin-versions`). It fails (exit non-zero) when any of
these holds, each checked against the **current head**, not the body:

1. `gh pr checks <pr>` reports any non-success check on the head SHA;
2. the paginated `reviewThreads` GraphQL query (the one `REVIEW_BOT` already
   uses) returns any unresolved thread;
3. the linked issue does not carry **exactly one** `risk:<class>` label (from
   1c) — zero or two-plus labels both fail; the body's text is never
   consulted for risk;
4. the label is `risk:high` and FINISH was not invoked with `--confirm-high`.
   That flag is a human-only authorization: SPAWN, EPIC, and `/spawn-epic`
   already strip merge-intent flags from what they forward to children, and
   `--confirm-high` joins that strip list, so no spawned or orchestrated
   session can ever carry it. This is the fail-closed high-risk gate the
   tier table in 2c relies on;
5. the Evidence block is absent, duplicated, malformed, or fails the
   required-key / schema / placeholder rules in 1a.

The step stays report-and-stop, never auto-fix, matching the rest of the gate.
A shell test under the plugin exercises: green + complete (pass), red check,
unresolved thread, missing label, two risk labels, `risk:high` without the
flag, missing block, wrong schema version, placeholder `tests`.

**1c. Risk label on tickets.** `/make-ticket` accepts
`--risk docs|low|normal|high`, **defaulting to `normal`** when omitted so a
new ticket can always reach FINISH; the GitHub tracker adapter applies a
`risk:<class>` label. Legacy open issues are backfilled once with
`risk:normal` in the same manual step that provisions the labels (item 3), so
the gate in 1b never strands an existing ticket; a closed issue is never
touched. On these personal repos every collaborator is a trusted actor, so
label edits are trusted operations; the gate's "exactly one label" rule is
what turns an accidental second label into a stop rather than a downgrade. Today the adapter's `--label` is best-effort (retries
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
| `factory-implementer` | Trusted + the hosts a project needs (GCP APIs for log reading) | see below |
| `factory-coordinator` | None beyond GitHub + Anthropic | none |

The setup script body lives in git, but the environment must never execute
the **checked-out branch's** copy: cloud children can be launched with a PR
branch as `source_revision`, so a PR could edit `.claude/cloud-setup.sh` and
run arbitrary code with the implementer's credentials before Claude starts.
The GUI-side script is therefore three lines that run the protected copy:

```bash
# factory-implementer setup script (v1)
git -C "$CLAUDE_PROJECT_DIR" fetch --depth=1 origin main
git -C "$CLAUDE_PROJECT_DIR" show origin/main:.claude/cloud-setup.sh | bash
```

`main` is protected by the rulesets in 1d, so only reviewed code reaches the
provisioning step regardless of which revision the session checked out. In
`toolbox`, the plugin-install and gcloud-activation steps move from
`.claude/hooks/session-start.sh` into that committed script (setup script =
VM provisioning, cached; SessionStart hook = per-session state such as the
`CLOUDSDK` env unset).

**Cache staleness is a known, bounded gap.** The snapshot rebuilds only when
the GUI-side script or allowlist changes, or after ~7 days; a commit to
`cloud-setup.sh` on `main` does not invalidate it. Two mitigations, both
recorded in the work item: (i) `cloud-setup.sh` must be idempotent and
re-runnable, and the SessionStart hook runs its cheap `--verify` mode each
session (checks the installed plugin versions and the gcloud account, and
prints a loud `SETUP STALE` line if they differ from what `main` declares) so
staleness is visible, never silent; (ii) the one manual step after a
`cloud-setup.sh` change is bumping the `(v1)` comment in the GUI script,
which forces a rebuild. If the Team account is used later, the same two
definitions become organization-shared environments; nothing else changes.

**2c. Environment selection in-repo.** Two mechanisms, because two launchers
exist:

- `claude --cloud` from a terminal reads `remote.defaultEnvironmentId`; commit
  it in each repo's project settings pointing at `factory-implementer`.
- The `spawn` cloud backend today omits `environment_id` (inherits the
  parent's). It gains an explicit `environment_id` sourced from a new
  `Environment:` briefing directive, and the repo's `AGENTS.md` config block
  (the same block that carries `Tracker:` / `Profile:`) gains two lines,
  `Implementer environment: env_…` and `Coordinator environment: env_…`.
  ticket-workflow's SPAWN Step 3 emits `Environment: <implementer>` on every
  child, and `/spawn-epic` emits `Environment: <coordinator>` on the
  `/start-epic` session it launches — so the coordinator tier is selected by
  the launcher, not by whatever the parent happened to run in. A session
  started by hand for coordination picks `factory-coordinator` in the
  environment selector; that is the one manual case and it's documented in
  the role charter.

Risk class → tier mapping:

| `risk:` | Runs unattended? | Environment |
|---|---|---|
| `docs`, `low`, `normal` | yes (merge gating differs per rung 3) | `factory-implementer` |
| `high` | START runs unattended; FINISH requires `--confirm-high`, which only a human can supply (1b) | `factory-implementer` |
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

**3a. Critic pass.** The critic's verdict must be a **GitHub check run** on
the head SHA that only a trusted actor can post. Creating check runs requires
App authentication, and the implementer session's git identity is a user
token, so the critic does not run inside the session. It runs as a
`factory-critic` GitHub Actions workflow with the same trust shape as the
merge workflow in 3b: triggered on `pull_request_target` (workflow YAML is
loaded from the **base** branch, so a PR cannot alter it), **no checkout**,
diff fetched through the API, reviewed by `claude -p` with the review skill,
and a `factory/critic` check run posted with the job's `GITHUB_TOKEN`
(`checks: write`). Gates verify the check run's `app.slug == github-actions`
*and* that it belongs to the `factory-critic` workflow (`check_suite`
→ workflow name) on the exact head SHA, not merely its name and conclusion.

The profile op `REVIEW_CRITIC` is then the session-side half: START's Step 8
waits for `factory/critic` alongside `gh pr checks`, treats a `failure` like
any other red check (fix and push, or stop and report), and records `critic:
ran` in the Evidence block. Item 10 is not just a new profile section: the
op is added to the enumerated op list in `profiles/default.md` and SKILL.md
Step 0, START gets the dispatch point, and the fail-closed path (workflow
missing or skill unavailable → no check run → 3b never matches) is tested.
The default profile enables it for `risk:docs` and above.

**3b. Docs-only auto-merge.** Three parts, each independently checkable.

*Predicate.* Every input is a protected or immutable source, and all of them
must hold for one captured head SHA:

- base: `base.ref == main` — the only branch the rulesets protect; a docs PR
  targeting an agent or feature branch never auto-merges;
- opt-in: the PR carries the `auto-merge: requested` label, which FINISH
  applies for `risk:docs` PRs. It is a required predicate input, not
  narrative — without it the workflow exits without merging;
- risk: the linked issue carries exactly one `risk:*` label and it is
  `risk:docs` (1c), read via the API;
- paths: the PR's changed-file list, **fully paginated** (follow `Link`
  headers until exhausted; if the count disagrees with the PR's
  `changed_files` field, fail closed), matches an explicit **inert
  allowlist**, not "anything `*.md`": `**/README.md`, `**/CHANGELOG.md`, and
  `docs/**` *excluding* `docs/superpowers/**` — specs and plans are the
  factory's design inputs (this very PR requires human approval before work
  is filed) and never auto-merge. Instruction and workflow files are excluded
  by construction — `AGENTS.md`, `CLAUDE.md`, `.claude/**`, `plugins/**`
  (SKILL.md, commands, hooks, profiles), `.github/**` — because in this
  repository "docs" can change the factory itself;
- CI: all required checks green on the head SHA;
- critic: `factory/critic` check run on the head SHA, `success`, posted by
  the `github-actions` app from the `factory-critic` workflow (3a);
- Evidence block well-formed (1a) — presence only, never trusted for state.

*Merge path.* A `docs-auto-merge` GitHub Actions workflow. Its trust model:

- **Trigger: `pull_request_target`** (`types: [labeled, synchronize]`) plus
  `check_suite: completed`. `pull_request_target` runs the workflow YAML from
  the **base branch** with base-branch secrets, so a PR cannot rewrite the job
  to exfiltrate the App key — which a plain `pull_request` trigger would allow
  on same-repo branches, since it loads YAML from the PR's merge ref. The
  usual `pull_request_target` hazard is checking out or executing PR code;
  this job does neither.
- **No checkout, nothing executed from the PR.** The job reads the
  changed-file list, labels, checks, and the critic check run through the API
  and calls the merge endpoint. No `actions/checkout`, no scripts from the
  tree.
- **Same-repo only.** On `pull_request_target`, `github.event.pull_request`
  is present: require `head.repo.full_name == github.repository`. On
  `check_suite`, the PR is not in `github.event.pull_request`; resolve it from
  `github.event.check_suite.pull_requests[]` (or, if empty, by querying PRs
  for `check_suite.head_sha`) and apply the same check to what the API
  returns. The factory never pushes from forks, so this excludes nothing
  legitimate.
- **Pinned SHA.** The job captures `head.sha` once, evaluates every predicate
  input against that SHA, and passes it as the merge endpoint's `sha`
  parameter; GitHub refuses the merge if the head moved after validation.
- **Credential.** The merge call uses a short-lived installation token minted
  from a dedicated, minimal GitHub App (`factory-auto-merge`), installed only
  on these repos, with permissions: `contents: write`, `pull_requests: write`
  (the two writes), `issues: read` (the risk label on the linked issue),
  `checks: read` (the critic run), `metadata: read` (implicit). `GITHUB_TOKEN`
  is not used for the merge, because it cannot satisfy the review ruleset.

*Ruleset compatibility.* `main-review` (1d) requires one approving review and
an Actions job cannot supply one. The `factory-auto-merge` App is added as the
**only** bypass actor on `main-review`; `main-integrity` (PR required, CI
required) keeps no bypass actors, so even the App cannot merge red CI. The
App's private key lives only in the repo's Actions secrets and is readable
only by base-branch workflows (the trigger choice above), so the bypass is
exercisable solely by that workflow. This is the compatible policy: humans
keep the review requirement, and the one unattended path is a narrowly scoped
App bypass whose predicate is enforced server-side.

`SPAWN_CAP` lifts for `risk:docs` only, and only in the sense that FINISH may
apply the `auto-merge: requested` label; the workflow decides.

**3c. Metrics.** A weekly routine derives per-risk-class metrics from
**immutable sources only**: review rounds from the PR's review and commit
timeline, critic outcomes from `factory/critic` check-run history, reverts
from `main`'s commit log (a commit whose subject or trailer references a
merged PR as reverted), and cost from the Evidence block's `wall_clock_min`
(the one field that is descriptive rather than a trust input). The Evidence
block is never the source for anything that widens a class. The routine posts
the table as a comment on the epic. This is the input for widening classes in
rung 4.

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
| 3 | `--risk` flag (default `normal`), `required_labels` in `CREATE`, `risk:*` label provisioning + one-time `risk:normal` backfill of open issues | 1c | — |
| 4 | Rulesets (`main-integrity`, `main-review`, `agent-branches`) on both repos; record JSON in this spec | 1d | — |
| 5 | Repo `permissions` blocks | 2a | — |
| 6 | `cloud-setup.sh` (+ `--verify` mode in the SessionStart hook), two environments running the `origin/main` copy, `remote.defaultEnvironmentId` | 2b, 2c | 5 |
| 7 | `Environment:` directive through spawn, SPAWN, and `/spawn-epic`; `Implementer environment:` / `Coordinator environment:` lines in the AGENTS.md config block | 2c | 6 |
| 7b | `--confirm-high` on FINISH, added to the merge-intent strip list in SPAWN/EPIC | 1b | 2, 3 |
| 8 | Spike: which launch paths yield `claude[bot]` on the personal account | 2d | — |
| 9 | `Budget:` directive in `SPAWN_CAP` | 2e | 1 |
| 10 | `factory-critic` workflow (`pull_request_target`, no checkout, posts `factory/critic`) + `REVIEW_CRITIC` op wired into the op list, Step 0, and START Step 8, with fail-closed test | 3a | 2 |
| 11 | `factory-auto-merge` GitHub App + `main-review` bypass + `docs-auto-merge` workflow (`pull_request_target`, no checkout, same-repo, pinned SHA, paginated inert-path allowlist, `base == main`, opt-in label) | 3b | 3, 4, 10 |
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
- **`pull_request` trigger for the privileged workflows.** Loads workflow YAML
  from the PR's merge ref, so a same-repo PR could rewrite the job and read
  the App key. `pull_request_target` with no checkout runs base-branch YAML
  and is safe precisely because nothing from the PR is executed.
- **Running the critic inside the implementer session.** Check runs require
  App auth the session doesn't have, and a session-posted verdict would be
  self-attested anyway. A base-branch workflow posts it.
- **Executing the branch copy of `cloud-setup.sh`.** A PR-branch child would
  run unreviewed code with implementer credentials; the environment runs the
  `origin/main` copy.

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
- Rung 2 setup script: a PR that edits `.claude/cloud-setup.sh` to print a
  marker, launched as a cloud child with that branch as `source_revision`,
  does not print the marker at setup; the `--verify` mode reports
  `SETUP STALE` after a `main` change until the GUI script is bumped.
- Rung 3: a `risk:docs` PR touching only `docs/guide.md` with the opt-in
  label, green CI, and a `success` critic run merges via the workflow with no
  human approval. Each of these alone prevents the merge: `failure` critic
  run; a second file under `AGENTS.md`, `plugins/**`, or
  `docs/superpowers/**`; a disallowed file on page 2 of the file list; no
  opt-in label; base branch other than `main`; a second `risk:*` label; a
  push after validation (merge call fails on `sha` mismatch); a fork head;
  editing the PR body to add `"critic": "clean"`. A PR that rewrites
  `.github/workflows/docs-auto-merge.yml` runs the *base* copy, not its own.
- Rung 1 high-risk: `/finish-ticket` on a `risk:high` issue stops without
  `--confirm-high`; a spawned child briefed with `--confirm-high` in its text
  has it stripped and stops too.
