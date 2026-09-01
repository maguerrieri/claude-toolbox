# Repository Agent Notes

## Spawn harness integration invariants

- A native Codex project task already owns a managed worktree. A spawned
  `/start-ticket` must reuse that checkout (`Worktree: current`) instead of
  creating a sibling worktree outside the task's writable/review surface.
  Carry that ownership through submodule setup and FINISH: the workflow must not
  remove an app-owned checkout or delete its branch. START can be re-entered,
  so switch to an existing issue branch instead of always recreating it with
  `git switch -c`.
- Generic spawn units may carry an explicit `name`; harness adapters preserve it
  verbatim. Ticket names must not be reconstructed from the caller's cwd.
- Claude-CLI-to-Claude-CLI ticket spawns keep the `Notify:` wake-up channel.
  Cloud, desktop, and cross-harness targets omit it and rely on their native
  task/PR inspection path. Resolve the spawner identity lazily only when caller
  and target share Claude CLI's local graph; all other paths must not perform a
  discarded `ListAgents` lookup.
- `clientThreadId` means Codex worktree setup is queued. It is safe for the
  created-task UI directive, but not for tools that require a real `threadId`
  (`read_thread`, navigation, follow-up messages, waits, or task mutation).

Harness (`codex|claude`) and execution surface (`desktop|cli|cloud`) are
independent routing axes. Same-harness spawn inherits both. Cross-harness local
spawn maps to the target CLI; cloud maps to target cloud. An explicit surface
always wins, and an unavailable selected pair must fail without fallback.

Stock Codex CLI 0.148.0 has `codex exec` but no durable `--bg` session launcher;
the uppercase `Codex` executable is not a separate background wrapper. Until a
native durable CLI adapter exists, `codex+cli` spawn reports unsupported rather
than borrowing desktop task tools or shell-backgrounding `codex exec`.

For behavior changes, complete the brainstorming skill's design-approval gate
before opening implementation-only guidance such as TDD. Treat reading that
guidance as entering implementation, even if no file has changed yet.

Editing prose inside a Markdown file's `---` frontmatter is a YAML edit. Load
the YAML skill before changing fields such as `description`, then parse the
frontmatter and assert the exact edited value; visual inspection is not enough.

## Shell inspection

Tool commands run through zsh. Do not put Markdown backticks inside a
double-quoted shell command (including an `rg` pattern): zsh executes the text
between them. This applies even to read-only inspection commands. Use a
single-quoted command or remove the backticks from the pattern.

## Ticket-workflow skill validation

The ticket-workflow plugin does not ship a validator under its own `scripts/`
directory. Validate it with the system skill-creator validator:

`uv run --with pyyaml python3 /Users/mario/.codex/skills/.system/skill-creator/scripts/quick_validate.py plugins/ticket-workflow/skills/ticket-workflow`
