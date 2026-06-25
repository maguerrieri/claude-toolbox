---
name: generate
description: Bulk-ideate a diverse, axis-tagged pool of candidates for an open-ended content type (game factions, event tables, product names, NPCs, test scenarios, …) without the LLM "mode-collapse" that turns "give me 30 X" into 30 reskins of one idea. Runs a morphological-analysis loop — frame → diversity-prompted parallel passes → axis-tag → cluster — with judgment OFF (capture, don't decide). Use to generate/expand a batch of a type, affinity-cluster a pool for gaps, or scaffold a new type's frame. A contested item promotes to your decision process via a pluggable Promotion adapter.
---

# Generate (the reservoir loop)

Turn a **content type + a count** into a **diverse, axis-tagged pool** of
candidates, captured into a running reservoir file. This is the **divergent**
counterpart to a **convergent** decision process: it never closes (a roster is
many *coexisting* items), and it hands off to a decision only at one seam —
[promotion](#promotion-the-one-seam-to-a-decision), which is **pluggable** (Step 0).

Grounding for every rule here is the vendored
[`references/generation-research.md`](references/generation-research.md)
(morphological analysis / Zwicky; Osborn deferred-judgment + Sylvester's
ideas-reservoir; affinity/KJ clustering; SCAMPER; and the measured LLM
mode-collapse problem with its validated countermeasures).

## The one rule: judgment is off

> **You capture; you do not decide.** Nothing is rejected *for quality*, nothing
> is ranked, "which is best" is not this skill's question. Killed ideas go to
> **cold storage**, not the trash. The moment you catch yourself converging —
> picking a winner, cutting the field to one — **stop**: that item has become a
> *decision*, and the move is to [promote it](#promotion-the-one-seam-to-a-decision),
> not to decide it here.

This is the load-bearing constraint (Osborn's "defer judgment"; the Double
Diamond's "don't diverge and converge at once"). Generation and decision stay
separate modes — mixing them is "driving with the brakes on," and it degrades both.

## Step 0: Select the Promotion adapter

The **promotion seam** — how a contested item hands off to a decision process —
is pluggable. Pick an adapter, **highest priority first**:

1. **Project memory / agent config** — a `Promotion:` directive, if your harness
   surfaces one.
2. **Repo `CLAUDE.md`** (or `.claude/CLAUDE.md`) — a `Promotion:` line.
3. **Default** → `inline` (surfaces the decision to the human, creates nothing —
   safe anywhere, no infra).

A **bare name** maps to `promotion/<name>.md` bundled here — `inline`,
`github-issue`, or `adr`. A **path** is read directly: that's how a project wires
its *own* decision tooling (e.g. an ADR-scaffolding skill, an RFC template, a
Linear/Jira ticket) without it living in this plugin. **Read the selected file**
and use its `OPEN` / `BACKLINK` ops at the [promotion seam](#promotion-the-one-seam-to-a-decision).
See [Writing a custom Promotion adapter](#writing-a-custom-promotion-adapter) for
the op contract.

## When to use it

- "**Generate / brainstorm / give me N** `<things>`" → **`generate`** mode (default).
  (`<things>` = any open-ended type: factions, events, NPCs, item or product
  names, quest hooks, test scenarios, user personas, world locations, …)
- "**What themes are over-represented** in the pool? **What's missing?**"
  → **`cluster`** mode (affinity/KJ over the current reservoir).
- "We need a **new content type** — scaffold its axes" → **`frame`** mode.

**Don't** use it to *decide* anything (that's the human + your decision process,
reached via the Promotion adapter), to *critique options toward a winner*, or to
*edit your canon/source-of-truth* (the reservoir feeds those; it isn't them).

## Inputs

- **`<type>`** — the content type, mapping to a reservoir file
  `docs/generation/<type>.md` (one file per type — this path is the plugin's
  convention, used by `/generate` and the `frame` scaffolder alike).
- **count `N`** — how many candidates to aim for this run (default ~15–30).
- For `frame` mode: the new type's name + a sentence on what it's for.

If the reservoir file doesn't exist yet, run **`frame`** first — don't generate
against a missing frame; that's how you get samey output.

## `generate` mode (default)

The discipline below is what defeats mode collapse — follow it exactly.

1. **Load the frame, not the favorites.** Read the **morphological frame** at the
   top of the type's reservoir file (its axes + values). **Do NOT read the
   existing entries in as examples**, and never paste reservoir favorites into a
   generation prompt — seeding with examples *measurably worsens* diversity
   (0.377 → 0.403–0.432 cosine similarity in the research). Grounding rides the
   **axes**, not example outputs.
2. **Run 3–4 *independent, lens-varied* passes — in parallel, blind to each
   other.** Anchoring is the enemy: the first idea silently collapses the space.
   If your harness can dispatch parallel subagents in isolation, give **each**
   only the frame + one distinct lens, none seeing the others' output; otherwise
   run **sequential
   passes in separate contexts** — never one long thread (it anchors on its own
   earlier output). Vary the lens per pass — a different **persona** (vary stance
   and vantage: a skeptic vs. an enthusiast, an insider vs. an outsider, a
   different discipline or era) or a **random seed word** (forced connection /
   de-fixation). Hybrid prompting + diverse personas are the two strongest
   measured countermeasures; their pools barely overlap, so the union is broad.
3. **Each pass uses the Chain-of-Thought diversity prompt** (the single
   best-validated prompt in the research):
   > "List `N` short `<type>` titles, each a distinct path through these axes:
   > `<axes>`. Then go through the list and decide whether the ideas are
   > different and bold; **make them bolder and more different — no two alike.
   > This is important.** Then expand each to 1–3 sentences and tag it with its
   > axis-values."
   Green-hat only: generate and self-critique-for-sameness, **never** for quality.
4. **Pool, dedupe, axis-tag, append.** Combine the passes. **Merge only
   near-identical** items (when in doubt, keep both — diversity beats tidiness).
   Tag every survivor with its full axis-line, plus any **per-type anchor** the
   frame's tagging format defines. **Append** to the `## Reservoir` section —
   **never overwrite**; nothing is rejected *for quality* (incoherent cells go to
   cold storage with a `CCA: incoherent` note — see step 5, not the trash).
5. **Honor the type's shape constraints.** Read and respect any "what a `<type>`
   *is*" rules at the top of the frame (the invariants a candidate must satisfy to
   be coherent). A candidate that breaks the shape is incoherent, not bold — but
   that's a *coherence* prune, not a quality kill: capture it to **cold storage**
   with a `CCA: incoherent` note (judgment stays off; nothing is deleted), don't
   silently drop it.
6. **Mutate on request (SCAMPER).** To deepen a spark rather than widen the pool,
   run it through SCAMPER. It operates on the item's *structure*, so it's
   **type-agnostic**: **S**ubstitute an axis-value, **C**ombine it with another
   item, **A**dapt a pattern from elsewhere, **M**odify/magnify an axis to an
   extreme, **P**ut it to another use, **E**liminate a component, **R**everse a
   relationship or goal — then append the mutations as new entries. Which lenses
   pay off varies by type; the per-type frame can note its strong ones.

**Done when:** ≥`N` axis-tagged candidates are appended, they spread across the
axis values (not clustered on two or three), every entry's tags are specific, and
at least several are paths you wouldn't have reached by iterating the obvious one.
Run the [self-check](#guardrails-self-check) before claiming done.

## `cluster` mode (affinity / KJ — the gap finder)

Over the **current** `## Reservoir`:

1. Cluster entries by **natural theme** (gut-feel similarity; do not impose
   predetermined categories). Name each cluster only **after** it emerges.
2. Report: which **themes are over-represented**, and — reading the clusters
   against the frame's axes — which **axis-regions are empty** (values, or
   value-combinations, that no entry occupies).
3. Hand the gaps back as **targets for the next `generate` run** (e.g. "no entry
   takes value X on axis Y — generate a pass aimed at that gap"). `cluster`
   **finds shape; it never kills** — pruning stays a human keep/kill call.

A useful diagnostic, not just a report: **one mega-cluster means the axes aren't
orthogonal** — revisit the frame (`frame` mode), not generate more.

## `frame` mode (scaffold a new content type)

For a type that has no reservoir yet:

1. Define **4–6 orthogonal axes**, **3–5 values each** (Zwicky). Derive them from
   your project's **source of truth** (domain knowledge, design docs) by its
   **shape**, *not* by copying existing example items in as seeds. Axes must vary
   **independently** — test each pair: can you move one without moving the other?
   If not, they're not orthogonal; pick better ones.
2. Note any **shape constraints** the type must honor, and any **per-type anchor**
   (a coordinate in a separate model the items attach to) if it has one.
3. Scaffold `docs/generation/<type>.md`: the frame table, the tagging format, an
   empty `## Reservoir`, and an empty `## Cold storage` section.
4. **Stop there** — `frame` scaffolds; it does not generate. Run `generate` next.

## Promotion: the one seam to a decision

The reservoir is divergent and never closes — **except** at promotion. When two
pooled items can no longer coexist (they compete for **one slot**: a single
canonical role, a fixed UI affordance, a mechanic that can only resolve one way),
that item has become a **decision**.

**The trigger is in the *request*, not the pool.** A `generate` / `cluster` /
`frame` run **never** promotes — those are divergent, and a pile of coexisting
candidates creates no pressure to choose. Promotion fires when the user's intent
flips from *"give me more"* to *"which of these"* — phrasings like **narrow · rank
· pick · cut to N · make this canon · there can only be one**. That flip is the
doorbell; the pool just sitting there is not.

> **Don't answer a convergent request by choosing.** When you catch the flip, do
> **not** comply by picking a winner — that's authority you don't have. Recognize
> it, name the contested `slot`, and route the rivals through the Promotion
> adapter. Your job is the *handoff*, not the verdict.

1. **Stop generating around it.** The stall ("which of these is best?") is the
   tell that you've drifted from divergence into convergence.
2. **`OPEN(type, slot, rivals)`** via the [selected Promotion adapter](#step-0-select-the-promotion-adapter)
   — open the decision artifact for the contested slot (the current reservoir
   `type` passed as context), seeded with the competing pooled items as its
   **starting options**. The reservoir *feeds* the decision's
   divergence; it never *is* it.
3. **`BACKLINK(ref)`** — record in the reservoir (cold storage) that these items
   promoted out to `<ref>`. The losers **stay** (in cold storage or the pool) —
   promotion doesn't delete them; the decision record preserves the rejected
   branches, and the pool keeps the rest alive.

Promotion is a moment to *recognize*, not a step to rush.

### Writing a custom Promotion adapter

An adapter is a small markdown file defining two ops the seam calls. Bundled ones
live in [`promotion/`](promotion/); point `Promotion:` at a **path** to use your
own (e.g. to wire an ADR/RFC skill or a tracker):

- **`OPEN(type, slot, rivals)`** — create the decision artifact for the contested
  `slot`. `type` is the **current reservoir's content type**, passed as calling
  context — use it to label the record (e.g. "promoted from the `<type>`
  reservoir"). Seed the artifact with `rivals` (the competing items, verbatim with
  their tags) as its starting options. Return a reference (an issue URL, a file
  path, an ADR number, or "(surfaced to the human)").
- **`BACKLINK(ref)`** — how to note, back in the **current `type`'s** reservoir
  cold storage, that these items promoted to `<ref>` so the trail persists.

Keeping the seam in an adapter means this plugin carries no assumption about
*your* decision process — swap the file, not the skill.

## Guardrails (self-check)

| Symptom | Cause | Fix |
|---|---|---|
| Output is visibly **samey** | skipped the frame, or seeded with examples | re-frame the axes; strip every example idea from the prompts |
| `cluster` shows **one mega-cluster** | axes aren't truly orthogonal | revisit the frame (`frame` mode); pick independently-varying axes |
| You're stalling on **"which is best"** | you drifted into convergence | **promote** the contested item; resume generating |
| You're **asked to rank / narrow / pick / "make canon"** from the pool | the *request* flipped divergent → convergent — that's the promotion trigger | don't choose; name the slot + route the rivals via the Promotion adapter (`OPEN`) |
| Late-run output feels **exhausted / repetitive** | past the ~500–750-idea diversity cliff | start a **fresh session** with a new lens/persona; don't push one long thread |

Two more standing rules: **temperature is a weak lever** (don't reach for it to
fix diversity — the frame + lens-varied passes do the real work), and a
generation scaffold **rots without a downstream use** — the promotion seam is what
keeps the reservoir a pipeline, not a graveyard.

## Boundaries

| Not this skill | Owner |
|---|---|
| Decide / converge / rank / pick a winner | the **human** + your decision process (reached via the Promotion adapter) |
| Critique options *toward a decision* | a design-decision / critique step, if your project has one |
| Open / scaffold the decision record | the **Promotion adapter** (`OPEN`) |
| Edit your canon / source-of-truth | your project's authoritative docs (the reservoir *feeds* them; it isn't them) |

This skill produces **candidates** — judgment-off, coexisting, axis-tagged. What
becomes canon is always a separate, convergent step it hands off to.

## Benchmark (is the loop earning its keep?)

A run clears the bar when:

- the pool **spreads across the axis values** (a `cluster` pass finds more than
  one or two themes, and points at real empty regions), and
- it **surfaces at least one candidate you wouldn't have generated solo** — a
  non-obvious path through the box, not a reskin of the obvious answer.

If a run produces only obvious near-duplicates, the diverge step didn't defeat
anchoring: re-run with genuinely independent, lens-varied passes, or fix the frame.
