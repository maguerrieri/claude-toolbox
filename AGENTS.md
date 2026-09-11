# claude-toolbox

Portable coding-agent conventions and Claude Code workflows, published as the
**`maguerrieri-toolbox`** plugin marketplace. Each plugin lives in
`plugins/<name>/` and is registered in `.claude-plugin/marketplace.json`.

## Repository instructions

This root `AGENTS.md` is the canonical source for shared project instructions.
The root `CLAUDE.md` must contain only `@AGENTS.md`; keep Claude-specific
behavior in Claude-owned surfaces such as `.claude/rules/`, settings, or skills.
The policy and migration guidance live in `conventions:repo-instructions`.

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

(An optional `Worktree dir: <path>` line in the same block — or in project memory —
overrides where `/start-ticket` creates worktrees; the default, `.claude/worktrees/`,
is the only location that avoids Claude Code's unsuppressible enter-worktree prompt.)

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

## Dogfooding our own plugins

`.claude/settings.json` registers this repo's own marketplace **over GitHub**
(`extraKnownMarketplaces.maguerrieri-toolbox` → `maguerrieri/claude-toolbox`) and
enables `defaults@maguerrieri-toolbox` **plus each of its five dependencies by
name**, so an interactive session that trusts the folder gets `/make-ticket`,
`/start-ticket`, `/spawn`, etc. with no manual `/plugin` step. Caveats, all
verified on Claude Code 2.1.268:

- **Sessions load `main`, not the working tree.** The plugins arrive as last
  pushed to `main` and version-bumped (see Releasing below); edits on a branch or
  in an uncommitted working tree are invisible to the session.
- **Testing unmerged plugin changes still needs `/plugin marketplace add ./` by
  hand** (or `claude --plugin-dir plugins/<name>`). This can't be checked in: a
  `directory` source with a relative path is stored literally and then fails with
  "not found in marketplace" (anthropics/claude-code#23978), and an absolute path
  isn't portable.
- **Keep the dependencies listed next to `defaults`.** The install that project
  settings trigger caches `defaults` but does not resolve its `dependencies`, so
  `defaults` alone ends up disabled (`dependency-unsatisfied`) and zero commands
  load. With the five listed explicitly, all six enable and the nine plugin
  commands load. A new plugin added to `defaults`' dependencies must therefore
  also be added here (and to the README snippet). `claude plugin install
  defaults@maguerrieri-toolbox` *does* resolve dependencies; only the
  settings-triggered path doesn't.
- **Headless sessions register the marketplace but install nothing.** With
  `claude -p` (and so the SDK), the settings clone the marketplace, then the
  loader reports every enabled plugin as `plugin-cache-miss` — `defaults` and
  the individually listed plugins alike, and the same for the `superpowers`
  entry. Interactive terminal sessions and `claude --bg` do install them.
- **Cloud sessions (Claude Code on the web) install them from a hook.** The
  cloud launcher runs Claude Code in SDK mode with the folder untrusted, and its
  startup log says why the plugins never arrive on their own: `Skipped
  auto-recording <plugin> — enabled only by repo-authored settings`. That's a
  consent policy, not a bug in this config: a cloned repo can't install code on
  its own. (The cloud-environments doc's claim that project-declared plugins
  install at session start didn't hold on 2.1.268.) Cloud sessions *do* honor
  repo-declared hooks, so `.claude/hooks/session-start.sh` does the install:
  when `CLAUDE_CODE_REMOTE` is `true` it reads this same `settings.json` with
  `jq`, runs `claude plugin marketplace add` for each marketplace and
  `claude plugin install` for each enabled plugin, and exits 0 no matter what.
  The settings file stays the single source of truth; the hook never changes
  when the plugin set does, and is a no-op locally. Other repos run the same
  file with one hook line (`curl -fsSL <raw URL on main> | bash`; see the
  README). Delete it once cloud sessions honor the settings natively. Alternatives that also work, outside
  the repo: enable the marketplace on your claude.ai account (Customize ›
  Plugins › Add marketplace › from a repository) so the plugins sync into cloud
  sessions as `<name>@synced` (skills verified; `claude plugin list` shows
  nothing for them, which is expected), or run the same install from the cloud
  environment's setup script.

## Shell: zsh special parameters

Tool commands run under zsh. Do not use `path` as a loop or script variable:
zsh ties the `path` array to `PATH`, so assigning `path` replaces command lookup.
Use a task-specific name such as `file_path` instead.

## SKILL.md size — when to split phases into their own files

ticket-workflow's `SKILL.md` keeps the phases **in one file** by default (~430
lines as of #79): the phases cross-reference each other's steps by number (EPIC →
START Steps 2/3/7, FINISH's gate → START Step 6), and one file keeps full-context
reads the default — splitting reintroduces the #22 bypass failure in a new form
(skim the index, skip the phase file). **EPIC is the one phase already split
out** (`phases/epic.md`, done in #79 when its cloud port made it phase-sized):
`SKILL.md` carries a one-paragraph index for it ending "Read `phases/epic.md`
now", and the phase file carries its own completion checklist. Don't split
another phase preemptively. Split it into a read-on-demand `phases/<phase>.md`
(the same read-on-demand idiom as `trackers/`, `profiles/`, and `roles/`) when
one of these fires:

- a phase-sized addition (e.g. a `--epic` variant of `/make-ticket`, a sixth
  phase) pushes `SKILL.md` past ~500 lines — split as part of that PR, not as a
  standalone refactor;
- two concurrent tickets produce a merge conflict in `SKILL.md`;
- wording micro-tests show agents missing steps mid-file.

Whatever splits, `SKILL.md` keeps the frontmatter, invocation discipline, Step 0,
and a one-paragraph-per-phase index ending in "Read `phases/<phase>.md` now"; the
completion-criteria checklists move with their phase.

## Releasing (version bumps)

Installs are **version-gated**: `/plugin marketplace update` only pulls a plugin's new
files when its `version` in `plugins/<name>/.claude-plugin/plugin.json` has increased.
So **any PR that changes a plugin's behavior must bump that plugin's `version` in the
same PR** (semver: patch for fixes, minor for features) — otherwise the change lands on
`main` but never reaches installs, and `/plugin` reports the plugin is "already at the
latest version." `marketplace.json` carries no version; each plugin's own `plugin.json`
is the source of truth. CI enforces this: the `plugin versions` check
(`.github/workflows/plugin-versions.yml`) fails any PR whose touched plugin isn't at a
strictly greater version than the PR's base branch (normally `main`).
