# claude-dotfiles

Portable Claude Code conventions, packaged as a [plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces).
One repo, declared per-project, works in local and cloud sessions alike.

## Plugins

- **defaults** — meta-plugin with no content of its own; its `dependencies`
  list pulls in every plugin below. Install this one to get the full set.
  New plugins added to this repo should also be added to its dependencies.
- **conventions** — cross-repo development conventions. Currently: commit
  message format. Candidates to move in later: merge policy, issue/epic
  structure, the ticket-workflow skills.

## Usage

Per repo, in `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "mario-dotfiles": {
      "source": { "source": "github", "repo": "maguerrieri/claude-dotfiles" }
    }
  },
  "enabledPlugins": {
    "defaults@mario-dotfiles": true
  }
}
```

Enabling `defaults` auto-installs and enables its dependencies, so the
settings file stays one line no matter how many plugins land here. To pick
plugins à la carte instead, enable them individually
(`"conventions@mario-dotfiles": true`).

Or user-wide: `claude plugin marketplace add maguerrieri/claude-dotfiles && claude plugin install defaults@mario-dotfiles`.

Org-specific playbooks (deploy processes, review-bot cycles, ticket rules)
deliberately do **not** live here — they stay in org work config; these
conventions are the portable layer underneath.
