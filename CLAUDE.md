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

## Development workflow

Built with the **`superpowers`** plugin (from the built-in `claude-plugins-official`
marketplace, pinned for this repo in `.claude/settings.json`): brainstorm → design
spec in `docs/superpowers/specs/` → `writing-plans` → test-driven implementation.
Pairs with the ticket workflow above.

## Releasing (version bumps)

Installs are **version-gated**: `/plugin marketplace update` only pulls a plugin's new
files when its `version` in `plugins/<name>/.claude-plugin/plugin.json` has increased.
So **any PR that changes a plugin's behavior must bump that plugin's `version` in the
same PR** (semver: patch for fixes, minor for features) — otherwise the change lands on
`main` but never reaches installs, and `/plugin` reports the plugin is "already at the
latest version." `marketplace.json` carries no version; each plugin's own `plugin.json`
is the source of truth.
