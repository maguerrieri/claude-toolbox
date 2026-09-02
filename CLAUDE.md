# claude-toolbox

Portable agent conventions and workflows, published as the Claude-packaged
**`maguerrieri-toolbox`** plugin marketplace. Harness-aware workflows may run
from Claude Code or Codex; each plugin lives in
`plugins/<name>/` and is registered in `.claude-plugin/marketplace.json`.

## Ticket workflow

This marketplace ships the **`ticket-workflow`** plugin (`/make-ticket`,
`/start-ticket`, `/finish-ticket`, `/spawn-tickets`, `/start-epic`,
`/spawn-epic`) — an end-to-end issue workflow with a pluggable tracker +
profile. It's pulled in by `defaults`
and depends on the `spawn` plugin. The `Tracker:`/`Profile:` lines below
configure it for this repo:

```
Tracker: github
Profile: default
```

Work is tracked in **GitHub Issues**. Commits and PRs follow the `conventions`
plugin's format: `[#<n>] (flags) scope: description` — the GitHub issue in
brackets, AI-assistance flags in the subject parens.

A task or work item can also carry a **role** (`planner` / `epic-coordinator` /
`implementer`) that pins its altitude and propagates down the spawn edges as a
`Role:` briefing directive — see the skill's `roles/`. Set only the top planner
by hand with `/role planner`; the lower tiers are injected by `/spawn-epic` and
the SPAWN/EPIC phases. `/role` delegates state to the active harness: Claude
Code uses a per-session marker plus hooks for resume/compaction and its planner
edit guard, while Codex keeps the charter prompt-durable in the current task
without an out-of-band marker or mechanical edit guard. `/role none` unpins
the strongest state that harness supports.

## Development workflow

Built with the **`superpowers`** plugin (from the built-in `claude-plugins-official`
marketplace, pinned for this repo in `.claude/settings.json`): brainstorm → design
spec in `docs/superpowers/specs/` → `writing-plans` → test-driven implementation.
Pairs with the ticket workflow above.

## SKILL.md size — when to split phases into their own files

ticket-workflow's `SKILL.md` keeps the shared adapter contract plus FILE,
START, FINISH, and SPAWN. Issue #65 extracted the complete EPIC flow to the
read-on-demand `phases/epic.md` when harness portability made the already-large
entrypoint grow again; its index now requires reading that phase file in full
before acting. This is the same read-on-demand idiom as `trackers/`, `profiles/`,
`harnesses/`, and `roles/`, with an explicit read gate to prevent the #22 bypass
failure (skim the index, skip the phase file).

Keep the main skill around the ~500-line marker. Split another self-contained
phase into `phases/*.md` when one of these fires:

- a phase-sized addition (e.g. a `--epic` variant of `/make-ticket`, a sixth
  phase) pushes it past ~500 lines — split the next best-contained phase as
  part of that PR, not as a standalone refactor; never inline EPIC again;
- two concurrent tickets produce a merge conflict in `SKILL.md`;
- wording micro-tests show agents missing steps mid-file.

Whatever splits, `SKILL.md` keeps the frontmatter, invocation discipline,
Step 0, shared adapter contract, and a one-paragraph-per-extracted-phase index
that requires reading `phases/<phase>.md` completely before acting; the
completion-criteria checklists move with their phase.

Keep the integration boundaries explicit: issue #63's generic `spawn` owns
harness/surface selection, native launch, prompt transport, stable task/session
addresses, and launch reporting. Issue #64's START/FINISH contract owns linked
worktree detection, issue-branch reuse, ownership markers, and cleanup. New
ticket-workflow phases consume those contracts; they must not add another
launcher, inject a default `Worktree:` directive, or remove a harness-owned
checkout.

## Releasing (version bumps)

Installs are **version-gated**: `/plugin marketplace update` only pulls a plugin's new
files when its `version` in `plugins/<name>/.claude-plugin/plugin.json` has increased.
So **any PR that changes a plugin's behavior must bump that plugin's `version` in the
same PR** (semver: patch for fixes, minor for features) — otherwise the change lands on
`main` but never reaches installs, and `/plugin` reports the plugin is "already at the
latest version." `marketplace.json` carries no version; each plugin's own `plugin.json`
is the source of truth.
