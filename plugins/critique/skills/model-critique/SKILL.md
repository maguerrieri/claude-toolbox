---
name: model-critique
description: 'Use when asked to critique, review, audit or sanity-check a 3D model or game asset (a low-poly character, building, vehicle, prop or terrain piece), when comparing game models that look alike, or when a model looks "off" and nobody can say why. Read it before giving any opinion of how the model looks, even for a quick take.'
---

# Model critique: describe before judging

## Overview

A critique of a 3D game model that starts from "how does it look?" misses parts
that are in the wrong place: an opinion of the whole model hides them. So the
order is fixed. **Describe where every part is, check each against the real
thing, and only then judge the look.** A handle that floats above the cart bed
is found by reading its position, not by squinting at a render.

A critique changes no code and no model. It ends in a report and a list of
recommended issues.

## What it needs

The method works on anything that has these three. Find each before starting,
and say in the report which one was missing or thin:

1. **Parts that can be listed and measured.** Each mesh or piece, with a
   position and size in the model's own axes and units.
2. **A reference for what correct is.** The real object the model is drawn
   from (with its real size), the project's design document, and its palette.
3. **A context of use.** The game itself, at the camera angles and zoom people
   play at, with everything else on screen.

**Use the project's own tools first.** If the project has a lineup page, a
turntable, a parts log or a screenshot script, use it for steps 1 and 2 and
read its documentation for what each view and number means. Otherwise render
the views and log the parts yourself: a script that loads the model, prints
each mesh's bounding box in the model's frame, and renders it from fixed
cameras is enough. If nothing can be run, the report lists the views it would
have rendered in place of the renders. A finding read straight off the parts'
numbers stands as it is, and one that needs a view to confirm is marked
unverified, with the view that would settle it.

## The method

Do the steps in order. Finish each before starting the next.

1. **Render every view.** Front, side and top (orthographic, one scale); the
   game camera's three-quarter view at each turn it can take; and the model in
   the game at the zoom people play at. Look at every one.
2. **Write down where every part is, before judging anything.** For each part:
   what it is, its position, and which way it faces, in the model's own axes
   and units ("handle: x ±0.10, y 0.14 to 0.26, z −0.26 to 0.02, sloping down
   toward the carter"). The numbers come from the parts log; the views say what
   each part is. A part that two views describe differently is a defect.
3. **Check each part against the real thing.** Is it where it would be on the
   object? Do the wheels touch the ground? Do the handles reach the bed, at the
   height of a hand? Is the door at ground level, on the side the road is? Do
   pieces join, or float, or pass through each other? Check sizes against the
   real object, too. Where the real size and the game's own scale disagree
   (figures drawn small, say), report both numbers and leave the choice to the
   art direction.
4. **Only then judge the look.** The silhouette; whether it reads at play
   zoom; whether it can be told from its look-alikes; whether it keeps to the
   palette and the art direction.
5. **Report in this order:** placement defects (position, size, joins), then
   readability, then style (palette and art direction, a wrong color
   included). Each finding names the part, the view that shows it, and the
   fix. Include the renders. End with the recommended issues: one per change
   worth making, with fixes that one edit would make grouped into one issue.

The written part list from step 2 goes in the report, ahead of the findings.
It is the evidence the placement findings cite, and writing it is the step
that finds them.

## Lessons from earlier critiques

- **The size people actually see is the test that fails most.** A figure 11
  pixels tall can't show a prop a fifth of its height, so roles that differ
  only by a prop look the same. Always look at the model in the real game, not
  only alone on plain ground: the game shows it among everything else.
- **Turn the camera.** Shoot every turn the game's camera takes, alone and in
  the game. A town of buildings that don't turn to face the road shows mostly
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
| A quick take that skips the part list | Write the part list anyway, and keep the rest short. It is the step that finds misplaced parts. |
| Trusting someone's verdict that it looks fine | A verdict on the look says nothing about placement. Run steps 1 to 3 anyway. |
| Reporting each automatic flag as a defect | Look at the part. Report it only if it is wrong on the real object. |
| Judging only the model alone on a plain background | Add the in-game view at play zoom, at every camera turn. |
| Comparing sizes by eye across separately scaled views | Compare the numbers. |
| Fixing the model during the critique | Report the fix and recommend an issue. |

## Outside 3D models

The same order carries over to any artifact that has the three things under
*What it needs*. For a UI screen: the views are every breakpoint and state;
the parts are the elements, each with its box and style read from computed
styles; the reference is the design system; the context is the real page with
real content. Describe each element's box before judging the layout.

Without measurable parts, a reference, or a context of use, this method has
nothing to check, and a critique of that thing needs another approach.
