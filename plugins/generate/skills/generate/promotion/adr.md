# Promotion adapter: adr

Scaffolds a plain **MADR-style** decision record as an in-repo markdown file — no
dependency on any ADR tooling. Good when decisions live as records next to the
code. Select with `Promotion: adr`.

> If your project already has an ADR-scaffolding **skill** (numbering, templates,
> an index), don't use this generic writer — point `Promotion:` at a small
> **custom adapter file** that calls your skill instead (see the skill's
> [Writing a custom Promotion adapter](../SKILL.md#writing-a-custom-promotion-adapter)).
> Keeping project-specific wiring in *your* config, not this plugin, is the whole
> point of the adapter seam.

## OPEN(type, slot, rivals)

Write `docs/decisions/NNNN-<kebab-slot>.md` (NNNN = next unused number, scanning
the dir; `0001` if the dir is new) from this template, filling the rivals into
**Considered Options**:

```markdown
# NNNN — <slot>

- **Status:** OPEN
- **Date:** <date>
- **Promoted-from:** <type> reservoir

## Context
Two pooled <type> candidates now compete for one slot: <slot>. They were captured
divergently (judgment off); this record converges them (judgment on).

## Considered Options
### <rival 1 name>
- **Axes:** <axis-tags>
- <gist — pros/cons for the decider to fill>

### <rival 2 name>
- **Axes:** <axis-tags>
- <gist — pros/cons for the decider to fill>

## Decision
_Pending — the human decides._
```

Return the file path.

## BACKLINK(ref)

Add one line under the reservoir's `## Cold storage` section:

```
promoted <date>: <slot> → <ADR path>
```

The rivals stay in the pool / cold storage; nothing is deleted (kill ≠ delete) —
and the record's Considered Options preserves the rejected branch anyway.
