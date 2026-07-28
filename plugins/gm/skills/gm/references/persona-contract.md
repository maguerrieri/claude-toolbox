# Persona contract

A **persona** is the GM's *voice* — tone, refereeing temperament, descriptive density, humor, content sensibilities. It is **orthogonal to the system adapter**: any persona runs any system (the full cross-product). Adapter = *what game*; persona = *who's running it*.

## The one hard boundary

**A persona shapes voice and emphasis only — never numbers.** It must not change a stat, a difficulty, an outcome, or any mechanic. A grognard *narrates* lethally but obeys the same dice and the same adapter rules as everyone else. This is what keeps personas composable with every adapter and keeps Rule 0 intact. A persona authored with any system-specific mechanic is a contract violation.

## Folder

```
personas/<name>/persona.md
```

That's the shape wherever a persona lives — see **Where personas are found** for which
`personas/` root a given `persona:` value points at.

## Where personas are found

A persona is **not** plugin-bound. `persona:` in `campaign.md` resolves two ways:

**Path-valued** — a value containing `/`, or starting with `~`, `.`, or `/`, *is* the persona
directory (`~` expanded; a relative value resolved against the campaign folder). No search.

**Bare name** — searched in order, taking the first that actually holds a readable
`persona.md` (a directory without one is not a match — the search continues, so a stray empty
folder can't shadow a working persona):

1. `<campaign>/personas/<name>/`
2. each colon-separated entry of `$GM_PERSONA_PATH`, as `<entry>/<name>/` — `~` expanded in an
   entry, empty entries skipped
3. `${CLAUDE_PLUGIN_ROOT}/personas/<name>/`

The plugin is **last**, so a shipped name keeps resolving unless something deliberately
shadows it. An unresolvable persona is an error that names every path tried — never a silent
fallback to `house`. `$GM_PERSONA_PATH` is set the same way `identity/README.md` sets
`$GM_IDENTITY_DOMAIN` — env var, typically via direnv — so direnv stays the one local-config
surface.

Three places a persona can live, all equally valid:

| Scope | Lives in | Selected by |
|---|---|---|
| One campaign | `<campaign>/personas/<name>/persona.md` | `persona: <name>` — travels with the save, versioned by `campaign checkpoint` |
| All your campaigns | a personal dir, e.g. `~/rpg/personas/` | `export GM_PERSONA_PATH=~/rpg/personas` in `.envrc` |
| Shared with others | a **persona pack** plugin shipping only `personas/` | a `SessionStart` hook appending its `${CLAUDE_PLUGIN_ROOT}/personas` to `GM_PERSONA_PATH` via `$CLAUDE_ENV_FILE` |

**The contract doesn't move.** Wherever the file came from, a persona is still voice-only and
still can't touch numbers — the hard boundary above holds, so the adapter × persona
cross-product is intact for out-of-tree personas too.

**The linter is a smoke test, not enforcement.** `bin/validate-adapter --personas <dir>` (and
`--all <root>`) take arbitrary paths, so a pack can run the same check the shipped personas
run — front-matter `name` + `chronicle_identity`, and a short deny-list of Ironsworn mechanic
phrases. That deny-list is all it knows: a persona naming some *other* system's numbers, or
telling the GM to override the adapter outright, passes clean. Nothing mechanical upholds the
boundary. **A persona is prose the GM adopts as instruction, so read one before you run it —
most of all one you didn't write.** A shipped persona got review in this repo; an out-of-tree
one got whatever review its author gave it.

**Identity wrinkle for out-of-tree personas.** `${identity_domain}` interpolation reads the
*plugin's* `identity/identity.json`, so an external persona should write a **literal** email in
`chronicle_identity` rather than rely on the placeholder resolving.

## `persona.md`

Front-matter:
```
---
name: house
chronicle_identity:
  author: House GM
  email: house@${identity_domain}     # used for the campaign git commit identity (milestone 4)
  avatar: assets/avatars/house.png
---
```
`${identity_domain}` resolves from `$GM_IDENTITY_DOMAIN` (e.g. via direnv), else a gitignored `identity/identity.local.json`, else the committed `identity/identity.json` default (`gm.invalid`, non-routable); see `identity/README.md`. Provisioning the aliases + Gravatars that make those avatars render is **follow-on infra** — personas work without it.

Body — voice only, with no reference to any system's mechanics or terms:
- **Voice** — how this GM sounds (diction, rhythm, register).
- **Temperament** — how harsh a cost feels, how lethal the *narration* runs, how much it pushes vs. follows.
- **Descriptive density** — terse vs. lush.
- **Humor** — dry / warm / none / absurd.
- **Content sensibilities** — default lines & veils leanings (the player's stated lines always win).

## How the core uses it

At session start the core reads `persona:` from `campaign.md` (default `house`), resolves it to a folder per **Where personas are found** above, loads that folder's `persona.md`, and narrates the whole session in that voice — applying it to scene framing, NPC dialogue, and outcome narration. The persona never enters the *mechanical* path (deciding rolls, reading the adapter, writing state); it only colors the prose. Switching personas mid-campaign changes the voice, nothing else.
