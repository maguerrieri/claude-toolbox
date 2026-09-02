# claude-toolbox

Portable agent conventions, packaged as a [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces).
The marketplace and install commands remain Claude-packaged; harness-aware
workflows can execute from Claude Code or Codex and across their supported
desktop, CLI, and cloud surfaces.

## Plugins

- **defaults** — meta-plugin with no content of its own; its `dependencies`
  list pulls in every plugin below. Install this one to get the full set.
  New plugins added to this repo should also be added to its dependencies.
- **conventions** — cross-repo development conventions. Currently: commit
  message format. Candidates to move in later: merge policy, issue/epic
  structure.
- **spawn** — generic background-task fan-out: the `spawn` skill plus the
  `/spawn` command. It inherits both the caller's Codex/Claude harness and
  desktop/CLI/cloud execution surface, supports explicit `--harness` and
  `--surface` overrides, and hands back without blocking. Cross-harness local
  calls select the target CLI; unavailable pairs fail instead of falling back.
- **generate** — diverse bulk ideation: the `generate` skill plus the
  `/generate` command. Runs a judgment-OFF morphological-analysis loop (frame →
  diversity-prompted parallel passes → axis-tag → cluster) that fights LLM
  mode-collapse, with the decision handoff behind a pluggable **Promotion
  adapter** (`inline` / `github-issue` / `adr`, or point it at your own).
- **ticket-workflow** — end-to-end issue workflow: the `ticket-workflow` skill
  plus `/make-ticket`, `/start-ticket`, `/finish-ticket`, `/spawn-tickets`,
  `/start-epic`, and `/spawn-epic`. Files an issue from conversation context and
  takes it from open to a reviewed PR and on to merged, with a pluggable
  **tracker** (GitHub Issues or Jira), **profile**, and active **harness**
  adapter. The workflow itself can execute from Claude Code or Codex while
  retaining harness-correct role state, task inspection, and attribution.
  Builds on `spawn` for harness-and-surface-aware parallel fan-out, so
  `/make-ticket --spawn`, `/spawn-tickets`, and `/spawn-epic` inherit both
  launch axes without duplicating mechanics.
- **yaml** — YAML editing guardrails: the `yaml` skill. Fires on the *surfaces*
  (frontmatter in SKILL.md / command / agent .md files, GitHub Actions workflows,
  docker-compose, k8s manifests, CI configs) — even for prose-feeling edits —
  and carries one quoting decision rule, a mandatory parse/round-trip verify
  step, and a compact symptom→cause→fix gotcha table.
- **gm** — system-agnostic, persona-driven solo-RPG game master: the `gm` skill
  plus 7 `/gm:*` commands (`/gm:new-campaign`, `/gm:play`, `/gm:wrap`,
  `/gm:oracle`, `/gm:checkpoint`, `/gm:rewind`, `/gm:backup`). Pluggable system
  adapters (generic / Ironsworn / Starforged), true dice, and git-versioned
  saves.

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
