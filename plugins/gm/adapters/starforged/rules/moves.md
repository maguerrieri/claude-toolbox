# Starforged Core Moves

All moves use the `ironsworn-core` action roll: `roll ironsworn-action --stat <value> --adds <N>` (pass the numeric stat value, e.g. `--stat 2`). See `ironsworn-core/adapter.md` for the full roll mechanic (strong hit / weak hit / miss / match).

> **Adapter note — flat harm:** Strike and Clash list flat harm values rather than Starforged's weapon/harm-rating system. This is a deliberate simplification; adjust in the fiction if circumstances warrant.

The move list below is the curated Starforged core set. Moves unique to Starforged (expeditions, connections, Withstand Damage) are noted. Moves carried over from classic Ironsworn are adjusted for the sci-fi context but mechanically identical unless noted.

---

## Adventure moves

### Face Danger
**Trigger:** You attempt something risky or react to an imminent threat.
**Stat:** Choose the most relevant: **edge** (speed, agility), **heart** (endurance, courage), **iron** (strength, force), **shadow** (stealth, deception), or **wits** (perception, resolve).
- **Strong hit:** You succeed — the danger is past.
- **Weak hit:** You succeed but at a cost: suffer a lesser harm, lose ground, or create a complication.
- **Miss:** You fail or things get worse. Pay the Price.

### Secure an Advantage
**Trigger:** You assess a situation, make preparations, or use your skills or resources to gain an edge.
**Stat:** Choose the stat that fits your approach (see Face Danger).
- **Strong hit:** Choose one: take +2 momentum, OR take +1 add on your next roll (if the advantage still applies when you act).
- **Weak hit:** Choose one: take +1 momentum, or take +1 add on your next roll.
- **Miss:** Your efforts reveal a surprising danger or complication. Pay the Price.

### Gather Information
**Trigger:** You search for clues, do research, conduct an interrogation, or otherwise seek knowledge.
**Stat:** **wits**
- **Strong hit:** You discover something useful. Take +2 momentum and the GM gives you a concrete, actionable finding.
- **Weak hit:** You find partial or ambiguous information. Take +1 momentum.
- **Miss:** You find nothing useful — or discover something that makes things worse. Pay the Price.

### Compel
**Trigger:** You attempt to persuade, barter with, threaten, or seduce someone.
**Stat:** **heart** (appeal or empathy), **iron** (intimidation), or **shadow** (deception or leverage).
- **Strong hit:** They comply as you intend.
- **Weak hit:** They comply, but with a condition, reduced effect, or lasting suspicion.
- **Miss:** They refuse, are angered, or the situation worsens. Pay the Price.

### Make a Connection
**Trigger:** You attempt to establish a bond with an NPC through shared purpose, vulnerability, or meaningful exchange.
**Stat:** **heart**
- **Strong hit:** You make a Connection. Name them and note a bond. Gain +1 momentum.
- **Weak hit:** The connection is uncertain or conditional. Gain +1 momentum but the relationship needs more work.
- **Miss:** They are wary or hostile. Pay the Price.

> *Note: Connections replace classic Ironsworn's "Forge a Bond." The Develop a Relationship move deepens existing connections over time.*

---

## Combat moves

### Strike
**Trigger:** You attack in close quarters or at range.
**Stat:** **edge** (ranged or quick strikes) or **iron** (melee power).
- **Strong hit:** Inflict +2 harm (flat; see adapter note above) and take +1 momentum.
- **Weak hit:** Inflict +1 harm, but you are exposed, off-balance, or your position costs you. Choose: suffer -1 momentum, suffer harm, or create an opening for your foe.
- **Miss:** You miss or are outmatched. Pay the Price.

### Clash
**Trigger:** You trade blows in a direct exchange where you are neither pressing the attack nor avoiding it — you stand your ground.
**Stat:** **edge** (quick parry and counter) or **iron** (absorb and respond with force).
- **Strong hit:** Inflict +2 harm (flat; see adapter note above) and take +1 momentum. You gain the upper hand.
- **Weak hit:** Inflict +1 harm but take harm in return.
- **Miss:** You fail to defend. Pay the Price — likely harm to you and no progress marked.

