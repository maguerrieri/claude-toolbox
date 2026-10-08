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
- `CLAUDE.md` is a recommended compatibility shim whose complete contents
  are:

  ```markdown
  @AGENTS.md
  ```

The shim is recommended, not required: current Claude Code can read
`AGENTS.md` without it, so a repository that lacks it isn't broken, but add
it. With the shim, Claude Code loads `AGENTS.md` through the import, so it
arrives on every version and in every session that reads `CLAUDE.md`.
Without it, `AGENTS.md` depends on Claude Code's native reading, which older
versions and some sessions lack, and which switches off as soon as any of the
`CLAUDE.md` files listed under *Harness behavior* (below) exists: a
contributor who adds a `CLAUDE.local.md` for their own notes silently loses
`AGENTS.md`. The shim also serves any other tool that reads `CLAUDE.md` and
follows `@` imports. Its cost, per Claude Code's docs, is native discovery
of nested `AGENTS.md` files, which the root shim turns off (*Harness
behavior and scoped files*).

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
5. Reduce root `CLAUDE.md` to the exact `@AGENTS.md` shim rather than
   deleting it (*Portable baseline* says why), and verify each supported
   harness loads the intended context.

User-level settings such as Codex
`project_doc_fallback_filenames = ["CLAUDE.md"]` can ease a migration, but they
are machine-local configuration, not a portable repository contract.

## Harness behavior and scoped files

- Codex natively discovers `AGENTS.override.md` and `AGENTS.md`; configured
  fallback names come after those files.
- Claude Code reads `CLAUDE.md` and expands `@file` imports. Per its memory
  docs (below), v2.1.277 and later also read `AGENTS.md` natively, but under
  the default setting only when no `CLAUDE.md`, `.claude/CLAUDE.md` or
  `CLAUDE.local.md` exists in the working directory or above it (the
  user-level `~/.claude/CLAUDE.md`, an organization's managed `CLAUDE.md`,
  and `.claude/rules/` files don't count). With one, it reads the
  `CLAUDE.md` files and whatever they import. The docs also list sessions
  without native reading: any with the built-in `AGENTS.md` plugin disabled,
  in some cases the first one after upgrading from v2.1.276 or earlier, and,
  before v2.1.281, Amazon Bedrock or telemetry-disabled ones. A **Project
  instructions** setting, set in `/config` or user or managed settings but
  not in project settings, changes the default: `claude-md-and-agents-md`
  reads both files (skipping an `AGENTS.md` already imported, so the shim
  isn't read twice), and `claude-md` reads `CLAUDE.md` only.
  Verified on Claude Code 2.1.294 in headless `claude -p` runs with no tools,
  by asking for a codeword kept in `AGENTS.md`: with only `AGENTS.md` it
  loaded; adding a `CLAUDE.local.md`, or a `CLAUDE.md` without the import,
  dropped it; with the `@AGENTS.md` shim it loaded, with or without a
  `CLAUDE.local.md`. Interactive sessions and the non-default settings
  weren't tested.
- GitHub Copilot CLI discovers `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md`.
- Gemini CLI defaults to `GEMINI.md`; users can configure other context
  filenames and use `@file.md` imports.

The root baseline is the portable contract. Nested and path-scoped instruction
discovery differs across harnesses, so verify every supported harness before
depending on a nested layout. Prefer each harness's scoped mechanism when
identical cross-harness behavior is not established. Claude Code's docs
describe loading a subdirectory's `AGENTS.md` when Claude reads a file there,
but only as part of native reading, which the root shim turns off under the
default setting. So a nested `AGENTS.md` kept for another harness, such as
Codex, doesn't reach Claude Code in a repository with the shim; give Claude
Code that guidance through `.claude/rules/` instead. Neither the nested
loading nor the shim's suppression of it is verified here.

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
- [Anthropic: Claude Code memory, CLAUDE.md and AGENTS.md](https://code.claude.com/docs/en/memory)
- [GitHub: Copilot CLI custom instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions)
- [Google: Gemini CLI project context](https://geminicli.com/docs/cli/gemini-md/)
