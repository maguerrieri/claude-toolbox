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

## Specs

Design specs (from the superpowers brainstorming flow) live in
`docs/superpowers/specs/`.
