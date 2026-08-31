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
- Claude-local-to-Claude-local ticket spawns keep the `Notify:` wake-up channel.
  Claude cloud, Codex targets, and Codex-to-Claude overrides omit it and rely on
  their native task/PR inspection path. Resolve the spawner identity lazily
  inside the Claude-local adapter only when caller and target share that local
  graph; all other paths must not perform a discarded `ListAgents` lookup.
- `clientThreadId` means Codex worktree setup is queued. It is safe for the
  created-task UI directive, but not for tools that require a real `threadId`
  (`read_thread`, navigation, follow-up messages, waits, or task mutation).

These are two-axis routing rules: the harness adapter owns task creation and
isolation; the Claude adapter alone selects local versus cloud backend.

## Shell inspection

Tool commands run through zsh. Do not put Markdown backticks inside a
double-quoted shell command (including an `rg` pattern): zsh executes the text
between them. Use a single-quoted command or remove the backticks from the
pattern.
