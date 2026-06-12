---
name: commit-conventions
description: Mario's git commit message format. Use whenever writing, amending, or reviewing a git commit message in any of Mario's repos.
---

# Commit message conventions

Format:

```
[<ticket>] (<flags>) <scope>: <description>
```

## Ticket

The issue/ticket ID for the work, in the tracker's native form — `#42` for
GitHub issues, `PROJ-123` for Jira. Include it whenever the repo tracks work
in issues (in repos with issue-driven workflows, every commit references one).
Omit only when the repo genuinely has no tracker. Org-specific ticket rules
live in that org's work config, not here.

## Flags

Include when applicable, in this order, comma-or-semicolon separated:

1. `CRC` — the commit addresses Code Review Comments.
2. `<Harness> + <Model>` — AI assistance was used. Name **both** the harness
   and the model. Prefix the model with its vendor only when the harness
   doesn't already pin it:
   - Claude Code only drives Claude models, so the model goes bare:
     `Claude Code + Fable 5`, `Claude Code + Opus 4.8`
   - Copilot is vendor-agnostic, so the vendor is needed:
     `Copilot + Claude Fable 5`, `Copilot + GPT-5`

No flags apply → omit the parentheses entirely.

## Scope

The subsystem/area touched (`split`, `clubs`, `docs`, `scaffold`, …).
Optional for tiny commits where the description carries it.

## Examples

```
[PROJ-123] (Claude Code + Fable 5) split: Add GeoIP routing
[PROJ-123] (CRC; Claude Code + Fable 5) Fix null check per review
[#42] (Copilot + Claude Fable 5) clubs: Cache member stats
[PROJ-123] Fix typo in config
```

## Adjacent rules

- When rebasing, avoid commands that open interactive editors — pass
  everything via CLI flags.
- A repo's own CLAUDE.md may extend or override this; org playbooks (work
  config) take precedence in org repos.
