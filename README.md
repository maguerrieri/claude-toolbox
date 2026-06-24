# claude-toolbox

Portable Claude Code conventions, packaged as a [plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces).
One repo, declared per-project, works in local and cloud sessions alike.

## Plugins

- **defaults** — meta-plugin with no content of its own; its `dependencies`
  list pulls in every plugin below. Install this one to get the full set.
  New plugins added to this repo should also be added to its dependencies.
- **conventions** — cross-repo development conventions. Currently: commit
  message format. Candidates to move in later: merge policy, issue/epic
  structure, the ticket-workflow skills.
- **spawn** — generic background-session fan-out: the `spawn` skill plus the
  `/spawn` command, for firing off one or more independent `claude --bg`
  sessions and handing back without blocking.
- **generate** — diverse bulk ideation: the `generate` skill plus the
  `/generate` command. Runs a judgment-OFF morphological-analysis loop (frame →
  diversity-prompted parallel passes → axis-tag → cluster) that fights LLM
  mode-collapse, with the decision handoff behind a pluggable **Promotion
  adapter** (`inline` / `github-issue` / `adr`, or point it at your own).

## Usage

Per repo, in `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "maguerrieri-toolbox": {
      "source": { "source": "github", "repo": "maguerrieri/claude-toolbox" }
    }
  },
  "enabledPlugins": {
    "defaults@maguerrieri-toolbox": true
  }
}
```

Enabling `defaults` auto-installs and enables its dependencies, so the
settings file stays one line no matter how many plugins land here. To pick
plugins à la carte instead, enable them individually
(`"conventions@maguerrieri-toolbox": true`).

Or user-wide: `claude plugin marketplace add maguerrieri/claude-toolbox && claude plugin install defaults@maguerrieri-toolbox`.

Org-specific playbooks (deploy processes, review-bot cycles, ticket rules)
deliberately do **not** live here — they stay in org work config; these
conventions are the portable layer underneath.
