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
  log/NNNN-<title>.md     # one file per session: what happened + a "Previously…" recap
  .gm/state.json          # GM-only hidden state (sealed clocks + answers) — only when adapter is visibility: gm
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
One per session, zero-padded index (`0001-the-ember-road.md`). Holds the session's beats and, at the end, a **forward recap** ("Previously…") the next `/gm:play` reads back.

### `.gm/` (the GM screen)
Present only when the active adapter is `visibility: gm` (see adapter-contract). Holds **GM-side hidden state** the player shouldn't see by default — secret clocks, the answer behind a mystery, an NPC's true agenda — in `.gm/state.json`. **Written only through the `campaign gm-*` CLI, never the Write/Edit tools**, so the writes collapse to "Ran 1 shell command" in the transcript instead of rendering inline and spoiling the player. It's versioned with the rest of the campaign (a managed checkpoint commits it) and is *not* encrypted — reading it, or expanding a write to peek, is a deliberate choice (dramatic irony), which is fine. Player-facing systems (`visibility: player`, e.g. Ironsworn) keep their clocks in the open `clocks.md` and have no `.gm/`.

## Rules

- **Disk is truth; context is a cache.** These files are authoritative. The core re-reads them at session start and at decision points, so a long session or a context compaction can't corrupt the campaign — it recovers from disk.
- **The player is referee.** If the player corrects a value, the file wins; reconcile to it.
- **Deltas at wrap.** The play loop stages changes; `/gm:wrap` persists them and writes the session log + recap.
