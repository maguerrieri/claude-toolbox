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

## First-party references

- [AGENTS.md standard](https://agents.md/)
- [OpenAI: custom instructions with AGENTS.md](https://developers.openai.com/codex/guides/agents-md/)
- [Anthropic: Claude Code memory and AGENTS.md imports](https://code.claude.com/docs/en/memory)
- [GitHub: Copilot CLI custom instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions)
- [Google: Gemini CLI project context](https://geminicli.com/docs/cli/gemini-md/)