### React Under Fire
**Trigger:** You must defend yourself or someone else against an immediate attack or hazard.
**Stat:** **edge** (dodge, evade) or **iron** (brace, shield).
- **Strong hit:** You successfully defend. Take +1 momentum.
- **Weak hit:** You avoid the worst, but take minor harm or lose ground.
- **Miss:** You are struck or overwhelmed. Pay the Price.

---

## Suffer moves

### Endure Harm
**Trigger:** You take physical damage.
Suffer -health as appropriate for the threat (applied before the roll). If health reaches 0, roll: **iron** (or **heart** to push through).
- **Strong hit:** Choose: press on (no further effect), OR take +1 momentum (you draw resolve from pain).
- **Weak hit:** You endure. No additional effect.
- **Miss:** The harm is worse than expected. Suffer an additional -1 health. If health is now 0, you are out of action — face what comes.

> *Starforged adds **Withstand Damage** for your starship — analogous to Endure Harm but applied to ship Integrity.*

### Withstand Damage
**Trigger:** Your starship takes damage.
Suffer -integrity as appropriate. If Integrity reaches 0, roll: **wits** (damage control) or **heart** (push your ship past its limits).
- **Strong hit:** Choose: restore +1 Integrity or stabilise (+1 momentum).
- **Weak hit:** The ship holds, barely. A module or system is stressed.
- **Miss:** Critical damage. The ship is crippled or worse. Pay the Price.

---

## Quest moves

### Swear an Iron Vow
**Trigger:** You commit to a quest by swearing a vow on iron.
**Stat:** **heart**
Set a rank (troublesome → epic) — the harder the quest, the greater the reward and the cost of failure. Open a progress track. Progress per milestone by rank: see `ironsworn-core/adapter.md` (troublesome=3 boxes, dangerous=2, formidable=1, extreme=2 ticks, epic=1 tick).
- **Strong hit:** Take +2 momentum. You are resolved.
- **Weak hit:** Take +1 momentum. There is a complication or cost you must face to pursue this vow.
- **Miss:** Your vow is clouded at the outset. Pay the Price — the path is harder than you thought.

### Reach a Milestone
**Trigger:** You accomplish a meaningful step toward your vow.
Mark progress on your vow track according to rank. No roll — the fiction determines when a milestone is earned.

### Fulfill Your Vow
**Trigger:** You believe you have achieved what you swore to do.
Roll **progress** (no stat — roll the challenge dice against your filled boxes).
- **Strong hit:** Your vow is fulfilled. Take +2 experience. Reflect on what you've paid to get here.
- **Weak hit:** The vow is fulfilled, but with an unexpected cost, partial result, or lingering consequence. Take +1 experience.
- **Miss:** The vow remains unfulfilled or you discover the truth is worse. Envision what went wrong and press on or forsake.

---

## Exploration moves

### Undertake an Expedition
**Trigger:** You travel to a distant destination through the Forge or across a planet's surface.
**Stat:** **edge** (speed and evasion), **wits** (navigation, preparation), or **heart** (endurance and resolve over long haul).
Define your destination and set a rank. Define waypoints as you go.
- **Strong hit:** Mark progress twice. At each waypoint, envision what you encounter.
- **Weak hit:** Mark progress once, then choose: suffer -1 supply, lose speed (mark once instead of twice on next leg), or face a complication at the next waypoint.
- **Miss:** You make no progress. Suffer a cost (harm, supply, or danger). Pay the Price.

> *Expeditions replace classic Ironsworn's "Undertake a Journey." They use waypoints rather than a single-roll-per-leg system, and can apply both to space travel and surface exploration.*

### Finish an Expedition
**Trigger:** You arrive at your destination or have marked progress to resolve the track.
Roll **progress** against your filled expedition track boxes.
- **Strong hit:** You arrive safely and in good position. Take +1 momentum.
- **Weak hit:** You arrive, but the journey has cost you or left you exposed. Suffer a minor price.
- **Miss:** You don't arrive as intended, or you arrive in dire circumstances. Pay the Price.
