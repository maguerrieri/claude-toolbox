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
  So: keep them few (one per risk tier), make each a thin pointer, and put
  everything else in the repo.
- **First auto-merge class is docs-only** (diff touches only `*.md` and
  `docs/**`).
- **No plugin behavior changes ride in this spec's PR.** Each child issue bumps
  the plugin it touches (the `plugin versions` CI check enforces it).

## Design

### Rung 1 — Evidence and gates (do first)

**1a. Evidence block in the PR body.** Extend the START Step 7 PR template in
`plugins/ticket-workflow/skills/ticket-workflow/SKILL.md` with an `## Evidence`
section, fenced YAML so it's greppable:

```yaml
risk: docs            # from the ticket label (1c); "unclassified" if none
tests: <commands run under TESTS, or "n/a: <why>">
docs: <DOCS outcome: "no doc impact" | files fixed>
ci: green | red
review_threads_unresolved: 0
critic_findings: 0    # rung 3; omitted until then
context_reads: [<files read outside the diff, short list>]
session: <$CLAUDE_CODE_REMOTE_SESSION_ID or "local">
role: implementer
wall_clock_min: <n>
```

**1b. Machine-checked FINISH gate.** FINISH Step 1 gains
`plugins/ticket-workflow/scripts/check-evidence.sh <pr>` (same idiom as
`.github/scripts/check-plugin-versions`): reads the PR body via
`gh pr view --json body`, parses the block, and exits non-zero when it is
absent or when `ci` ≠ `green` or `review_threads_unresolved` ≠ `0`. The step
stays report-and-stop, never auto-fix, matching the rest of the gate. A shell
test under the plugin exercises present/absent/red cases.

**1c. Risk label on tickets.** `/make-ticket` accepts
`--risk docs|low|normal|high`; the GitHub tracker adapter applies a
`risk:<class>` label. START copies it into the Evidence block. No behavior
change yet — this is the data rung 3 consumes.

**1d. Branch rulesets on both repos** (manual, one-time, done alongside 1a):
`main` requires a PR, green CI, and one approving review, no bypass actors;
`claude/**` is pushable by the agent actor(s) named in 2d. The exact ruleset
JSON is recorded here once applied so it's reproducible.

### Rung 2 — Identity and boundaries

**2a. Repo-side permissions.** Add a `permissions` block to
`toolbox/.claude/settings.json` and extend `claude-toolbox/.claude/settings.json`:
allow the repos' own test/lint/`terraform plan` commands (seeded with
`/fewer-permission-prompts`); deny `terraform apply`, `gcloud run deploy`,
`firebase deploy`, force-pushes without lease, and edits under `~/.config`.
The implementer role's hook (the same mechanism that gates a pinned planner's
edits) gains a deny list for deploy commands.

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
workflow's SPAWN Step 3 forwards it.

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
an adversarial subagent (the `code-review` skill at high effort) reviews the
diff; its findings land in the Evidence block as `critic_findings`. The default
profile enables it for `risk:docs` and above.

**3b. Docs-only auto-merge.** In the FINISH gate, when `risk:docs` and the diff
is docs-only by path check and CI is green and `critic_findings: 0`, FINISH may
merge without a human; `SPAWN_CAP` lifts for this class only. The merge is
performed by a `docs-auto-merge` GitHub Actions job (`pull-requests: write`)
so `main` keeps "no bypass" for humans and agents alike; the job re-checks the
same conditions server-side.

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
| 1 | Evidence block in START PR template | 1a | — |
| 2 | `check-evidence.sh` FINISH gate + test | 1b | 1 |
| 3 | `--risk` flag and `risk:<class>` label | 1c | — |
| 4 | Rulesets on both repos; record JSON in this spec | 1d | — |
| 5 | Repo `permissions` blocks | 2a | — |
| 6 | `cloud-setup.sh`, two environments, `remote.defaultEnvironmentId` | 2b, 2c | 5 |
| 7 | `Environment:` directive through spawn and SPAWN | 2c | 6 |
| 8 | Spike: which launch paths yield `claude[bot]` on the personal account | 2d | — |
| 9 | `Budget:` directive in `SPAWN_CAP` | 2e | 1 |
| 10 | `REVIEW_CRITIC` profile op | 3a | 2 |
| 11 | Docs-only auto-merge gate + Actions job | 3b | 3, 4, 10 |
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

## Testing

- Rung 1: run `/start-ticket` on a docs-only issue from a cloud session;
  confirm the PR body carries the Evidence block; run `/finish-ticket` and
  confirm the gate passes; strip the block on a scratch PR and confirm it
  stops.
- Rung 2: spawn two implementers from a coordinator session; confirm they land
  in `factory-implementer`, cannot run a deploy command, and their PRs are
  blocked on `main` without a review.
- Rung 3: a `risk:docs` PR with green CI and zero critic findings merges via
  the Actions job; the same PR with one critic finding does not.
