# Campaign state schema

A campaign is a folder in **your** space (a directory or an Obsidian vault) — never inside the plugin. The plugin scaffolds it and ships *example* campaigns, but your saves are yours. Markdown throughout, so it stays readable and Obsidian-friendly.

## Layout

```
<campaign>/
  campaign.md             # premise, truths, tone, active adapter + persona, saves metadata
  characters/<name>.md    # one file per player character (shape from the adapter's sheet-template)
  npcs.md                 # named NPCs: who they are, what they want
  threads.md              # open threads / quests / vows, each with a status
  clocks.md               # progress clocks / countdowns (segments filled)
  locations.md            # places, with a line of sensory detail each
  tables/<type>.md        # player-facing rollable tables (hand-authored or forged)
  log/NNNN-<title>.md     # one file per session: what happened + a "Previously…" recap
  log/raw/<date>-<session>.md  # autosaved every turn: the player's prompts + the GM's narration
  .gm/tables/<type>.md    # sealed GM tables (same format once unsealed; see .gm/ below)
  .gm/state.json          # GM-only hidden state (hidden clocks + sealed answers) — only when adapter is visibility: gm
  .gm/forge/, .gm/inbox/  # the gm:screen subagent's drafts; consumed as it seals them
```

## Files

### `campaign.md`
Front-matter + prose. Required front-matter:
```
---
adapter: generic         # which system adapter runs this campaign
persona: house           # which GM persona (default: house; added in milestone 3)
saves: ~/rpg/embervale   # ABSOLUTE path to this campaign in your space
---
```
`saves` is an **absolute** path in your own space. (The example campaigns bundled in the plugin use a repo-relative path only because they ship *inside* the plugin; real campaigns live in your directory or vault.)

Body: the **premise** (a paragraph), the **truths** (established facts about this world), and **tone & safety** (genre, lines & veils).

### `characters/<name>.md`
One file per PC, in the shape the active adapter's `sheet-template.md` defines. The core never invents a stat that isn't on the sheet (Rule 0).

### `npcs.md`
A list; each NPC gets: name, a one-line description, **what they want** (every NPC wants something), and their current disposition toward the party.

### `threads.md`
Open threads. Each: a title, a one-line description, and a status (`open` / `hot` / `resolved`). The recap and scene-framing pull from here.

### `clocks.md`
Progress clocks the world advances: `Bandits find the camp [▰▰▱▱] 2/4`. Note each clock's **trigger** so it ticks consistently — e.g. `The Ashwood creeps closer [▰▱▱▱] 1/4 — ticks when the party delves deeper or the threat acts`. The core ticks a clock when its trigger fires in the fiction.

### `locations.md`
Places visited or known, each with a line of sensory detail so scenes stay grounded.

### `log/NNNN-<title>.md`
One per session, zero-padded index (`0001-the-ember-road.md`). Holds the session's beats and, at the end, a **forward recap** ("Previously…") the next `/gm:play` reads back. `/gm:wrap` writes it from the raw log below.

### `log/raw/<YYYY-MM-DD>-<session>.md`
The **raw play log**, written by the plugin's Stop hook after every turn of a session bound to this campaign (`campaign bind`, run by `/gm:play` and `/gm:new-campaign`) — no model action involved. `<session>` is the first 8 characters of the Claude Code session id, and a new file starts each day. Each turn appends `### Player` (the prompt as typed, including a gm command like `/gm:play …`; other slash commands such as `/compact` or `/model` aren't play and are left out) and `### GM` (the GM's visible narration) blocks. **Text only:** tool calls and their results are never logged, so nothing written behind the GM screen (`campaign gm-*`, `.gm/`) reaches it. A managed campaign commits the log and the current state each turn (`autosave: <prompt>`), so every turn is a `/gm:rewind` target; a deferred campaign gets the log but no commits.

It exists so the play record never depends on the model remembering `/gm:wrap`, or on Claude Code keeping its session transcripts (they are deleted after `cleanupPeriodDays`, 30 by default). `/gm:wrap` summarizes it into `log/NNNN-<title>.md`, then appends a `<!-- gm:wrapped log/NNNN-<title>.md -->` marker (`campaign mark-wrapped`; the wrapping session's own file is marked again once the wrap turn is logged, so that turn isn't left after the last marker); `campaign unwrapped` lists everything after each file's last marker — including sessions that were never wrapped at all. Append-only otherwise: don't edit it by hand. (A `/gm:rewind` rolls it back along with the rest of the campaign; the rewound turns stay in git history.)

### `tables/`

Player-facing rollable tables in the `- ` bullet-list format (see adapter-contract: "Tables"). Each file is a `<type>.md` — e.g. `rumors.md`, `weather.md`, `loot.md`. Tables may be hand-authored by the player, generated by `/gm:forge` (bulk prep or on-demand mid-play), or copied from an adapter's `oracles/`. `roll table <campaign>/tables/<type>.md` draws from them. Sealed GM tables that the player shouldn't see live in `.gm/tables/<type>.md` instead (sealed on disk; see `.gm/` below) — `/gm:forge --secret` writes there, through the `gm:screen` subagent.

### `.gm/` (the GM screen)
Present only when the active adapter is `visibility: gm` (see adapter-contract). Holds **GM-side hidden state** the player shouldn't see by default — secret clocks, the answer behind a mystery, an NPC's true agenda — in `.gm/state.json`, plus sealed tables in `.gm/tables/`.

- **Sealed at rest.** Every file under `.gm/` is stored sealed: a `gm-sealed v1` header line, then the base64 of its zlib-compressed text. It's obfuscation against a glance, not encryption: Claude Code's diff of a file a Bash command changed, `cat`, an editor or `git diff` shows noise instead of the secret. `campaign gm-reveal` / `gm-list` and `roll table` read it. `state.json` is JSON once unsealed (`{"clocks": {<id>: {"filled", "segments"}}, "secrets": {<id>: <text>}}`); a table is the usual `- ` list.
- **Written only by the CLIs, and a secret's text only from inside the `gm:screen` subagent.** Clocks through `campaign gm-clock`; an answer through `gm:screen`, which drafts it with the Write tool under `.gm/inbox/` and seals it with `campaign gm-seal --from` (the draft is deleted); a sealed table through `forge harvest --consume` from a draft under `.gm/forge/`. Never the Write/Edit tools in the GM's own session, and never a secret in a command's text: both are in the player's transcript.
- **Legacy plaintext is read as-is**, and sealed on the next write to it. The plugin's Stop and SessionStart hooks also seal any plaintext left under a bound campaign's `.gm/` (from an older version, or a draft a crashed subagent left), out of any tool call's diff; `campaign gm-migrate <dir>` does the same on demand. Rewinding to a checkpoint from before sealing seals the restored files within the rewind. Git history from before sealing still holds the plaintext.

It's versioned with the rest of the campaign (a managed checkpoint commits it). Reading a secret early is a deliberate choice (dramatic irony), which is fine. Player-facing systems (`visibility: player`, e.g. Ironsworn) keep their clocks in the open `clocks.md` and have no `.gm/`.

## Rules

- **Disk is truth; context is a cache.** These files are authoritative. The core re-reads them at session start and at decision points, so a long session or a context compaction can't corrupt the campaign — it recovers from disk.
- **The player is referee.** If the player corrects a value, the file wins; reconcile to it.
- **Deltas as they happen; the story at wrap.** The play loop writes state deltas to disk as the fiction produces them, and the autosave commits them with each turn's raw log; `/gm:wrap` persists anything still staged and writes the curated session log + recap.
