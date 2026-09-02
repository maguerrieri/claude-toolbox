---
description: >-
  Use when asked to file, create, or write up an issue/ticket from the current discussion
  ("make a ticket for this", "file an issue for that bug"), including compound
  create-and-run requests ("file an issue and spawn it", "make a ticket and start on it"),
  or when /make-ticket appears anywhere in the message
argument-hint: '<description> [--spawn | --start] [--harness codex|claude] [--surface desktop|cli|cloud]'
---
Make a ticket for: **$ARGUMENTS**

**Invoke the `ticket-workflow` skill now via the Skill tool** and run its **FILE** mini-phase — do not read its `SKILL.md` directly. Parse "$ARGUMENTS" as the issue description plus at most one action flag: `--spawn` (file, then hand the new ID to the SPAWN phase — a background `/start-ticket` task) or `--start` (file, then run the START phase on it inline in this session). No action flag → file the issue and stop. Optional `--harness codex|claude` and `--surface desktop|cli|cloud` flags are valid only with `--spawn`; pass them as launch metadata to SPAWN and remove them from the issue body and child prompt.

First do the skill's **Step 0** in its authoritative order: select and read the active harness adapter, then select and read the tracker + profile. This resolves the active `MESSAGE`, `INSPECT`, and `ATTRIBUTION` operations before the phase uses them. Then run FILE: compose the issue title + body from the **conversation context** (motivation, scope, acceptance shape, links to related issues/PRs — not just the description above), check for existing open duplicates via the tracker's `SEARCH` op (per FILE Step 2 — surface hits interactively; note-and-file when unattended; non-fatal on failure), create it via the tracker's `CREATE` op, and report the new ID + URL. With `--spawn` or `--start`, complete that handoff **in the same turn** — never park it behind the report or a clarifying question. `/make-ticket --spawn` delegates both launch axes to generic `spawn`.
