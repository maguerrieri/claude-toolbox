# Campaign state schema

A campaign is a folder in **your** space (a directory or an Obsidian vault) — never inside the plugin. The plugin scaffolds it and ships *example* campaigns, but your saves are yours. This file is the format a new campaign follows; the examples are demos to play, not templates to copy (`/gm:new-campaign` never reads them). Markdown throughout, so it stays readable and Obsidian-friendly.

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
  .gm/tables/<type>.md    # sealed GM tables (same format; see .gm/ below)
  .gm/state.json          # GM-only hidden state (sealed clocks + answers) — only when adapter is visibility: gm
```

## Files

### `campaign.md`
Front-matter + prose. Required front-matter:
```
---
adapter: generic         # which system adapter runs this campaign
persona: house           # which GM persona (default: house; added in milestone 3)
saves: ~/rpg/my-campaign # ABSOLUTE path to this campaign in your space
---
```
`saves` is an **absolute** path in your own space. (The example campaigns bundled in the plugin use a repo-relative path only because they ship *inside* the plugin; real campaigns live in your directory or vault.)

Body: `## Premise` (a paragraph), `## Truths` (a `- ` list of established facts about this world), and `## Tone & safety` (genre and tone, then the player's own **Lines:** and **Veils:** — asked at `/gm:new-campaign`, in their words, never defaulted).

A bundled example also lists its proper names in its front-matter (`names: <place>, <person>, …`), for `campaign example-overlap`; your own campaigns don't need it.

### `characters/<name>.md`
One file per PC, in the shape the active adapter's `sheet-template.md` defines. The core never invents a stat that isn't on the sheet (Rule 0).

### `npcs.md`
A list; each NPC gets: name, a one-line description, **what they want** (every NPC wants something), and their current disposition toward the party.

### `threads.md`
Open threads. Each: a title, a one-line description, and a status (`open` / `hot` / `resolved`). The recap and scene-framing pull from here.

### `clocks.md`
Progress clocks the world advances: `Bandits find the camp [▰▰▱▱] 2/4`. Note each clock's **trigger** so it ticks consistently — e.g. `The rival crew reaches the vault [▰▱▱▱] 1/4 — ticks when the party dawdles or the rivals act`. The core ticks a clock when its trigger fires in the fiction.

### `locations.md`
Places visited or known, each with a line of sensory detail so scenes stay grounded.

### `log/NNNN-<title>.md`
One per session, zero-padded index (`0001-the-first-night.md`). Holds the session's beats and, at the end, a **forward recap** ("Previously…") the next `/gm:play` reads back. `/gm:wrap` writes it from the raw log below.

### `log/raw/<YYYY-MM-DD>-<session>.md`
The **raw play log**, written by the plugin's Stop hook after every turn of a session bound to this campaign (`campaign bind`, run by `/gm:play` and `/gm:new-campaign`) — no model action involved. `<session>` is the first 8 characters of the Claude Code session id, and a new file starts each day. Each turn appends `### Player` (the prompt as typed, including a gm command like `/gm:play …`; other slash commands such as `/compact` or `/model` aren't play and are left out) and `### GM` (the GM's visible narration) blocks. **Text only:** tool calls and their results are never logged, so nothing written behind the GM screen (`campaign gm-*`, `.gm/`) reaches it. A managed campaign commits the log and the current state each turn (`autosave: <prompt>`), so every turn is a `/gm:rewind` target; a deferred campaign gets the log but no commits.

It exists so the play record never depends on the model remembering `/gm:wrap`, or on Claude Code keeping its session transcripts (they are deleted after `cleanupPeriodDays`, 30 by default). `/gm:wrap` summarizes it into `log/NNNN-<title>.md`, then appends a `<!-- gm:wrapped log/NNNN-<title>.md -->` marker (`campaign mark-wrapped`; the wrapping session's own file is marked again once the wrap turn is logged, so that turn isn't left after the last marker); `campaign unwrapped` lists everything after each file's last marker — including sessions that were never wrapped at all. Append-only otherwise: don't edit it by hand. (A `/gm:rewind` rolls it back along with the rest of the campaign; the rewound turns stay in git history.)

### `tables/`

Player-facing rollable tables in the `- ` bullet-list format (see adapter-contract: "Tables"). Each file is a `<type>.md` — e.g. `rumors.md`, `weather.md`, `loot.md`. Tables may be hand-authored by the player, generated by `/gm:forge` (bulk prep or on-demand mid-play), or copied from an adapter's `oracles/`. `roll table <campaign>/tables/<type>.md` draws from them. Sealed GM tables that the player shouldn't see live in `.gm/tables/<type>.md` instead (same format; see `.gm/` below) — `/gm:forge --secret` writes there directly.

### `.gm/` (the GM screen)
Present only when the active adapter is `visibility: gm` (see adapter-contract). Holds **GM-side hidden state** the player shouldn't see by default — secret clocks, the answer behind a mystery, an NPC's true agenda — in `.gm/state.json`. **Written only through the `campaign gm-*` CLI, never the Write/Edit tools**, so the writes collapse to "Ran 1 shell command" in the transcript instead of rendering inline and spoiling the player. It's versioned with the rest of the campaign (a managed checkpoint commits it) and is *not* encrypted — reading it, or expanding a write to peek, is a deliberate choice (dramatic irony), which is fine. Player-facing systems (`visibility: player`, e.g. Ironsworn) keep their clocks in the open `clocks.md` and have no `.gm/`.

## Rules

- **Disk is truth; context is a cache.** These files are authoritative. The core re-reads them at session start and at decision points, so a long session or a context compaction can't corrupt the campaign — it recovers from disk.
- **The player is referee.** If the player corrects a value, the file wins; reconcile to it.
- **Deltas as they happen; the story at wrap.** The play loop writes state deltas to disk as the fiction produces them, and the autosave commits them with each turn's raw log; `/gm:wrap` persists anything still staged and writes the curated session log + recap.
