---
description: >-
  Use when asked to file, create, or write up an issue/ticket from the current discussion
  ("make a ticket for this", "file an issue for that bug"), including compound
  create-and-run requests ("file an issue and spawn it", "make a ticket and start on it"),
  or when /make-ticket appears anywhere in the message
argument-hint: <description> [--risk docs|low|normal|high] [--spawn | --start]
---
Make a ticket for: **$ARGUMENTS**

**Invoke the `ticket-workflow` skill now via the Skill tool** and run its **FILE** mini-phase — do not read its `SKILL.md` directly. Parse "$ARGUMENTS" as the issue description plus an optional risk flag and at most one routing flag. `--risk docs|low|normal|high` sets the issue's **risk class** (default `normal` when omitted); any other value is a hard error — stop before searching or creating anything. Routing: `--spawn` (file, then hand the new ID to the SPAWN phase — a background `/start-ticket` session) or `--start` (file, then run the START phase on it inline in this session). No routing flag → file the issue and stop.

First do the skill's **Step 0** to select the tracker + profile, then FILE: compose the issue title + body from the **conversation context** (motivation, scope, acceptance shape, links to related issues/PRs — not just the description above), check for existing open duplicates via the tracker's `SEARCH` op (per FILE Step 2 — surface hits interactively; note-and-file when unattended; non-fatal on failure), create it via the tracker's `CREATE` op with the resolved `risk:<class>` label as a **required** label (per FILE Step 3 — a repo missing that label fails the command loudly; it never files an unclassified issue), and report the new ID + URL. With `--spawn` or `--start`, complete that handoff **in the same turn** — never park it behind the report or a clarifying question.
