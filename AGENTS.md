# Editing workflow guidance

- A profile override replaces the corresponding default operation in full. Do not
  make default mechanics binding on overriding profiles; user instructions and host
  permissions remain authoritative independently of that inheritance mechanism.
- Before patching long prose, copy the exact context from the source file. A
  remembered wrapped line can omit a quote and make `apply_patch` fail; do not
  retry the same guessed context.
- Review completion must be tied to the PR head commit, not a reviewer's login
  or disappearance from the pending list. Review summaries can contain actionable
  suppressed feedback even when there are no inline threads. The authoritative
  procedure lives in `plugins/ticket-workflow/skills/ticket-workflow/profiles/default.md`
  under `REVIEW_BOT`; keep completion summaries consistent with it.
- Codex heartbeat creation needs an explicit task destination: use
  `destination: "thread"` for the current task or a known `targetThreadId`.
  Omitting both returns `Missing targetThreadId or destination=thread` even
  when the exposed schema marks them optional. Check the tool result before
  claiming a follow-up exists; a validation error creates nothing.
