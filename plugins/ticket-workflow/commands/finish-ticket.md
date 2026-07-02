---
description: >-
  Use when asked to finish, land, merge, or close out a reviewed issue/PR ("land PR 7",
  "close out #42"), or when /finish-ticket appears anywhere in the message
argument-hint: <issue-id>
---
Finish issue: **$ARGUMENTS**

**Invoke the `ticket-workflow` skill now via the Skill tool** and run its **FINISH** phase — do not read its `SKILL.md` directly. Treat "$ARGUMENTS" as the issue ID.

This assumes the PR is already reviewed and clean (CI green, review threads resolved, the user has reviewed). First do the skill's **Step 0** to select the tracker adapter, then run the FINISH cycle: smoke test → rebase-merge → clean up worktree/branch → close the issue → record what to watch for.

Invoking this command is the user's **explicit authorization to merge** the reviewed PR. It supersedes any earlier "do not merge / stop at a reviewed PR and report back" hold from a `/start-ticket` briefing or a spawn cap (the profile's `SPAWN_CAP`) earlier in this session — those caps bound the unattended START/SPAWN phases and expire on this invocation. Don't treat them as a standing boundary or refuse the merge on their account.
