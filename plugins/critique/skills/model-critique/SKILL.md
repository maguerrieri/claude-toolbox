---
name: model-critique
description: 'Use when asked to critique, review, audit or sanity-check a 3D model or 3D game asset (a low-poly character, building, vehicle, prop or terrain piece), when comparing 3D game models that look alike, or when a 3D model looks "off" and nobody can say why. Read it before giving any opinion of how the model looks, even for a quick take.'
---

# Model critique: describe before judging

## Overview

A critique of a 3D game model that starts from "how does it look?" misses parts
that are in the wrong place: an opinion of the whole model hides them. So the
order is fixed. **Describe where every part is, check each against the real
thing, and only then judge the look.** A handle that floats above the cart bed
is found by reading its position, not by squinting at a render.

A critique changes no model and no game code. It ends in a report and a list
of recommended issues.

## What it needs

The method checks three things against each other, so find each before
starting:

1. **Parts that can be listed and measured.** Each mesh or piece, with a
   position and size in the model's own axes and units.
2. **A reference for what correct is.** The real object the model is drawn
   from (with its real size), the project's design document, and its palette.
   For an invented thing (a dragon, a starship), the reference is its concept
   art or the design document's description, and the rest of the game for
   scale: never dimensions made up for the critique.
3. **A context of use.** The game itself, at the camera angles and zoom people
   play at, with everything else on screen.

One that is thin (no design document, a game that can't be run right now)
doesn't stop the critique: go on with what there is, and say in the report
what was missing and which findings it leaves unverified. A kind with no
separate meshes to log (terrain drawn as instances, say) still has parts:
list its pieces by hand from the views, and say the numbers were read off
them.

## Getting the views and the numbers

The method's steps 1 and 2, below, need renders and a parts log.

- **The project has tools for them** (a lineup page, a turntable, a parts log,
  a screenshot script): use those, and read their documentation for what each
  view and number means.
- **It has none:** render the views and log the parts yourself. A scratch
  script that loads the model, prints each mesh's bounding box, rotation and
  material color in the model's frame, and renders it from fixed cameras is
  enough. The script and its raw output are scratch: keep them out of the
  project's tracked files.
- **Nothing can be run:** work from whatever numbers or images were given.
  The report lists the views it would have rendered, in place of the renders.
  A finding the numbers settle on their own (a wheel's lowest point above the
  ground, a size against the real object) stands as it is. One that needs a
  view to confirm is marked unverified, and names the view that would settle
  it. A bounding box gives a part's extent, not its shape, so whether a sloped
  or rotated part joins its neighbor is one of those.

## The method

Do the steps in order. Finish each, as far as the views and numbers on hand
allow, before starting the next.

1. **Render every view.** Front, side and top (orthographic, one scale), with
   the back and the other side for a model that isn't symmetric; the game
   camera's view from each angle players see the model at (every turn of a
   fixed camera, or a representative set for a free one); and the model in
   the game at the zoom people play at. A model that looks different by state
   (loaded or empty, at work or at rest) gets these for each state. Look at
   every one.
2. **Write down where every part is, before judging anything.** For each part:
   what it is, its position, and which way it faces, in the model's own axes
   and units ("handle: x ±0.10, y 0.14 to 0.26, z −0.26 to 0.02, sloping down
   toward the carter"). The numbers come from the parts log; the views say what
   each part is. A part that two views describe differently is a defect.
3. **Check each part against the real thing.** Is it where it would be on the
   object? Do the wheels touch the ground? Do the handles reach the bed, at the
   height of a hand? Is the door at ground level, on the side the road is? Do
   pieces join, or float, or pass through each other? Check sizes against the
   real object, too.
4. **Only then judge the look.** The silhouette; whether it reads at play
   zoom; whether it can be told from its look-alikes; whether it keeps to the
   palette and the art direction.
5. **Report in this order:** placement defects (position, size, joins), then
   readability, then style (palette and art direction, a wrong color
   included). Each finding names the part, the view that shows it (or, with no
   renders, the numbers that do), and the fix. Where the fix is a choice that
   isn't the critique's to make (the real object's size against the game's own
   scale, say), give the options and the numbers for each. End with the
   recommended issues: one per change worth making, with fixes that one edit
   would make grouped into one issue.

**The report** of a full critique is a document that carries its renders, not
a chat reply that lists file paths. It goes where the project keeps its
reports, renders with it; where the project has no such place, publish it
outside the project's tracked files. The written part list from step 2 goes in
it, ahead of the findings. It is the evidence the placement findings cite, and
writing it is the step that finds them.

**A quick take** asked for in conversation is answered there, in the same
order and shorter: the part list from the views and numbers on hand, placement
findings first, and one line on which views weren't looked at.

## Lessons from earlier critiques

- **The size people actually see is the test that fails most.** A figure 11
  pixels tall can't show a prop a fifth of its height, so roles that differ
  only by a prop look the same. Always look at the model in the real game, not
  only alone on plain ground: the game shows it among everything else.
- **Turn the camera.** Shoot every angle the game shows, alone and in the
  game. A town of buildings that don't turn to face the road shows mostly
  backs from one side.
- **Put look-alikes side by side.** Models that share a silhouette need one
  lineup of their own, viewed at play zoom.
- **Compare sizes across kinds, from numbers.** Views scaled to fit each model
  hide that a person stands twice the height of a door. Read sizes off the
  parts log, or off views that share one scale.
- **Check sizes against the real object.** A cart modeled on a 1.5 m handcart
  with barrow-sized wheels is a placement finding, not a style one.
- **Automatic flags are places to look, not findings.** A "floating" flag is
  true of a bucket with no rope and of a lantern hung on purpose. Look at each
  flagged part, and at the parts no flag names.
- **A shared part reaches further than the model in front of you.** If the
  same piece is drawn elsewhere (a good on a cart, in a storehouse, on a market
  table), check every place it appears.
- **A still render can't show motion.** Gait, turning and animation timing
  need the running game. Say so when the critique didn't cover them.
- **One critique per kind of thing** (people, buildings, vehicles, terrain),
  each written up as its own report.

## Common mistakes

| Mistake | What to do |
|---|---|
| Opening with an overall impression ("looks great", "reads well") | Hold it until step 4. Write the part list first. |
| A quick take that skips the part list | Write the part list anyway, and keep the rest short. |
| Trusting someone's verdict that it looks fine | A verdict on the look says nothing about placement. Run steps 1 to 3 anyway. |
| Reporting each automatic flag as a defect | Look at the part. Report it only if it is wrong on the real object. |
| Fixing the model during the critique | Report the fix and recommend an issue. |

## Outside 3D models

The same order carries over to any artifact that has the three things under
*What it needs*. For a UI screen: the views are every breakpoint and state;
the parts are the elements, each with its box and style read from computed
styles; the reference is the design system; the context is the real page with
real content. Describe each element's box before judging the layout.

Something with no parts to measure at all, or nothing to say what correct is
(a piece of music, a story's tone), is outside this method: critique it
another way.
