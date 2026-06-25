# Persona contract

A **persona** is the GM's *voice* — tone, refereeing temperament, descriptive density, humor, content sensibilities. It is **orthogonal to the system adapter**: any persona runs any system (the full cross-product). Adapter = *what game*; persona = *who's running it*.

## The one hard boundary

**A persona shapes voice and emphasis only — never numbers.** It must not change a stat, a difficulty, an outcome, or any mechanic. A grognard *narrates* lethally but obeys the same dice and the same adapter rules as everyone else. This is what keeps personas composable with every adapter and keeps Rule 0 intact. A persona authored with any system-specific mechanic is a contract violation.

## Folder

```
personas/<name>/persona.md
```

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

At session start the core reads `persona:` from `campaign.md` (default `house`), loads `personas/<name>/persona.md`, and narrates the whole session in that voice — applying it to scene framing, NPC dialogue, and outcome narration. The persona never enters the *mechanical* path (deciding rolls, reading the adapter, writing state); it only colors the prose. Switching personas mid-campaign changes the voice, nothing else.
