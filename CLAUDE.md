# claude-toolbox

Portable Claude Code conventions and workflows, published as the
**`maguerrieri-toolbox`** plugin marketplace. Each plugin lives in
`plugins/<name>/` and is registered in `.claude-plugin/marketplace.json`.

## Ticket workflow

This repo uses the `ticket-workflow` skill (`/start-ticket`, `/finish-ticket`,
`/spawn-tickets`, `/start-epic`).

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
