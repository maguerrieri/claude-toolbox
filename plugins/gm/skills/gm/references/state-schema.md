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
```

## Files

### `campaign.md`
Front-matter + prose. Required front-matter:
```
---
adapter: generic         # which system adapter runs this campaign
persona: house           # which GM persona (default: house; added in milestone 3)
saves: ~/rpg/embervale   # this directory, for reference
---
```
Body: the **premise** (a paragraph), the **truths** (established facts about this world), and **tone & safety** (genre, lines & veils).

### `characters/<name>.md`
One file per PC, in the shape the active adapter's `sheet-template.md` defines. The core never invents a stat that isn't on the sheet (Rule 0).

### `npcs.md`
A list; each NPC gets: name, a one-line description, **what they want** (every NPC wants something), and their current disposition toward the party.

### `threads.md`
Open threads. Each: a title, a one-line description, and a status (`open` / `hot` / `resolved`). The recap and scene-framing pull from here.

### `clocks.md`
Progress clocks the world advances: `Bandits find the camp [▰▰▱▱] 2/4`. The core ticks them as consequences land.

### `locations.md`
Places visited or known, each with a line of sensory detail so scenes stay grounded.

### `log/NNNN-<title>.md`
One per session, zero-padded index (`0001-the-ember-road.md`). Holds the session's beats and, at the end, a **forward recap** ("Previously…") the next `/gm:play` reads back.

## Rules

- **Disk is truth; context is a cache.** These files are authoritative. The core re-reads them at session start and at decision points, so a long session or a context compaction can't corrupt the campaign — it recovers from disk.
- **The player is referee.** If the player corrects a value, the file wins; reconcile to it.
- **Deltas at wrap.** The play loop stages changes; `/gm:wrap` persists them and writes the session log + recap.
