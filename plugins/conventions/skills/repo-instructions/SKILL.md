---
name: repo-instructions
description: 'Use when creating, auditing, or migrating repository instruction files for coding-agent harnesses.'
---

# Repository instruction conventions

Use one shared source of truth for guidance that coding agents must receive in
every session.

## Portable baseline

At the repository root:

- `AGENTS.md` is canonical for shared, harness-neutral project instructions.
- `CLAUDE.md` is a compatibility shim whose complete contents are:

  ```markdown
  @AGENTS.md
  ```

Prefer the import over a symlink: it works on platforms where creating symlinks
needs elevated privileges. Keep the shim pure. GitHub Copilot CLI also discovers
`CLAUDE.md`, so appending Claude-only behavior there can leak that behavior into
Copilot sessions.

Put genuinely harness-specific mechanics in harness-owned surfaces instead:
`.claude/rules/`, `.claude/settings.json`, Claude-specific skills, `.codex/`, or
the corresponding surface for another harness. Do not duplicate shared prose
across files.

## Instructions versus skills

Repository instructions are always-loaded context: build and test commands,
architecture boundaries, safety constraints, and workflow rules an agent must
know before acting. Keep them concise.

Skills are on-demand procedures or references selected for a matching task.
Use a skill for a specialized workflow; do not hide a rule that must apply to
every session behind skill discovery.

## Migration

When both `CLAUDE.md` and `AGENTS.md` already exist:

1. Compare them and resolve conflicts deliberately; do not concatenate them.
2. Move shared project guidance into root `AGENTS.md` once.
3. Relocate harness-only guidance to that harness's owned surface.
4. Audit repository automation that parses one instruction filename directly;
   migrate that consumer first or defer this repository's file migration.
5. Reduce root `CLAUDE.md` to the exact `@AGENTS.md` shim and verify each
   supported harness loads the intended context.

User-level settings such as Codex
`project_doc_fallback_filenames = ["CLAUDE.md"]` can ease a migration, but they
are machine-local configuration, not a portable repository contract.

## Harness behavior and scoped files

- Codex natively discovers `AGENTS.override.md` and `AGENTS.md`; configured
  fallback names come after those files.
- Claude Code reads `CLAUDE.md`, not `AGENTS.md`, and expands `@file` imports.
- GitHub Copilot CLI discovers `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md`.
- Gemini CLI defaults to `GEMINI.md`; users can configure other context
  filenames and use `@file.md` imports.

The root baseline is the portable contract. Nested and path-scoped instruction
discovery differs across harnesses, so verify every supported harness before
depending on a nested layout. Prefer each harness's scoped mechanism when
identical cross-harness behavior is not established.

## Plugins declared per repository

Declare the plugins a repository needs in `.claude/settings.json`, not in
prose: `extraKnownMarketplaces` registers the marketplace and `enabledPlugins`
turns plugins on. Two rules keep that declaration working in interactive local
sessions and in cloud sessions (verified on Claude Code 2.1.268; headless
`claude -p`/SDK runs install nothing from project settings and are out of
scope here):

- **List every enabled plugin's dependencies next to it.** The install that
  project settings trigger on the trust prompt does not resolve any plugin's
  `dependencies`, so a plugin enabled without them ends up disabled
  (`dependency-unsatisfied`) and loads nothing: a bundle plugin without the
  plugins it bundles, or a single plugin without the one it builds on. Enable
  each plugin *and* everything its manifest depends on.
- **Install from a SessionStart hook for cloud sessions.** Cloud sessions honor
  repo-declared hooks but skip repo-declared plugins ("enabled only by
  repo-authored settings"), and headless runs (`claude -p`, the SDK) install
  nothing from `enabledPlugins`. Commit a hook that, when `CLAUDE_CODE_REMOTE`
  is `true`, reads the same `settings.json` and, for each enabled plugin, runs
  `claude plugin marketplace add <source>` for its marketplace and `claude
  plugin install <plugin>`. Keep the marketplaces it may use as an allowlist
  inside the script: a repo hook already runs arbitrary shell in cloud
  sessions, but the allowlist stops a settings-only change on a branch from
  pointing the hook at a new source. The settings file stays the single source
  of truth and the hook never changes when the plugin set does. The reference
  implementation is `.claude/hooks/session-start.sh` in
  `maguerrieri/claude-toolbox`; either copy that file or run it from there
  with a single hook entry and nothing to copy:

  ```json
  {
    "hooks": {
      "SessionStart": [
        {
          "matcher": "startup|resume",
          "hooks": [
            {
              "type": "command",
              "command": "curl -fsSL https://raw.githubusercontent.com/maguerrieri/claude-toolbox/main/.claude/hooks/session-start.sh | bash"
            }
          ]
        }
      ]
    }
  }
  ```

  Pin a commit SHA in place of `main` for an immutable copy. The fetch needs
  `raw.githubusercontent.com`, which is on the cloud environments' default
  allowlist. A plugin can't carry this hook: it is what installs the plugins.

## First-party references

- [AGENTS.md standard](https://agents.md/)
- [OpenAI: custom instructions with AGENTS.md](https://developers.openai.com/codex/guides/agents-md/)
- [Anthropic: Claude Code memory and AGENTS.md imports](https://code.claude.com/docs/en/memory)
- [GitHub: Copilot CLI custom instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions)
- [Google: Gemini CLI project context](https://geminicli.com/docs/cli/gemini-md/)
