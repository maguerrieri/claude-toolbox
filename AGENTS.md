# Editing workflow guidance

- Before patching long prose, copy the exact context from the source file. A
  remembered wrapped line can omit a quote and make `apply_patch` fail; do not
  retry the same guessed context.
- Review completion must be tied to the PR head commit, not a reviewer's login
  or disappearance from the pending list. Review summaries can contain actionable
  suppressed feedback even when there are no inline threads. The authoritative
  procedure lives in `plugins/ticket-workflow/skills/ticket-workflow/profiles/default.md`
  under `REVIEW_BOT`; keep completion summaries consistent with it.
