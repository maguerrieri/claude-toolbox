# claude-toolbox

Portable Claude Code conventions and workflows, published as the
**`maguerrieri-toolbox`** plugin marketplace. Each plugin lives in
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

A session can also carry a **role** (`planner` / `epic-coordinator` /
`implementer`) that pins its altitude and propagates down the spawn edges as a
`Role:` briefing directive — see the skill's `roles/`. Set only the top planner
by hand with `/role planner` (a per-session marker + hooks make it durable
across resume/compaction and gate a pinned planner's edits behind a permission
prompt); the lower tiers are injected by `/spawn-epic` and the SPAWN/EPIC
phases. `/role none` unpins.

## Development workflow

Built with the **`superpowers`** plugin (from the built-in `claude-plugins-official`
marketplace, pinned for this repo in `.claude/settings.json`): brainstorm → design
spec in `docs/superpowers/specs/` → `writing-plans` → test-driven implementation.
Pairs with the ticket workflow above.

## SKILL.md size — when to split phases into their own files

ticket-workflow's `SKILL.md` deliberately stays a **single file** (~520 lines as of
#45 — over the ~500 marker, but that trigger is for *phase-sized* additions): the phases cross-reference each other's steps by number (EPIC → START Steps
2/3/7, FINISH's gate → START Step 6), and one file keeps full-context reads the
default — splitting reintroduces the #22 bypass failure in a new form (skim the
index, skip the phase file). Don't split preemptively. Split phases into
read-on-demand `phases/*.md` (the same read-on-demand idiom as `trackers/`,
`profiles/`, and `roles/`) when one of these fires:

- a phase-sized addition (e.g. a `--epic` variant of `/make-ticket`, a sixth
  phase) pushes it past ~500 lines — split as part of that PR, not as a
  standalone refactor;
- two concurrent tickets produce a merge conflict in `SKILL.md`;
- wording micro-tests show agents missing steps mid-file.

Extract **EPIC first** — biggest, most self-contained, least invoked. Whatever
splits, `SKILL.md` keeps the frontmatter, invocation discipline, Step 0, and a
one-paragraph-per-phase index ending in "Read `phases/<phase>.md` now"; the
completion-criteria checklists move with their phase.

## Releasing (version bumps)

Installs are **version-gated**: `/plugin marketplace update` only pulls a plugin's new
files when its `version` in `plugins/<name>/.claude-plugin/plugin.json` has increased.
So **any PR that changes a plugin's behavior must bump that plugin's `version` in the
same PR** (semver: patch for fixes, minor for features) — otherwise the change lands on
`main` but never reaches installs, and `/plugin` reports the plugin is "already at the
latest version." `marketplace.json` carries no version; each plugin's own `plugin.json`
is the source of truth.
