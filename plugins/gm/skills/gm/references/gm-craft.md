# GM craft

System-agnostic narration technique — *how* the core runs a good scene, independent of any adapter's rules and any persona's voice.

## Fail forward
A miss never dead-ends the story. A failed roll introduces a complication, a cost, or a new threat that *moves the fiction* — the door stays locked, but now there are boots on the stair. Never "nothing happens."

## Succeed at a cost
A partial success (a "weak hit", a "Yes, but…") gives the player what they reached for **and** a price: progress with a complication, the goal but not cleanly, success that draws attention. The cost is concrete and lands now.

## Every NPC wants something
Before an NPC speaks, know their want. It drives what they offer, refuse, and risk — and they pursue it off-screen too. The world doesn't pause when the player looks away.

## Frame the scene, then ask
Open with a sensory hook and a situation that *demands a choice*, then ask "what do you do?" Don't narrate the player's actions for them; set the stage and hand them the moment.

## Stop at the first real fork
A turn that describes several steps is a *plan*, not permission to make every choice inside it. Play it forward a step at a time, resolving each as you reach it (a roll where the rules call for one, the state it changes). Routine details the player left unstated are yours to settle (the line along the wall, which stall sells rope, how many coils); anything they did state stands. A fork is a choice that changes what happens next. **Stop at the first point where:**
- a roll or oracle result changes the situation the plan assumed;
- something new comes to light that the player would plausibly want to react to;
- the plan forks on a choice the player hasn't made: who comes along, what to carry or leave, which way;
- an NPC confronts the character or asks them something that matters.

Never invent the player's choice to keep the chain moving: a step that needs a decision they didn't state *is* the fork. End the reply on the fork. Name the rest of the plan as still pending ("you were making for the gate") so the player can confirm it in a word, and ask one question: the specific one when it's a choice they haven't made, otherwise "what do you do?"

Don't over-interrupt, either. If nothing along the way is a fork, resolve the whole plan in one narration: in a quiet town, "we buy rope in the market and head for the docks" is one reply with no stops. A pause is for a real decision, not a checkpoint after every step. This is *Pace by stakes* (below) applied inside a single turn, and it's core craft: the persona colors how the pause sounds, not where it falls.

> Player: *"Let's creep out of the stable and approach the gates. Carefully."*
>
> **Don't:** "You leave Talla penned; a mule's hooves would carry. You slip out with Sael at your shoulder, keep to the wall, and reach the gate, where…" The mule's fate was the player's call, and they never made it.
>
> **Do:** "Talla shifts in her stall, halter rope trailing. Beyond the door the yard is open cobbles all the way to the gate, and she's shod. Sael is at the door already; you were making for the gate. Does Talla come?" *Let's* settled Sael; it didn't settle the mule. Once they answer, play the rest forward: roll the creep across the yard, and if it holds, bring them to the gate, stopping there only if something at the gate calls for it. If the roll goes wrong, that's the next fork.

## Pace by stakes
Zoom in beat-by-beat when stakes are high or a choice matters; zoom out (montage, "time passes") through the routine. Cut a scene on a turn, a reveal, or a question.

## The player is referee
On any disagreement about what's true, the campaign state file wins. Reconcile to it, then continue. The fiction is collaborative; the record is authoritative.

## Felt, not shown
A hidden clock or a sealed secret manifests as *fiction*, not as a visible number. When a behind-the-screen clock advances, the player should **feel** the pressure — the lanterns wake one bend closer, the guard's rounds tighten — not read "[▰▰▱▱]". Tick it with `campaign gm-clock` (behind the screen) and spend the beat on the *consequence*. Reveal the thing itself — the count, the answer — only when the fiction earns it (`campaign gm-reveal`), the way a mystery turns over when the last clue lands. Which state is hidden vs. open is the adapter's `visibility`; see adapter-contract and the skill's "The GM screen".
