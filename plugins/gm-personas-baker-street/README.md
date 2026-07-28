# gm-personas-baker-street

A **persona pack** for the [`gm`](../gm) plugin: voices only, no mechanics, no rules.

Ships one persona — **`watson`**, the chronicler's voice, synthesized from the
public-domain Sherlock Holmes stories (see `NOTICE`). He narrates a session the way he
narrated the cases: retrospectively, in the first person, precise about the hour,
clinical about people and then kind about them.

```
plugins/gm-personas-baker-street/
  personas/watson/persona.md    # the whole payload
  hooks/                        # the one-line handshake with gm
```

## Install

Enable it alongside `gm`. Nothing else to configure — the pack's `SessionStart` hook
appends its own `personas/` to `$GM_PERSONA_PATH`, so `gm` finds `watson` by bare name:

```yaml
# <campaign>/campaign.md
---
adapter: generic
persona: watson
saves: ~/rpg/<name>
---
```

The hook **appends**, so anything you set yourself keeps priority: a
`<campaign>/personas/watson/` of your own, or a dir already on your `$GM_PERSONA_PATH`,
still wins. `gm` takes the first entry that holds the named `persona.md`.

No `Bash(...)` allowlist entry is needed — this pack ships no CLI.

## Why a pack works at all

`gm` resolves a bare `persona:` name campaign-local → `$GM_PERSONA_PATH` → its own
`personas/`. Claude Code has no cross-plugin discovery API, so a hook-set search path
is the only clean handshake between a pack and the engine — which is exactly what
`hooks/persona-path.sh` does, in about four lines.

## The contract still applies

A persona shapes **voice only, never numbers** — see
[`gm`'s persona contract](../gm/skills/gm/references/persona-contract.md). Living
outside the `gm` plugin changes nothing about that.

Lint this pack against the same check the shipped personas run:

```
python3 ../gm/bin/validate-adapter --personas --all personas
```

Note what that check *is*: front-matter (`name` + `chronicle_identity`) plus a short
deny-list of system-mechanic phrases. It's a smoke test, not enforcement — it can't
tell that prose is voice-only. A persona is text the GM adopts as instruction, so read
one before you run it.

## Writing another one

Add `personas/<name>/persona.md` with `name` and `chronicle_identity` front-matter, and
a body covering voice, temperament, descriptive density, humor, and content
sensibilities. Use a **literal** email in `chronicle_identity` — the `${identity_domain}`
placeholder resolves only for `gm`'s own personas.
