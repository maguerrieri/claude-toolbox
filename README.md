# claude-dotfiles

Portable Claude Code conventions, packaged as a [plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces).
One repo, declared per-project, works in local and cloud sessions alike.

## Plugins

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
    "conventions@mario-dotfiles": true
  }
}
```

Or user-wide: `claude plugin marketplace add maguerrieri/claude-dotfiles && claude plugin install conventions@mario-dotfiles`.

Org-specific playbooks (deploy processes, review-bot cycles, ticket rules)
deliberately do **not** live here — they stay in org work config; these
conventions are the portable layer underneath.
