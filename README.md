# claude-toolbox

Portable coding-agent conventions and Claude Code workflows, packaged as a
[Claude-compatible plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces).
One repo, declared per-project, works in local and cloud sessions alike.

## Plugins

- **defaults** — meta-plugin with no content of its own; its `dependencies`
  list pulls in every plugin below. Install this one to get the full set.
  New plugins added to this repo should also be added to its dependencies.
- **conventions** — cross-repo development conventions: commit-message format
  and a portable repository-instruction policy built around canonical root
  `AGENTS.md` plus a pure `CLAUDE.md` import shim.
- **spawn** — generic background-session fan-out: the `spawn` skill plus the
  `/spawn` command, for firing off one or more independent `claude --bg`
  sessions and handing back without blocking.
- **generate** — diverse bulk ideation: the `generate` skill plus the
  `/generate` command. Runs a judgment-OFF morphological-analysis loop (frame →
  diversity-prompted parallel passes → axis-tag → cluster) that fights LLM
  mode-collapse, with the decision handoff behind a pluggable **Promotion
  adapter** (`inline` / `github-issue` / `adr`, or point it at your own).
- **ticket-workflow** — end-to-end issue workflow: the `ticket-workflow` skill
  plus `/make-ticket`, `/start-ticket`, `/finish-ticket`, `/spawn-tickets`,
  `/start-epic`, and `/spawn-epic`. Files an issue from conversation context and
  takes it from open to a reviewed PR and on to merged, with a pluggable
  **tracker** (GitHub Issues or Jira) and **profile**. Builds on `spawn` for its
  parallel fan-out.
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
    "defaults@maguerrieri-toolbox": true,
    "conventions@maguerrieri-toolbox": true,
    "spawn@maguerrieri-toolbox": true,
    "generate@maguerrieri-toolbox": true,
    "ticket-workflow@maguerrieri-toolbox": true,
    "yaml@maguerrieri-toolbox": true
  }
}
```

List the dependencies out, not just `defaults`: the install that project
settings trigger on trust caches `defaults` but does not resolve its
`dependencies`, so on its own it ends up disabled (`dependency-unsatisfied`)
and nothing loads (verified on Claude Code 2.1.268). Drop what you don't want
for an à la carte pick. Headless sessions (`claude -p`, the SDK) register the
marketplace but install nothing from `enabledPlugins`; see the repo's
`AGENTS.md` for the details.

Or user-wide: `claude plugin marketplace add maguerrieri/claude-toolbox && claude plugin install defaults@maguerrieri-toolbox`
— that path does resolve `defaults`' dependencies, so one install pulls in
every plugin above.

Org-specific playbooks (deploy processes, review-bot cycles, ticket rules)
deliberately do **not** live here — they stay in org work config; these
conventions are the portable layer underneath.
