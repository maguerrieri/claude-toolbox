---
description: Use when asked to finish, land, merge, or close out a reviewed issue/PR ("land PR 7", "close out #42"), or when /finish-ticket appears anywhere in the message
argument-hint: <issue-id>
---
Finish issue: **$ARGUMENTS**

**Invoke the `ticket-workflow` skill now via the Skill tool** and run its **FINISH** phase — do not read its `SKILL.md` directly. Treat "$ARGUMENTS" as the issue ID.

This assumes the PR is already reviewed and clean (CI green, review threads resolved, the user has reviewed). First do the skill's **Step 0** to select the tracker adapter, then run the FINISH cycle: smoke test → rebase-merge → clean up worktree/branch → close the issue → record what to watch for.
