# Stomp design pass

Per mon we screen the win rate first. Roughly 45–55% is fine, and clean counters are fine. The goal is
not to hit a target win rate. The goal is move quality: find moves that are never used or superseded, and
rework them so they are situationally useful, synergistic, and flavorful. Cap is two new moves per mon.

Judge every move inside the whole game system, not by a static stat-line comparison. The stamina economy is
the load-bearing example: mons start at 5 stamina and regen +1 each turn, so a cheap move can earn its slot
precisely because it's affordable on the turns the expensive ones aren't. A move that looks strictly worse on
paper can be the only thing a stamina-starved mon can still do.

Claims use two templates.
**[Thing]** 1) reason 2) why I know it 2.5) why isn't what we have working 3) uncertain? 4) validate
5) what would change my mind 6) easy to test? 7) simulated result 8) consistent with (1)?
**[Property]** 1) opinion 2) which property 3) why 4) better alternatives 5) their tradeoffs 6) still hold?
7) amend 8) empirical hook.

Validation is a real experiment, and it's written as a structured list of steps. Each list says what to
measure first, the exact change to make, the delta we expect to see, and how the call updates in either
direction. Damage scales as basePower × attack ÷ defense, with a type multiplier and a 1.5× crit, so
relative claims like "halving a stat halves the damage" are exact without the scaling constant. Win rates
are the munch arena runs (hard/greedy avg); for setup and combo mons those numbers are pilot artifacts and
are flagged as such.

---

## Ghouliath — 51% (in band; a leave-it once the pilot can fire Eternal Grudge)
Yin/Fire suicide lead. It cripples with status, then cashes out with Eternal Grudge at +1 priority. The sim
mostly spams Infernal Flame, and Eternal Grudge sits near 1% usage.

**[Thing] Eternal Grudge is unpiloted, not weak — a 1-ply pilot will never choose a self-KO.**

*1) Reason.* Eternal Grudge looks dead, but its payoff is bigger than the usage suggests. It KOs Ghouliath and
halves both the opponent's Attack and Special Attack. That debuff holds until the crippled mon switches out,
and the move has +1 priority, so you can often fire it twice in a game.

*2) Why I know it.* Halving both offenses is a large, matchup-agnostic cut. A physical attacker and a special
attacker are both neutered by it, so the value is real even though the mon pays its own life for it. The 1%
usage is a pilot artifact. A smart Ghouliath fires Eternal Grudge as a last resort — when it's about to be
KO'd anyway, or it has no better option — so the self-KO spends a mon that was already dead. Both default
pilots refuse that trade, so the cripple-then-grudge plan never shows up in the data.

*2.5) Why isn't what we have working.* The problem is piloting, not the payoff. A greedy or 1-ply pilot will
never choose to KO its own mon, so the plan never appears. The rest of the kit supports it and is also
underused. Wither Away drains stamina from both sides via Panic, and Grave Affliction costs both mons half
their HP if the target is already statused. Those are all setup pieces the sim skips.

*3) Uncertain?* The size of the halve is not uncertain. What is uncertain is whether the opponent stays in or
switches the crippled mon out to shed it. And even if they switch, the value doesn't vanish. It's still
tactically useful if the rest of the team can exploit the moment: a partner that punishes the forced switch,
or one that presses the weakened mon before it can escape. So the debuff changes hands rather than disappears.

*4) Validate?* The halve on its own doesn't decide anything, so this is a scripted test, and it needs a pilot
that fires the move at all.
- Add a last-resort CPU script that fires Eternal Grudge when Ghouliath is about to be KO'd or has no better
  move, then run a few hundred games and confirm the move actually gets used.
- Log how often the crippled opponent stays in versus switches out to shed the halve.
- In the stay branch, measure the opponent's next-turn damage with and without the halve; expect it to land at
  about half.
- In the switch branch, pair Ghouliath with a partner that punishes the forced switch, and check whether the
  partner cashes the tempo.
- If the opponent almost always switches and no partner profits, the grudge is a bad trade; if they stay, or a
  partner profits, it pays and the move is fine as written.

*5) What would change my mind.* If the opponent almost always switches and the team can't exploit the forced
switch, then Eternal Grudge is a worse trade than it looks. If they tend to stay, or a partner cashes the
pivot, the halve pays and the move is fine.

*6) Easy to test?* The static halve is trivial and already answered by the formula. The stay-versus-switch
half needs the pilot plus a fuller game, so it leans on the arena.

*7) Simulated result.* I expect the halve to be strong against a mon that stays, and a tempo tax against one
that pivots, especially paired with a partner that punishes the pivot. So it's a good move the current pilot
can't use, not a weak one.

*8) Consistent with (1)?* Yes. It's unpiloted, not weak, with a "they can switch" hole that team synergy
softens rather than a mechanical flaw.

**[Property] Leave the move alone — fix the pilot and lean on a partner, don't make the halve stick.**

*1) Opinion.* I'd leave Eternal Grudge's mechanics as they are. My first instinct was to make the halve
survive one switch, but that punishes switching, which we explicitly want to encourage. So the real fix is a
last-resort pilot plus a team partner that exploits the cripple, not a stickier debuff.

*2) Property.* This is really about meta and risk/reward together. The reward for a self-KO should be paid by
the team you built around it, not by taxing the opponent's escape.

*3) Why.* Making the halve stick fights switching-as-counterplay, a core value of the game. There's also a
mechanical trap to check first: the halve is applied as a stat boost, so it may already be a Temp boost that
drops when the killer switches out. If it is, "make it stick" actually means making it permanent, which is a
far bigger call than it looks. It's cleaner to accept the switch as counterplay and build the payoff into a
partner instead.

*4) Better alternatives?* We could make the halve survive a switch, buff its raw size, or leave it and fix the
pilot plus the team.

*5) Their tradeoffs.* Sticking the halve punishes switching. Buffing the size doesn't fix the dodge at all, it
just makes the un-dodged case swingier. Leaving it keeps the value honest and moves the reward onto
team-building, which is where we want initial advantage to come from.

*6) Still hold it?* Yes, and this reverses my first draft. Ghouliath is a leave-it on the numbers.

*7) Amend.* No mechanic change. The action item is a last-resort CPU pilot, and the design note is that the
grudge's real reward lives in a partner that punishes the forced switch.

*8) Empirical hook.*
- Once the last-resort pilot fires Eternal Grudge, log the stay-versus-switch rate across a few hundred games.
- Measure whether a punish-the-switch partner converts the switch branch into a tempo gain.

*Summary:* Existing changed — none. New moves — none. Action item: a CPU pilot that fires **Eternal Grudge** as
a last resort (Ghouliath about to be KO'd, or out of good options), so the move can be measured at all; and a
team-building note to pair Ghouliath with a partner that punishes the forced switch.

> **[Predicted]** The design leans on a partner that punishes the forced switch, but no specific mon is named.
> We need to identify which mon on the roster actually fills that role. If none does, the team-synergy argument
> does not hold. The last-resort logic also needs numbers. When Ghouliath is about to be KO'd, is a self-KO that
> halves both of the opponent's offenses better than one more Infernal Flame into the same target? We should
> script both lines and compare them. (This is a Validation question.)

> **[Addressed]** On the partner: scanning the roster, the only real switch-punish tool is Gorillax's Rock
> Pull, a Pursuit that catches a fleeing mon. So the concrete pairing is Ghouliath into Gorillax — Grudge forces
> a bad spot, and Rock Pull punishes the switch. That names it, but it also surfaces a gap: the roster has
> essentially one Pursuit, so the "pair with a switch-punisher" plan is thin. On the last-resort math, the
> source settles the shape. Eternal Grudge deals zero damage; it applies a Temp 50%/50% Attack/SpAttack debuff
> and self-KOs. The debuff is Temp, so it drops the moment the crippled mon switches out. So Grudge beats one
> more Infernal Flame only when the opponent stays in and keeps attacking, because then halving their offense
> saves more than the Flame's damage. Against a mon that will switch, Grudge is strictly worse. The pilot rule
> follows: fire Grudge only when the opponent is likely to stay, which the override can test against a staying
> and a switching line.

> **[Predicted]** Wither Away and Grave Affliction are mentioned a lot. However, we need a deeper dive into
> their viability. Grave Affliction deals damage to both players — is this symmetry beneficial for the user? Do
> we need to tweak it? (And if so, this would lend itself to the Validation thought process and procedures.)

> **[Addressed]** I read both. Wither Away is a 60-power Yin special for 3 stamina that applies Panic to the
> target and to Ghouliath itself. Panic drains stamina, so it is chip plus mutual stamina drain, and on a
> suicide lead the self-Panic is a small cost. It is a fine setup piece and needs no change. Grave Affliction
> only fires if the opponent already has a status, and then both mons lose half their current HP. Because it is
> current HP, the mon with more HP loses more in absolute terms. Ghouliath is usually the lower-HP mon, so the
> symmetry favors the user — it is a drag-you-down-with-me move that is strongest when Ghouliath is behind. So
> the symmetry is beneficial in Ghouliath's natural state, and it is gated on landing a status first, which the
> kit already does. No tweak needed; the reason it is unused is piloting, the same as Grudge.

---

## Inutia — 42% (unreliable; a support-pivot the greedy pilot can't drive)
Faith utility with weak damage. The sim plays it as a mono-Big-Bite mon and ignores its whole toolkit.

**[Thing] Inutia's utility is unpiloted, and the buff-pass is the part most likely to be strong.**

*1) Reason.* Inutia plays as one damage button because the pilot can't sequence its utility. Big Bite is used
56% of the time. Initialize, Chain Expansion, and Hit and Dip are each used under 7%.

*2) Why I know it.* Initialize gives +50% ATK and SpATK, and it transfers to the incoming mon when Inutia
switches out. That is a baton pass in all but name. A smart Inutia casts Initialize, then pivots with Hit and
Dip so a frail partner enters already boosted. A greedy pilot just casts it on Inutia and never completes the
handoff, so its usage looks like noise. The transfer is the strong part, and it never happens in the data.

*2.5) Why isn't what we have working.* The failure is piloting, but it hides a real balance risk. A passed +50%
can let a frail nuker sweep, which is the classic degenerate baton-pass pattern. So the danger here is not that
the kit is weak. The danger is that it snowballs once a pilot actually plays it.

*3) Uncertain?* I don't know how strong the completed pass is. It could be fair, or it could be oppressive with
the right partner. That is the load-bearing unknown, and it's exactly why this needs CPU tests that actually
use Initialize and the pivot rather than the arena's Big-Bite-only line.

*4) Validate?* Scripted test, not a static check, because the payoff is a multi-turn line that depends on the
partner.
- Script Initialize, then Hit and Dip into a frail attacker, then that attacker's hit, and read the damage with
  and without the passed boost. We change nothing, since the transfer already exists.
- Fork on the opponent: log whether they stay and eat the boosted partner, or switch to reset the matchup.
- Run a full arena game with the override driving the pass, and measure whether the boost snowballs into
  no-counterplay wins.
- If the pass turns a 2HKO into a 1HKO on common targets, cap it to about +30%; if it barely changes the math,
  it's fine and Inutia is just underpiloted.

*5) What would change my mind.* If the passed boost turns a 2-hit-KO into a 1-hit-KO on common targets, the pass
is too strong and needs a cap. If it barely changes the math, the pass is fine and Inutia is just underpiloted.

*6) Easy to test?* The single-handoff damage is easy to script. The "does it snowball across a game" question is
harder and is the one place this mon may need the arena.

*7) Simulated result.* I expect the pass to be strong, and possibly too strong if uncapped. So the design should
throttle it before we lean on it.

*8) Consistent with (1)?* Yes, with a caveat. It is unpiloted, and its real problem is a snowball risk, not weakness.

**[Property] Keep Inutia a throttled buff-passer, and fix Blessed into a gated one-hit shield.**

*1) Opinion.* Keep the Initialize transfer as the identity, sized so it's strong but not degenerate. Leave
Chain Expansion as-is, and instead spend the one change on Blessed, reworking it from a slow heal-over-time
into a shield that blocks a single hit. Together these give Inutia a real job: enable a partner, and protect a
key mon on the swap.

*2) Property.* This supports meta and risk/reward. It makes Inutia a team-building piece rather than a filler
attacker, and it avoids a stally heal.

*3) Why.* Inutia is fast, so it can pass a boost and pivot in one motion, the way Hit and Dip already does. That
is tempo-positive support, not turtling. A one-hit shield fits the same tempo role, because it protects the
incoming mon from the free hit a pivot usually eats.

*4) Better alternatives?* We could fix Blessed into a real heal instead, or turn Chain Expansion into an active
switch-punish, or just buff Big Bite and accept a plain attacker.

*5) Their tradeoffs.* A pure heal-cleric drags games toward stall, which we're avoiding by design. Turning Chain
Expansion active is more churn than the kit needs, and it taxes the switching we want to encourage, so it stays
a mild hazard-heal. Buffing Big Bite throws away the whole unique kit for a generic mon. The one-hit shield is
different from a heal and worth pursuing, as long as it can't be spammed — once per mon per game, or some other
drawback. Blessed barely does anything today, so reworking it is a real option, not a throwaway.

*6) Still hold it?* Yes, but the pass is gated on the snowball test. If it's oppressive, the cap has to come first.

*7) Amend.* Keep the pass soft: one stat line, a survivable pivot, no stacking into an omniboost. Gate the
shield to once per mon per game so it protects a key swap without becoming a wall.

*8) Empirical hook.*
- Run the handoff-damage script for the pass size.
- Run a full arena game with the override for the snowball check.
- Script a shield-into-a-big-hit line and confirm the shield saves exactly one mon and no more.

*Summary:*
- **Initialize** — 0 / 2 / Faith / Self / — / 0 — unchanged mechanics: +50% Attack and Special Attack that
  transfers to the incoming mon on switch-out. Balance is gated on the snowball CPU test; if it snowballs, cap
  the transfer to about +30%.
- **Chain Expansion** — unchanged. It stays a mild switch-in hazard-heal, kept mild on purpose so it doesn't tax
  switching.
- **Sanctify** — 0 / 2 / Faith / Other / 100 / 0 — targets a friendly mon and grants **Blessed**, reworked from
  a heal-over-time into a shield that blocks the next incoming hit. Limited to once per mon per game so it can't
  be spammed.
- New standalone moves: none.

> **[Predicted]** The shield needs more detail. Does it block the whole hit regardless of size? Blocking a large
> hit is a big swing, and blocking a small one does little, so the value depends heavily on the matchup. We may
> need to cap the damage it absorbs. There is also an interaction to check. Initialize passes +50% to a frail
> partner, and Sanctify can give that same partner a free block on entry. We should judge the shield and the
> pass together, since combined they may be the snowball we were trying to avoid. Finally, once-per-game
> requires a per-mon flag in storage, so we should confirm that is cheap to track.

> **[Addressed]** Agreed on the cap. The shield should absorb one hit up to a fraction of the mon's max HP —
> roughly 50% — so it saves against a nuke but is not a full free turn against a small hit. On the interaction:
> Initialize passes +50% to a frail partner, and Sanctify can shield that partner's entry, so judged together it
> is a strong protected setup. Two guards already limit it: the pass is capped to +30% if the snowball test
> flags it, and the shield is once per mon per game. If the pair still snowballs, the shield should not be
> castable the same turn as the pass. On storage: once-per-game is cheap and already precedented. Rise from the
> Grave, Sleep, and Loop all use per-battle globalKV flags for one-shot state, so a single per-mon flag keyed the
> same way is standard. Confirmed feasible.

---

## Malalien — 49% (skill-gated: 55% hard, 43% greedy)
Cyber glass cannon. It 2HKOs most of the roster with coverage plus a self-buff. The sim shows Triple Think
barely used and Foul Language as the odd slot.

**[Thing] Malalien is not broadly dominant. Its strength is skill-gated.**

*1) Reason.* The aggregate says Malalien is in band, not oppressive. It only looks scary under a strong pilot.
Its 12-point gap between hard and greedy is the tell.

*2) Why I know it.* Under greedy it drops to 43%, because a greedy pilot feeds a frail mon into its own death.
Under hard it climbs to 55%, because a planner sets up Triple Think and sweeps. Triple Think is used about 1%
of the time, so the "very strong" read comes from a setup the average pilot never performs. A smart Malalien
only spends the turn on Triple Think when it's healthy and outspeeds, so the buff isn't punished before it
pays; a greedy pilot buffs into a faster attacker and dies holding the setup.

*2.5) Why isn't what we have working.* Nothing is broken here. The kit works when piloted, and the low-pilot
number is the artifact. The only real question is whether its all-types coverage is too forgiving.

*3) Uncertain?* Low uncertainty on the power. Some uncertainty on whether the coverage makes it too safe to
pick, which only matters once the rest of the roster shifts.

*4) Validate?* Static chart lookup, not test code, and it's already done.
- From the type chart, count how many of the 12 other mons Malalien lacks a super-effective or neutral option
  against, across Cyber, Math, and Cosmic.
- Result: at least a neutral hit on all twelve, super-effective on five (Inutia, Gorillax, Volthare, Aurox,
  Nirvamma), and no mon resists all three types, so coverage is total.
- After the other reworks land, re-run the arena and check whether Malalien is still the default best pick above
  55%.
- If it is, tax the coverage; if it settles in band, leave it.

*5) What would change my mind.* If, after other reworks land, Malalien is still the default best pick at over
55%, then the coverage is too safe and should be taxed. If it settles in band, leave it.

*6) Easy to test?* Yes, the coverage count is a static lookup, and it's done. The "still dominant later" part is
an arena recheck after the other reworks ship.

*7) Simulated result.* Coverage is total, which is exactly why it feels safe to bring. That's a watch-list
item, not a bug. Its real check is a partner, since a frail 2HKO cannon wants a teammate that can take the hit
it can't and pivot Malalien back in clean.

*8) Consistent with (1)?* Yes. It is a fine, skill-gated glass cannon with total coverage, not a problem mon.

*Summary:* Existing changed — none. New moves — none. Foul Language (60 / 2 / Cyber / Special, unlocked at level
6) is not a dead slot: it's Malalien's cheap 2-stamina action for when its 3-cost coverage moves are
unaffordable, so it can still take a KO or force a switch at low stamina. Watch-list: coverage is confirmed
total, so recheck field win rate after the other reworks land and tax the coverage only if Malalien stays the
default pick.

> **[Predicted]** We called Foul Language the odd slot and then did not examine it. That is the kind of move
> this pass is meant to catch — one that is never the pick. We should look at what Foul Language does and whether
> the three coverage moves supersede it. Leave-it can be right for the mon overall and still wrong for that one
> slot.

> **[Addressed]** I had this wrong, and the error is instructive. I compared Foul Language's stat line to other
> moves in isolation instead of placing it in Malalien's stamina budget. Mons start at DEFAULT_STAMINA 5 and
> regen +1 each turn. Malalien's three coverage moves all cost 3, and Triple Think costs 2, so its stamina
> drains fast: Triple Think (5−2+1 = 4), then a 3-cost coverage move (4−3+1 = 2) leaves Malalien at 2, where a
> 3-cost move is unaffordable. Foul Language costs 2, so it's the move that still fires there — a cheap closer
> that takes the KO on a weakened target or forces an early switch when the expensive buttons are locked out.
> The recoil is the price of that flexibility, and on a glass cannon that trades anyway it's a small one. It's
> also an UnlockLevel-6 pick, so it's a progression option, not a default slot. So Foul Language isn't a dead
> slot, and Malalien goes back to a full leave-it. The real lesson is to judge every move inside the stamina
> economy and the whole system, not by a static stat-line comparison.

---

## Iblivion — 43% (below band; a piloting floor, not a weak kit)
Yang/Air resource mon, and a fast, frail, mixed attacker: Speed 256, HP 277, Attack 199, SpATK 180. At 43% it's
under the 45–55 band, but the sim shows why that's a floor — hard ignores Loop at 4%, greedy spams it at 83% for
8% wins, and no pilot manages Baselight. So this is a below-band mon to raise, not a strong one to rein in, and
that fact should point the whole rework.

**[Thing] Baselight is a free timer feeding one button, not a resource.**

*1) Reason.* There's no decision in earning Baselight, and there's one dominant thing to spend it on. From
source, it starts at 1 on switch-in and gains +1 each turn to a max of 3, no matter what Iblivion does.

*2) Why I know it.* Loop reads the Baselight level to set all stats to +15, +30, or +40%, but it doesn't consume
the level. The greedy pilot sees that stat gain and mainlines Loop, winning only 8% of the time; the hard pilot
barely touches it. Neither number says anything about a well-managed Iblivion.

*2.5) Why isn't what we have working.* Two things fail at once. Generation is free, so there's no risk in earning
the resource. And the only move that actually spends is the empowered Unbounded Strike, while Loop just reads the
level, so there's no hold-versus-spend choice and the empowered attacks never really compete.

*3) Uncertain?* I don't know where a properly-piloted Iblivion lands. My guess is mid-pack, but the sim can't
show it, because no pilot manages Baselight well.

*4) Validate?* Static value check plus a scripted line.
- Sum the stat gains Loop grants at each level (+15/+30/+40%) to confirm its raw one-button swing.
- Add an override that banks Baselight, then cashes it into empowered Unbounded Strike, and compare it to
  Loop-spam over the same turns.
- Read the win margin and damage total for each line.
- If managed Iblivion lands near 50%, the low score was piloting; if it stays low even when managed, the kit is
  genuinely weak.

*5) What would change my mind.* If managed Iblivion lands near 50%, its low score was piloting and the work is
about making the resource interesting. If it stays low even when managed, the kit needs more than a resource
rework.

*6) Easy to test?* The scripted comparison is easy once the override runs it, but the number is only trustworthy
with a competent pilot, which is the gating requirement.

*7) Simulated result.* I expect roughly 50% when managed, so the real problem is a boring resource, not a weak
mon.

*8) Consistent with (1)?* Yes. Baselight is dull even though the mon isn't weak.

**[Property] Earn Baselight by attacking, not by the clock.**

*1) Opinion.* Gate the stack on landing a base, non-empowered attack — base Unbounded Strike, 80/2 — instead of
on the clock.

*2) Property.* This supports fun through decision density, plus risk/reward.

*3) Why.* A resource you earn for free is a timer, and a timer isn't interesting. Earning by pressing the attack
rewards a fast attacker for doing its job. The obvious "earn on any damage" version fails, because most of
Iblivion's damaging modes already spend a stack, so earning and spending on the same press means you can never
accumulate. The base attack is the clean charger.

*4) Better alternatives?* We could nerf Loop and touch nothing else, or earn a stack every time Iblivion is hit
rather than when it hits.

*5) Their tradeoffs.* Nerfing Loop alone tanks a mediocre mon and leaves the resource just as boring. Earning on
being hit rewards passivity, which fights the fast-attacker identity. Earning on the base attack keeps the mon
pressing and still lets it bank.

*6) Still hold it?* Yes. It converts the timer into a resource without touching net power.

*7) Amend.* Keep the base attack cheap at 80/2 so charging is always affordable, which matters given how thin
Iblivion's stamina gets across a game.

*8) Empirical hook.*
- Blocked on the override managing Baselight; until a pilot can bank base hits, no arena number means anything.
- Once it can, confirm a managed line accumulates then spends rather than mainlining one button.

**[Property] Make Loop a readable window, and give the empowered modes a reason to compete.**

*1) Opinion.* Loop consumes 1 stack and its boost lasts only 2 turns instead of holding indefinitely; raise the
empowered Unbounded Strike and Brightback ceiling so they're real alternatives to Loop.

*2) Property.* This supports meta and risk/reward.

*3) Why.* An indefinite all-stats boost off a free timer is the dominant button, so nothing competes. Making Loop
spend a stack and expire in two turns turns it into a committal play the opponent can wait out or punish, and
raising the empowered ceiling gives the attack modes a real claim on the same stacks.

*4) Better alternatives?* We could leave Loop indefinite and just raise its stack cost, or cap its boost size.

*5) Their tradeoffs.* Leaving it indefinite keeps the set-and-forget feel that makes it dominant. Capping the
boost size weakens the payoff without adding a decision. The 2-turn window is the version that creates an actual
hold-versus-spend read.

*6) Still hold it?* Yes, but "keep net power flat" isn't enough — Iblivion is below band, so the empowered
ceiling should rise until a well-piloted Iblivion ends up net stronger, not lateral.

*7) Amend.* Pay the Loop nerf back with a higher empowered ceiling and then some, so managed Iblivion climbs
toward band rather than holding at a 43% floor.

*8) Empirical hook.*
- Script Loop-then-attack against a Loop-and-hold line and confirm the 2-turn window creates a punishable moment.
- Confirm the raised empowered modes get chosen over Loop in at least some spots, so the sink isn't
  one-dimensional again.

**[Thing] The naive accumulate-then-spend economy barely beats just attacking.**

*1) Reason.* Once you write down the costs, the loop pays almost nothing. From source: base Unbounded Strike is
80/2 and consumes nothing; at 3 stacks it's 130/1 and consumes all 3. So banking three base 80s (240) then one
empowered 130 is 370 over four turns, versus 320 from four plain 80s — only +50 for all the setup.

*2) Why I know it.* The numbers are exact from the contract: BASE_POWER 80, EMPOWERED_POWER 130, REQUIRED_STACKS
3, and a +1-per-turn charge. There's no hidden multiplier that closes the gap.

*2.5) Why isn't what we have working.* The empowered ceiling is too low relative to the base hit for the
accumulate-then-spend loop to be worth the turns it costs. A resource that pays +50 over four turns is
decorative, not a decision.

*3) Uncertain?* The exact ceiling that makes the loop worthwhile. It clearly has to rise, but by how much depends
on how the boosted line trades against a plain attacker in real games.

*4) Validate?*
- Script the accumulate-then-spend line against a plain-attack line over the same turns; read total damage.
- Raise the empowered ceiling (or the per-hit charge above +1) and re-run until the loop clears the plain line by
  a real margin.
- Separate the regimes: the loop should win when Iblivion has time to bank, and a plain attacker should win a
  race.
- If no ceiling makes the loop worth the setup turns, simplify the resource rather than deepen it.

*5) What would change my mind.* If a modest ceiling bump makes the loop clearly beat plain attacking, the rework
is sound. If it takes an absurd number to pay off, the earn-then-spend framing is wrong for this kit.

*6) Easy to test?* Yes — it's a fixed multi-turn script with two variables, the ceiling and the charge rate.

*7) Simulated result.* I expect the loop needs the empowered ceiling raised past 130, or a +2 charge, before it
beats four plain hits by enough to justify the risk.

*8) Consistent with (1)?* Yes, and it's the crux of the rework: without a paying economy, earning Baselight by
attacking is just a slower timer.

**[Thing] Charging on one Air-typed move dries the resource up in the matchups where Iblivion is already stuck.**

*1) Reason.* If only the base Unbounded Strike charges, and it's Air-typed, then an Air-resist or a forced switch
shuts the resource off — exactly when Iblivion is already losing the exchange.

*2) Why I know it.* From source, base Unbounded Strike's moveType is Air. The current free timer fills regardless
of matchup; moving the charge onto a single typed attack couples the resource to that attack landing.

*2.5) Why isn't what we have working.* This is a feasibility hole the earn-on-hit fix introduces. A fast attacker
that depends on one charging button can end up worse than the free-timer version it replaced.

*3) Uncertain?* How often Iblivion actually faces an Air-resist or a charge-denying switch in real games. The tail
matters more than the average, since it's the bad matchups that decide the mon's floor.

*4) Validate?*
- Script Iblivion into an Air-resisting matchup and one that forces early switches, and log how often the charge
  stalls.
- Add the mitigation (any damaging move charges, or a passive trickle) and re-run to confirm the resource still
  moves.
- Compare the floor matchups' win rate with and without the mitigation.

*5) What would change my mind.* If the stall almost never happens in practice, single-move charging is fine and
simpler. If it strands Iblivion in its bad matchups, the mitigation is required.

*6) Easy to test?* Yes, once the override pilots the charge line.

*7) Simulated result.* I expect the stall to bite in the Air-resist matchups, so the mitigation earns its place.

*8) Consistent with (1)?* Yes. It constrains the earn-fix: the charge can't rest on a single typed move.

**[Property] Let more than one move charge, and keep a floor.**

*1) Opinion.* Let any of Iblivion's damaging moves grant the stack, or keep a slow +1-every-two-turns trickle
under the on-hit charge, so the resource doesn't vanish in a bad matchup.

*2) Property.* This supports risk/reward without a feels-bad.

*3) Why.* Earning on hit is right for making the resource a decision, but it shouldn't punish Iblivion twice by
drying up exactly when it's already behind. A small floor or a broader charge keeps generation honest without
returning to a free timer.

*4) Better alternatives?* Keep single-move charging and accept the dead matchups, or return to the free timer
with a lower cap.

*5) Their tradeoffs.* Single-move charging is cleaner but strands the bad matchups. The free-timer-with-cap gives
up the whole point of the rework. Multi-move charge with a small floor keeps the decision while removing the
feels-bad.

*6) Still hold it?* Yes, contingent on the stall above actually showing up in the sim.

*7) Amend.* Keep the floor slow, +1 every two turns, so it's a safety net and not a return to free generation.

*8) Empirical hook.*
- Script the Air-resist matchup with the floor in place and confirm the resource moves without making generation
  free again.

**[Property] The package has to be a net buff, because Iblivion is below band.**

*1) Opinion.* Every change above — earn-on-hit, Loop consuming a stack, the 2-turn window — lowers Iblivion's
power. That's only defensible if it's paid back and then some, because at 43% Iblivion is below the band, not
dominant. The empowered ceiling has to rise enough that a well-piloted Iblivion lands in band, around 50% or
better, not just "flat."

*2) Property.* This is about power level and direction, matched to where the mon actually sits.

*3) Why.* You nerf a resource when it's too strong, and Iblivion isn't — its 43% is a piloting floor, and the
interesting-resource goal is orthogonal to power. If we reshape the resource into a decision but leave managed
Iblivion weaker, we've spent effort making a below-band mon worse. The reshaping and the buff have to ship as
one package.

*4) Better alternatives?* Keep the free timer and just raise the payoffs — a pure buff with no new decision. Or
reshape and accept a lateral move.

*5) Their tradeoffs.* A pure buff leaves the resource as dull as it is now, which fails the move-quality goal. A
lateral reshaping on a below-band mon is wasted work. Reshape-plus-buff is the only version that fixes both the
interest and the power.

*6) Still hold it?* Yes. The 43% sets the direction: net up, not flat, not down.

*7) Amend.* Tie the buff to the earn-and-spend loop, not to Loop — raise the empowered Unbounded Strike ceiling
well past 130 so the burst is the reward for banking. That's both the power add and the payoff that makes the
loop worth the setup.

*8) Empirical hook.*
- Measure managed Iblivion's win rate first, with the override piloting the resource; that number sets how big
  the buff must be.
- If managed is already ~50%, the reshaping can be near-flat; if it's still sub-45%, the empowered ceiling rises
  until it lands in band.

*Summary:*

**Iblivion — resource rework, net buff, no new move.**
- *Findings:* At 43% Iblivion is below the 45–55 band, and that's a piloting floor — a fast, frail, mixed
  attacker (Speed 256, HP 277, ATK 199, SpATK 180) whose resource no pilot manages. Baselight is a free timer
  (1→2→3, +1/turn); Loop reads the level but doesn't consume it; only empowered Unbounded Strike spends. Because
  the mon is below band, the rework's job is to make the resource a decision **and** leave a well-piloted
  Iblivion stronger, not weaker. Net direction is a buff, targeting ~50%+ when managed.
- **Baselight (ability) → earn +1 on a base, non-empowered attack (max 3), plus a slow +1-every-two-turns
  floor**, replacing the free +1/turn timer.
  - *Rationale:* turns a timer into an earned resource without making it harder to fuel — the floor keeps
    generation honest in the Air-resist matchups where a single charging move would stall.
- **Loop → 0 / 1 / Yang / Self, consumes 1 stack, boost lasts 2 turns** (was indefinite, consumed nothing).
  - *Rationale:* adds the hold-versus-spend decision and a punishable window. This is the one nerf, and it's only
    justified because it's paid back — and then some — by the buff below.
- **Unbounded Strike (empowered) → ceiling raised well past 130 (the buff).**
  - *Rationale:* the empowered burst is the payoff for banking and the net-power add that keeps a below-band mon
    from getting weaker. Sized against the finding that a naive economy nets only ~+50 over four turns, so the
    ceiling rises until a managed Iblivion reaches band.
- *Validation gate:* measure managed Iblivion's win rate first; the empowered ceiling rises until it lands in
  band, so the package never ships as a net nerf.
- *New moves:* none.

---

## Gorillax — 54% (strong, pilot-robust)
Earth bruiser with the highest HP and Attack. The sim leans on Throw Pebble at 38% and never clicks Rock Pull
at 1.4%. Its ability, Angery, rarely reaches its payoff.

**[Thing] Rock Pull is a dead button because the wrong-read cost is self-damage.**

*1) Reason.* Rock Pull is a Pursuit-style read, but nobody takes the gamble. Its usage is 1.4% across both pilots.
The reason is the downside.

*2) Why I know it.* Rock Pull deals heavy damage if the opponent switches, and it deals damage to Gorillax itself
if they don't. So a wrong read hurts you for nothing. Against a rational opponent who won't always switch, the
expected value of clicking it is negative, so it never gets clicked.

*2.5) Why isn't what we have working.* This is mechanical, not piloting. The read is fine as a concept, but the
punishment for guessing wrong is too steep to ever risk. A move you can't afford to be wrong on is a move you
don't press.

*3) Uncertain?* Low. The self-damage clause is the whole problem, and it's right there in the move text.

*4) Validate?* Static first, and I've run it; a scripted check confirms the fix.
- Compare the wrong-read line to a plain attack: a stay-read Rock Pull deals 30 self-damage and zero to the
  opponent, versus 95 from Pound Ground that turn — confirmed dead.
- Check the correct-read payoff: it pays only 80 base, below a normal attack, so even the upside is modest.
- Mock the fix (swap the self-damage for about 40 base to the opponent), then re-check the wrong-read line is now
  merely mediocre, not punishing.
- If a softened whiff makes Rock Pull a low-risk read people actually click, ship it; the 80-base correct read
  is below a normal hit, so it was never a high-variance tool worth the self-damage.

*5) What would change my mind.* If the correct-read payoff were large enough that the rare hit justified the
frequent self-damage, it'd be a high-variance tool, not a dead one. The 80-base correct read is below a normal
attack, so it isn't. The numbers settle it.

*6) Easy to test?* Yes, both halves are cheap and scriptable, and the static half is done.

*7) Simulated result.* With the whiff softened to a weak hit, Rock Pull becomes a low-risk read people will
actually make.

*8) Consistent with (1)?* Yes. It's dead because the downside is punishing, and softening it fixes that.

**[Property] Soften the whiff, and give Angery a rage payoff so the ability matters.**

*1) Opinion.* A wrong Rock Pull should deal reduced normal damage to the opponent, not hurt Gorillax. And at
three Angery stacks, Gorillax's next attack should gain priority and ignore the target's defensive stat boosts,
on top of the existing heal.

*2) Property.* This supports risk/reward and synergy. The read becomes clickable, and the slow body finally has a
reason to soak hits.

*3) Why.* Gorillax has the highest Attack in the game, so another flat +ATK on the ability is filler — you
flagged this, and it's right. The interesting payoff is priority on a brick. Gorillax is slow, so it eats hits
going second, which charges Angery on its own; letting the three-stack hit strike first turns eating hits into
a real threat instead of a bigger number. Pairing that with armor-pierce makes it a specific answer to bulky
setup mons that hide behind defensive boosts, which is a niche, not raw power.

*4) Better alternatives?* We could instead make the three-stack payoff a free, empowered nuke, or keep the
existing flat Attack buff.

*5) Their tradeoffs.* A free empowered nuke risks overtuning a mon that's already at 54%, and it overlaps
Aurox's take-a-hit ramp. The flat Attack buff is the filler we're removing. Priority plus armor-pierce is a
narrower, safer payoff aimed squarely at walls.

*6) Still hold it?* Yes, since Gorillax is strong and we don't want to add raw power.

*7) Amend.* Keep a small per-stack Attack bump too, so early Angery stacks aren't wasted before you reach three.

*8) Empirical hook.*
- The static Rock Pull compare is done.
- Script a three-stack Angery hit into a boosted wall and confirm the priority lands the hit first and the pierce
  ignores the defensive boost.

*Summary:*
- **Rock Pull** — ? / 3 / Earth / Physical — on a wrong read, deal reduced normal damage to the opponent (about
  40 base) instead of 30 self-damage. The correct-read 80-base hit and its +priority stay as they are.
- **Angery (ability)** — each hit taken still builds a stack; at three stacks Gorillax's next attack ignores the
  target's defensive stat boosts (the primary payoff, aimed at bulky setup walls), then the stacks reset and it
  heals as it does now. Priority-on-the-hit stays a candidate to test only if armor-pierce alone underperforms —
  from 302 Attack, both together likely one-shots. Keep a small per-stack Attack bump so early stacks aren't
  wasted.
- **Rock Pull** — keep the whiff clearly worse than a normal attack (low power for the 3 stamina), not just
  non-punishing, so the Pursuit read stays a real bet rather than a free throw.
- New moves: none.

> **[Predicted]** The Rock Pull fix removes the punishment but not the underlying problem. After it, a correct
> read pays 80 base and a wrong read pays 40 — both below a normal attack. So even reading correctly is worse
> than clicking Pound Ground, and there is no reason to press the move. If we are changing it, the correct-read
> payoff has to beat a normal hit, or the read is never worth taking.

> **[Addressed]** Reading the source corrects my own criticism. Rock Pull only fires when the opponent switches,
> it resolves at SWITCH_PRIORITY+1, and it hits the fleeing mon before the switch completes. A normal 95-power
> Pound Ground that turn would hit the incoming mon instead, or let the fleer escape untouched. So the 80-base
> isn't competing with a normal hit on the same target — its value is switch-denial, catching a weakened mon
> before it pivots to safety, which a normal attack can't do. That means the correct-read branch isn't
> dominated. The genuine risk runs the other way: softening the whiff from 30-self to 40-to-opponent removes the
> downside, so Rock Pull could become a no-risk Pursuit you always throw. The fix should keep the whiff clearly
> worse than just attacking — low power for the 3 stamina — so guessing wrong is a bad turn without being
> self-harm. That reframes the change from "make it clickable" to "remove the self-damage feel-bad while keeping
> the read a real bet."

> **[Predicted]** The Angery change may now be too strong. Gorillax already has the highest Attack and sits at
> 54%. At three stacks it hits first, ignores defensive boosts, and heals — a priority armor-piercing hit from
> the strongest attacker in the game. We should check that it does not simply one-shot common targets. The
> armor-pierce may be enough on its own, and adding priority on top could be overkill. We need the actual damage
> number at three stacks.

> **[Addressed]** The concern is right, so I'm splitting the payoff. Three conditions still gate it — Gorillax
> must take three hits first, that's three turns of damage, the stacks reset, and it's one attack — so it's a
> slow charge, not an on-demand nuke. But from 302 Attack, a priority armor-piercing hit that also heals is
> likely too much stacked together. So pick one: armor-pierce is the primary payoff, since it answers the bulky
> setup walls that hide behind defensive boosts, which is the intended niche. Priority stays a candidate to test
> only if armor-pierce alone underperforms. Validation is arithmetic first: compute the three-stack hit's damage
> against the frailest common targets and check for one-shots, then a light script to confirm.

---

## Sofabbi — 51% (in band; incoherent gambling theme)
Nature gambler with high bulk. Only Gachachacha actually gambles, and the greedy pilot spams Snack Break.

**[Thing] Gachachacha's auto-KO tails are no-counterplay swings, and the rate is quietly self-biased.**

*1) Reason.* Gachachacha can delete a mon on a dice roll, with no decision on either side. The move's own code
comment intends a 5% chance to KO Sofabbi and a 5% chance to KO the opponent. The implementation doesn't match
that intent, which is its own separate bug.

*2) Why I know it.* I read the roll: it's `rng % 210`, with the KO bands at 5/210 for the self-KO and 4/210 for
the opponent-KO. That's about 2.4% self, 1.9% opponent, ~4.3% total — not the flat 10% a "5% and 5%" reading
would give. So the tails are rarer than the design note claims, and they're asymmetric against Sofabbi: it's
more likely to blow itself up than to blow up the opponent. The rest of the roll is uniform power.

*2.5) Why isn't what we have working.* Two things are wrong. The gamble has no agency — you click it and pray —
and the rest of the kit doesn't share the gambling theme, so the identity is only half there. On top of that,
the KO bands undershoot their own intended 5%/5% and skew the wrong way, so the implementation is off from the
design regardless of whether we keep the tails.

*3) Uncertain?* Low on the tails being feel-bad. The softer question is how often they actually swing a game,
and now that I've read the rate, the answer is "less often than I first claimed."

*4) Validate?* Static probability check, and it's done; a seed sweep confirms it.
- From the code, the roll is `rng % 210` with KO bands 5/210 self and 4/210 opponent — about 2.4% self, 1.9%
  opponent, ~4.3% total, not the flat 10% I first claimed.
- Cast Gachachacha across many seeds and confirm the observed frequency matches the arithmetic and the self-bias.
- If we soften the tails, replace the KO bands with heavy self-recoil and a big fixed hit, then re-run the sweep
  to confirm no more instant kills.
- The bias and the 5%/5%-intent mismatch are worth fixing regardless; the raw ~4.3% frequency is low enough that
  softening the tails is lower priority than the bias fix.

*5) What would change my mind.* At ~4.3% total the auto-KO feel-bad is real but not urgent, so softening the
tails is a lower priority than I first thought. What is clearly worth fixing regardless is the self-unfavorable
bias and the gap between the 5%/5% intent and the implementation.

*6) Easy to test?* Yes. The probability is exact, and the seed sweep is cheap.

*7) Simulated result.* I expect the seed sweep to land near 2.4% self and 1.9% opponent, confirming the
arithmetic and the bias.

*8) Consistent with (1)?* Amended. The tails are uninteractive swings, but rarer and more self-biased than the
first draft assumed, so the headline fix is the bias and the intent mismatch, not the raw frequency.

**[Property] Turn the gamble into a decision, using stamina as chips.**

*1) Opinion.* Correct Gachachacha's bias and soften the tails so no cast is an instant kill. Then add Double or
Nothing, a wager move where you spend stamina, fed by Carrot Harvest, to skew the odds in your favor.

*2) Property.* This supports fun through real risk/reward, and it ties the kit together through synergy.

*3) Why.* Sofabbi is bulky and stamina-rich, because Carrot Harvest regenerates stamina half the time. So
stamina is the natural currency for a gambler. Paying chips to improve a bet turns raw variance into a
press-your-luck choice, which is what makes gambling fun, and a losing flip still chips so it's never a fully
dead turn.

*4) Better alternatives?* We could instead make every move random.

*5) Their tradeoffs.* Four independent dice is noise, not a plan, and it gives the opponent nothing to read. One
wild spin (Gachachacha) plus one controllable bet (Double or Nothing) is a cleaner identity and an actual
decision.

*6) Still hold it?* Yes. It fixes the feel-bad and the incoherence at once, and it gives the stamina engine a
payoff.

*7) Amend.* Keep the losing flip's chip so a wager is never a fully dead turn, and keep Snack Break as the
sustain that buys more spins.

*8) Empirical hook.*
- Re-run the seed sweep after correcting the bias to confirm no instant kills.
- Script a lost Double or Nothing flip and confirm it still deals its 30 floor.

*Summary:*
- **Gachachacha** — ? / 3 / Cyber / Physical — replace the auto-KO bands with heavy self-recoil and a big fixed
  hit, so no cast is an instant kill; also correct the self-unfavorable bias so it matches the intended 5%/5%.
- **Double or Nothing (new)** — 120 or 30 / 2 / Nature / Physical / 100 / 0 — a coin flip. Heads deals 120
  power, tails deals 30. You may pay 1 or 2 extra stamina to raise the heads chance: +1 makes it 65%, +2 makes
  it 80%. A lost flip still deals the 30, so it's never a dead turn. Replaces Guest Feature or Unexpected
  Carrot, whichever tests weaker.

> **[Predicted]** The reworked Gachachacha still has no numbers. What is the big fixed hit, and how heavy is the
> self-recoil? We need the full mechanics before we can judge it. Double or Nothing also needs a second look. At
> 80% heads for 120 power, paying 4 stamina in total, is the boosted bet simply better than a normal attack? If
> it is, the gamble collapses into always paying for 80% and swinging 120, which is not a decision. We should
> compare the boosted bet against a plain attack and against Gachachacha. (This is a Validation step.)

> **[Addressed]** On Gachachacha's numbers: keep the uniform 0–200 spin, and replace the two KO bands with a
> capped big hit (about 180 power) and, on the former self-KO band, heavy self-recoil of roughly a third of max
> HP instead of death. No instant kills, still swingy, exact numbers to tune. On Double or Nothing, here's the
> expected-value math. Base is 2 stamina at 50/50 for 120 or 30, so EV 75. At 3 stamina (65% heads) EV is
> 0.65×120 + 0.35×30 = 88.5. At 4 stamina (80% heads) EV is 0.8×120 + 0.2×30 = 102. So the fully-boosted bet is
> EV 102 for double a normal move's stamina, and it still whiffs to 30 one time in five. Against a reliable
> ~90-power 2-stamina attack, the boosted bet trades stamina and variance for a higher ceiling, so it's a real
> choice rather than an auto-pick — but it's close. The heads% per stamina and the 120 ceiling are the tuning
> levers if it starts to dominate.

---

## Pengym — 46% (in band)
Ice gym-bro. Its identity is the Frostbite → Deep Freeze combo plus a workout buff. The sim defaults it to
Pistol Squat. Two threads, and they interact.

**[Thing] The Frostbite → Deep Freeze combo is matchup-dependent, not a dud.**

*1) Reason.* Chill Out is not just a combo setup. It applies Frostbite, which is a real status with its own value.
So "the combo is a dud" is the wrong claim. The right claim is narrower: the combo's worth depends on the
opponent's type. Deep Freeze also consumes the Frostbite for its double hit, so you trade an ongoing debuff for a
burst, which is a genuine hold-or-pop choice.

*2) Why I know it.* I checked the effect itself rather than the design note. Frostbite halves the target's Special
Attack, and it also deals 1/16 of max HP each turn. Both of those hurt a special attacker badly, and Chill Out
costs no stamina. Pengym's natural prey is special, like Malalien at SpATK 322, so halving that is a bigger swing
than most single hits. Against a physical attacker, though, the halve does nothing.

*2.5) Why isn't what we have working.* The forced-combo run came out flat because it used Chill Out into every
opponent, including physical ones where the halve is dead weight. So the average of "great" and "useless" washed
out to "meh." The combo is not bad, it's conditional. The genuinely dead case is Chill Out into a physical
attacker, where its only value is the chip and the Deep Freeze enable.

*3) Uncertain?* The special-matchup value is not uncertain, because halving Special Attack is plainly strong. What
is uncertain is the field mix. I don't know how often Pengym faces special versus physical attackers, and that
fraction decides how often Chill Out is great versus dead.

*4) Validate?* Static first from the damage formula, then a scripted per-matchup test.
- Static: Frostbite halves Special Attack, so a special attacker's next hit lands at about half its normal value,
  exact from the formula.
- Script Chill Out on turn one and the opponent's attack on turn two, and read Pengym's HP loss, once versus a
  special attacker and once versus a physical one. We change nothing, since Chill Out already applies Frostbite.
- Check whether the opponent pivots the frostbitten mon out; if they routinely switch it away, Chill Out's value
  collapses toward the physical case.
- If the halve sticks and swings the special matchups, the reframe holds; if they routinely pivot it out, the
  original "dud" read revives.

*5) What would change my mind.* If the opponent routinely switches the frostbitten mon out, taking the debuff with
it, then Chill Out's standalone value collapses toward the physical case, and the original "dud" read revives. If
the halve sticks and swings the special matchups, the reframe holds.

*6) Easy to test?* The per-matchup damage is easy and mostly answered by the numbers. The "do they pivot it out"
question needs a fuller game, so it's partly arena-dependent.

*7) Simulated result.* I expect Chill Out to test as a near-Tailwind-sized swing against special attackers and a
near-dead pick against physical ones. The combo is real but conditional.

*8) Consistent with (1)?* Yes, and it corrects the earlier draft. The defect isn't the combo, it's that Chill Out
has one dead matchup.

**[Property] Give Chill Out a floor in its dead matchup, not a combo rework.**

*1) Opinion.* The SpAtk halve and the Deep Freeze combo are both good, so we should leave them alone. Instead, we
can give Chill Out a small effect against physical targets. For example, we can deal chip damage and lower the
opponent's speed. Then it's never a dead turn.

*2) Property.* This supports risk/reward and cleaner decisions. It narrows the gap between Chill Out's best and
worst case so the move is always a reasonable pick.

*3) Why.* A small always-on rider raises the floor without inflating the ceiling, so the special matchups play the
same. The speed drop also does double duty, because it makes it harder for a special attacker to pivot the
frostbitten mon out. That shores up the one way its good matchup gets played around.

*4) Better alternatives?* We could leave Chill Out as-is and accept the dead matchup. We could tax Pistol Squat
instead. Or we could change Frostbite globally to also shave physical damage.

*5) Their tradeoffs.* Leaving it ships a dead button in a common matchup. Taxing Pistol Squat fixes crowding, not
Chill Out's dead matchup. Changing Frostbite touches every Frostbite user, like Aurox and Xmon, so its blast radius
is far too large for one mon's floor.

*6) Still hold it?* Tentatively, ranked just above doing nothing. I'd want the field-mix number first, because if
physical attackers are rare the dead matchup barely matters.

*7) Amend.* Sequence it behind the measurement. Add the floor rider only if the physical matchup turns out to be
common.

*8) Empirical hook.*
- Statically count the roster's physical versus special attackers from their attack and specialAttack stats; if
  special attackers dominate, Chill Out is rarely dead and the rider isn't worth it.
- Mock the reworked Chill Out and script it into a physical matchup to confirm it now does non-zero work.

**[Thing] Pistol Squat is the auto-default because it's damage plus disruption for cheap.**

*1) Reason.* Pengym reaches for Pistol Squat first, at 35% under hard. That isn't because the combo is bad. It's
because Pistol Squat is quietly the best button.

*2) Why I know it.* It deals 80 damage for 2 stamina, and it forces the opponent to switch. So it's damage and
disruption in one move. Its only cost is −1 priority, but Pengym's speed of 149 already loses the turn order to
the fast threats, so going last often costs nothing it wasn't giving up anyway.

*2.5) Why isn't what we have working.* This is the inverse problem: it works too well. A near-full-power attack
with a free forced switch makes the interesting moves look bad by comparison. It isn't dead, it's crowding the kit.

*3) Uncertain?* Some. I'd want to split how much of its value is the 80 damage versus the forced switch, which a
scripted run can isolate.

*4) Validate?* Scripted test to isolate the forced-switch value.
- Script Pistol Squat against a plain 80-power hit with no switch, and measure the win-margin difference that
  comes purely from the forced switch. We change nothing, since both moves exist.
- Split the value: check how much comes from the 80 damage versus the forced switch, especially against setup and
  frail mons.
- If the forced switch is worth little because the opponent switches to something fine, Pistol Squat is just a
  slightly-slow attack and there's no crowding problem; if it's worth a real chunk, it's the efficient default
  and needs a tax.

*5) What would change my mind.* If the forced switch is worth little, because the opponent switches to something
fine, then Pistol Squat is just a slightly-slow attack and there's no problem.

*6) Easy to test?* The damage half is easy. The switch-value half wants a fuller game, so it's partly
arena-dependent.

*7) Simulated result.* I expect the forced switch to be worth a real chunk against setup and frail mons. So it
genuinely is the efficient default.

*8) Consistent with (1)?* Yes. It's dominant by efficiency, not broken.

**[Property] Tax Pistol Squat so it's a choice, but only after the combo fix.**

*1) Opinion.* Give it a small tax, either +1 stamina or a force-switch that only triggers below some HP. Do this
only if it still dominates after Chill Out is fixed.

*2) Property.* This supports meta and complexity, by restoring the choice between disrupting and setting up.

*3) Why.* If the reworked combo is meant to matter, its rival can't be a strictly cheaper do-everything button.

*4) Better alternatives?* We could buff the other moves instead of nerfing this one.

*5) Their tradeoffs.* Buffing everything up is power creep, and it doesn't address one button doing damage and
disruption for cheap. A small tax is surgical.

*6) Still hold it?* Contingently. It depends on the combo fix landing first.

*7) Amend.* Sequence it: fix Chill Out, re-measure usage, and tax Pistol Squat only if it's still the auto-pick.

*8) Empirical hook.*
- After the Chill Out change, re-run move-usage.
- If Pistol Squat is still above 35% and the combo is below 10%, it needs the tax.

*Summary:*
- **Chill Out** — 0 / 0 / Ice / Other — keeps its Frostbite application; add a rider so it isn't dead into
  physical attackers, dealing light chip and dropping the opponent's speed. Contingent on the field mix being
  physical enough to matter.
- **Pistol Squat** — 80 / 2 → 3 / Metal / Physical / 100 / −1 — a small stamina tax, only if it still dominates
  after the Chill Out fix.
- New moves: none.

> **[Predicted]** The field mix is treated two different ways. The summary states about 50% physical as if it is
> settled, but the section says we still need to count it. We should settle that first, because the whole Chill
> Out rider depends on how common physical attackers actually are. This is a static Validation step: count the
> roster's physical versus special attackers from their stats before we build the rider.

> **[Addressed]** Counted it from mons.csv. Taking the higher offense stat per mon across the 12 opponents:
> physical-leaning are Gorillax (302/112), Sofabbi (180/120), Aurox (150/100), Nirvamma (202/140), Iblivion
> (199/180), and Ghouliath (157/151) — six. Special-leaning are Malalien, Volthare, Xmon, Ekineki, Embursa, and
> Inutia — six. So the field is about 50/50, which confirms the exec-summary figure. Ghouliath and Inutia are
> near-even and could tip either way, but the heavy hitters split 5/5, so the conclusion holds. Chill Out is
> therefore dead in roughly half its matchups without the floor, so the rider is justified. The claim is now
> measured, not assumed.

---

## Embursa — 47% (in band)
Fire burn-fuel bear. The sim carries with Set Ablaze, never uses Q5, and greedy spams Honey Bribe. Rest
auto-heals Burn, so the fuel never stacks.

**[Thing] The burn-fuel identity never turns on, because Embursa can't control the Burn.**

*1) Reason.* Embursa is supposed to thrive while Burned, but it's almost never Burned on purpose. Tinderclaws
gives it a +50% SpATK boost while Burned, but the Burn arrives on a random roll after a move, and Rest — the
default recovery — heals it off. So the fuel neither lands when you want it nor stays once it's up.

*2) Why I know it.* The ability burns Embursa about a third of the time after a move, and grants +50% SpATK while
that Burn holds. The player never chooses when it triggers. You flagged this directly: Embursa can't really
control when the Burn fires, which guts the agency. A boost you can't schedule is just occasional free damage,
not a risk-reward loop.

*2.5) Why isn't what we have working.* This is design plus mechanics. Generation is random, so there's no
decision in earning the boost, and the moves don't key off being Burned, so even when it's up it only changes a
number, not a plan. Rest healing the Burn isn't the whole villain — the real gap is that the player has no lever
on the burn at all.

*3) Uncertain?* Low on the mechanism. The open question is whether a stacked-burn Embursa actually out-damages a
safe one, once the player can choose to escalate. That's the untested premise the whole rework rides on.

*4) Validate?* Static first, then a scripted escalated-versus-safe test.
- Static: a +50% SpATK boost multiplies special damage by 1.5, and a degree-scaled boost climbs the multiplier
  with the burn degree, exact from the formula.
- Mock a controlled self-burn (Heat Beacon) and a degree-scaled boost, then script Embursa raising its own degree
  and firing Set Ablaze.
- Compare damage and self-inflicted HP loss over several turns against a safe, un-burned line, keeping Rest's
  heal as an escape hatch.
- If the escalated line out-damages the safe one without Embursa killing itself, the premise holds; if the chip
  plus boost nets negative even when escalated on purpose, soften the identity instead.

*5) What would change my mind.* If the burn chip plus the boost nets negative even when the player escalates on
purpose, the identity should be softened rather than leaned into. If the escalated damage clearly beats the safe
line, the premise holds.

*6) Easy to test?* Yes. The multiplier is exact, and the several-turn script is cheap.

*7) Simulated result.* I expect the escalated line to win on damage but to demand real HP management, so it's a
proper risk-reward rather than free power.

*8) Consistent with (1)?* Yes. The fuel never turns on because the player can't control it, and the rework hinges
on the escalated line actually paying.

**[Thing] Q5 is a dead slot, because a five-turn-delayed payoff can't compete with attacking now.**

*1) Reason.* Q5 is used about 0% of the time. It deals its 150 damage five turns after it's cast and burns the
enemy. No pilot picks a payoff it can't score now, and even a human can't reliably bank on damage that lands
five turns out.

*2) Why I know it.* A 1-ply pilot can't see five turns ahead, so Q5 scores as zero on the turn you'd click it,
and its usage is near-zero in both pilots. For a human, the target can switch or the game can end before it
resolves, so the bank rarely pays.

*2.5) Why isn't what we have working.* This is partly piloting and partly design. The pilot can't value delay,
and the delay itself is fragile against switching and game-length. Either way the slot sits dead.

*3) Uncertain?* Low. The comparison is the load-bearing part, and it's a fixed script.

*4) Validate?* Scripted test, since it's a multi-turn payoff.
- Script the current Q5, then five turns of a normal attacker, and compare Q5's eventual 150 to the two normal
  hits landed over the same span. We change nothing to measure the current move.
- Separately script the reworked immediate Q5 (130 now, burn the enemy, +1 self-degree) and compare its turn-one
  value plus engine feed against just attacking.
- If the delayed 150 beat two undodgeable hits it'd be worth keeping; two normal hits over five turns clear 150
  and can't be dodged by a switch, so the immediate version wins.

*5) What would change my mind.* If the delayed 150 beat what Embursa could deal by just attacking over those five
turns, it'd be a strong tool a smarter pilot could use. Two normal hits over five turns clear 150, and they
can't be dodged by a switch, so it loses.

*6) Easy to test?* Yes, it's a fixed five-turn script.

*7) Simulated result.* I expect Q5 to lose to just attacking, because delayed damage is easy to dodge and Embursa
gives up tempo to set it up.

*8) Consistent with (1)?* Yes. It's a weak slot, not just an unpiloted one, so it should become an immediate hit.

**[Property] Give the player control of the Burn, scale the boost with degree, and make Q5 an immediate hit that stokes the fire.**

*1) Opinion.* Keep Rest's heal as the pressure valve, and give Embursa a lever on its own Burn through Heat
Beacon, with the SpATK boost scaling up as the burn degree climbs. Rework Q5 from a delayed bomb into a strong
immediate special that also raises Embursa's own degree, so it feeds the same engine.

*2) Property.* This supports risk/reward, synergy, and flavor. The mon chooses to burn itself for power, and its
escalation is a decision instead of a die roll.

*3) Why.* A controlled self-burn creates the stay-and-escalate decision the mon is named for, and a boost that
scales with degree means risk and reward climb together. Keeping Rest's heal matters, because at high degree the
chip is heavy — without the escape hatch, escalating goes suicidal, so removing it was the wrong call in my
first draft. A Q5 that hits now and stokes the fire ties the burst into the engine rather than floating outside
it.

*4) Better alternatives?* We could stop Rest from healing Burn, which was my earlier draft, or leave Q5 delayed
and only touch the ability.

*5) Their tradeoffs.* Stopping the Rest-heal removes the only pressure valve, so high-degree Embursa just kills
itself — that makes the risk un-manageable rather than interesting. Leaving Q5 delayed keeps a dead slot. The
control-plus-scaling package is the one that turns the passive boost into an identity while staying survivable.
Note also that Honey Bribe already halves the opponent's Special Defense, which is real setup for Embursa's
special attacks — separate from its heal-both, and easy to miss because the greedy pilot just spams it as a
heal. So the kit already has a setup move, and the burn-fuel rework should be judged against that, not against a
kit that has nothing.

*6) Still hold it?* Yes, gated on the step-4 test showing the escalated line pays.

*7) Amend.* Cap the self-burn escalation so it's a risk, not a guaranteed suicide, and leave Honey Bribe alone
since it's a stronger slot than the usage suggests.

*8) Empirical hook.*
- Run the escalated-versus-safe damage script from step 4.
- Run the Q5-versus-attacking script to confirm the immediate Q5 pays.

*Summary:*
- **Tinderclaws (ability)** — scale the SpATK boost with the burn degree instead of the flat +50% it gives now:
  first pass +50% / +75% / +100% at degree 1 / 2 / 3, against self-chip of maxHp/16 · /8 · /4 per turn. Keep
  Rest's heal as the pressure valve, since degree 3 is ~25%/turn (about 105 on 420 HP) and goes suicidal
  without it.
- **Q5** — 130 / 2 / Fire / Special — reworked from the five-turn delay to: deal 130 damage now, burn the enemy,
  and raise Embursa's own burn degree by one. This is the player's escalation lever, so the burn is a choice,
  not a random roll. Replaces the delayed Q5.
- **Heat Beacon** — unchanged. It already burns the opponent and grants Embursa +1 priority next turn, so it's
  not a dead slot; the earlier plan to repurpose it into a self-burn dial is dropped, since Q5 covers that.
- **Honey Bribe** — unchanged. Its SpDef cut is real setup for Embursa's special attacks, so it stays.
- New moves: none beyond the Q5 rework.

> **[Predicted]** The claim that risk and reward climb together needs numbers to back it. At each burn degree,
> what is the SpATK boost, and what is the self-chip? Burn chips 1/16, then 1/8, then 1/4 of max HP as the
> degree rises, so escalating gets expensive quickly. The boost scaling only pays if it outruns that chip, and
> right now that is asserted rather than shown. We should build the degree-to-boost-to-chip table and validate
> the escalated line against the safe one. Separately, Heat Beacon is an existing move — what does it do today,
> and do we lose anything by repurposing it into the burn dial?

> **[Addressed]** The table, from source: Burn chips maxHp/16 at degree 1 (~6.25%/turn), maxHp/8 at degree 2
> (~12.5%), and maxHp/4 at degree 3 (~25%). Embursa's max HP is 420, so degree 3 is about 105/turn — near
> suicidal, which is exactly why Rest has to stay as the valve. Tinderclaws today is a flat +50% SpATK
> regardless of degree. A first-pass degree-scaled version: +50% at degree 1, +75% at degree 2, +100% at degree
> 3. At degree 3 that's ×2 special damage against ~25%/turn self-chip, a real risk/reward, and whether the boost
> outruns the chip is the sim question. On Heat Beacon: it is not a dead slot today. It burns the opponent and
> grants Embursa +1 priority next turn, so repurposing it into a self-burn dial would lose both. So I'm dropping
> the repurpose. The player already controls escalation through Q5, which raises Embursa's own degree by one, so
> Q5 plus Tinderclaws re-applying burn is the escalation lever, and Heat Beacon keeps its opponent-burn and
> priority.

---

## Volthare — 50% (in band)
Fast Lightning/Cyber. The sim uses Dual Shock, Electrocute, and Mega Star Blast, and rarely picks Round Trip.
Zap, a turn-skip status, is swingy, and Round Trip is a thin pivot.

**[Thing] Zap is a swingy, all-or-nothing status, and Round Trip is a weak pivot.**

*1) Reason.* Zap's skip-a-turn is binary. It either does nothing or steals a whole turn. Round Trip deals 30 and
switches, which is thin.

*2) Why I know it.* A Zapped mon skips its next action entirely, so a low-chance proc is either wasted or
game-deciding, with nothing the target can do about it. Round Trip's 30 power is small even for a pivot, so its
3–11% usage is honest. Volthare's better buttons crowd it out.

*2.5) Why isn't what we have working.* Zap's swing is a tuning problem, not a mechanic to throw out. We want a
stun-style status in the game, so the fix is to make Zap less binary, not to replace it. Round Trip is
mechanical: the payoff is just too small.

*3) Uncertain?* Some, on how often Zap actually procs and how much the stun swings a game. That's a frequency
question the arena can settle.

*4) Validate?* Scripted test to measure Zap's tempo swing at its current proc rate.
- Script a Zapped attacker and log how often the skipped turn is wasted (the target had nothing important to do)
  versus game-deciding (it skipped a KO or a key move).
- Lower Zap's proc rate or shorten its duration in the mockup, then re-run and re-measure the swing; expect the
  feels-bad share to fall while the stun still lands often enough to matter.
- Separately mock a distinct Speed-drop status and check it produces steady tempo without the all-or-nothing
  feel.
- If the lower-proc stun stays impactful but less swingy, ship that; if it does nothing, the swingy skip was at
  least meaningful, and I'd shorten its duration rather than weaken the proc.

*5) What would change my mind.* If a lower-proc Zap still lands often enough to matter but stops stealing games
out of nowhere, that's the better tune. If it does too little, the swingy skip was at least impactful, and I'd
shorten rather than weaken it.

*6) Easy to test?* Yes, the tempo swing is scriptable in a couple of turns.

*7) Simulated result.* I expect a lower-proc or shorter Zap to keep the stun's bite while cutting the feels-bad,
and a separate Speed status to give Volthare steady value.

*8) Consistent with (1)?* Yes. Zap stays a stun and gets tuned, and Round Trip is thin and gets a bump.

**[Property] Keep Zap as a stun, add a separate Speed-drop status, and firm up the pivot.**

*1) Opinion.* Keep Zap as a stun that skips the target's next turn — that's the stun-style status the game wants.
If it's too swingy, lower its proc rate or shorten it rather than replacing the mechanic. Any value-debuff should
be a separate status that lowers Speed, not folded into Zap.

*2) Property.* This supports meta and risk/reward. Volthare gets a clean stun plus a steady speed-control tool,
which is a defined role.

*3) Why.* A stun and a speed-drop do different jobs, so they shouldn't be the same status. Speed is also easier to
tune than priority, because a priority shift rewrites the turn order for every move at once, while a speed number
just moves one mon down the order. Splitting them lets each be balanced on its own, and both give the opponent a
real out, since a switch clears them.

*4) Better alternatives?* We could keep the skip-turn and just raise its proc rate, or fold a speed cut into Zap
itself.

*5) Their tradeoffs.* Raising the proc doubles down on the swing, which is the feels-bad we're removing. Folding a
speed cut into Zap loads one status with two jobs and makes it harder to tune. Two clean statuses are more
interactive and easier to balance.

*6) Still hold it?* Yes.

*7) Amend.* Make Dual Shock's self-Zap a real cost rather than a self-skip, and bump Round Trip's power so the
pivot is worth clicking.

*8) Empirical hook.*
- Script the stun at a few proc rates and confirm it lands often enough to matter without stealing games.
- Script the separate Speed-drop and confirm it produces steady tempo the opponent can still switch out of.

*Summary:*
- **Zap (status)** — keep it as a stun that skips the target's next turn. If it's too swingy, lower its proc rate
  or shorten it rather than replacing the mechanic.
- **New Speed-drop status** — a separate value-debuff that lowers Speed, easier to tune than priority across
  every move. Carrier: Dual Shock self-applies it (replacing its self-stun); Electrocute keeps applying the stun
  Zap to the opponent. Optionally spread the Speed-drop offensively too, but drop that if it tests as fiddly.
- **Round Trip** — 30 → 50 / 1 / Lightning / Special — a small power bump so the pivot is worth clicking.
- New moves: none.

> **[Predicted]** The new Speed-drop status has no carrier. A status needs a move to apply it, and none is
> named. We should say which of Volthare's moves delivers it. There is also a complexity question. Volthare
> would now carry two separate statuses, a stun and a speed drop. Is that more status complexity than one mon
> needs, or is the split worth it? We should state the tradeoff plainly.

> **[Addressed]** The source names the carrier for me. Dual Shock currently self-applies the stun Zap — a full
> self-skip — plus team Overclock, for 60 power at 0 stamina. That self-skip is the harsh cost the section
> wanted to soften. So the clean move is: Dual Shock self-applies the new Speed-drop instead of the self-stun.
> That makes its cost real but survivable — Volthare is slower for a couple of turns rather than losing a whole
> turn — which is exactly the "self-Zap becomes a real cost" line. Offensively the stun stays on Electrocute. So
> the split is: Electrocute applies the stun to the opponent, Dual Shock self-applies the Speed-drop. On
> complexity: two statuses is more than most mons carry, but each is simpler than today's overloaded Zap, and
> Volthare is the designated status-spreader, so it fits. If it tests as fiddly, keep the Speed-drop only as
> Dual Shock's self-cost and don't spread it offensively.

---

## Aurox — 41% (validated: mispiloted, not weak)
Metal permabull tank. Already worked and validated. The tank line moves it from 35% to 47%, and the
per-opponent split shows a matchup-defined role.

**[Thing] "Aurox is weak" was about 85% a piloting artifact.**

*1) Reason.* Aurox is below-average but functional, not bottom-tier. When it actually plays its tank line, it jumps
from 35% to 47%. So the low aggregate measured a mon that never did its combo.

*2) Why I know it.* We scripted the line: Iron Wall on entry, then Bull Rush, with Up Only ramping as it's hit.
Iron Wall usage went from near 0% to 17.5%, and the win rate climbed 12 points. The per-opponent split then showed
it isn't uniformly mediocre. It beats slow and setup mons it out-grinds, and it loses to burst and Fire that
out-race the wall.

*2.5) Why isn't what we have working.* Piloting dominated. Both default pilots ignore Iron Wall, so the regen half
of the engine never ran, and Up Only ramped with no sustain behind it. That's a client problem, not a kit problem.

*3) Uncertain?* Resolved. The tank line test settled it.

*4) Validate?* Done, in the chomp scripted rig.
- Added an override script (Iron Wall once on entry, then Bull Rush) and re-ran win rate; Iron Wall usage went
  0% → 17.5% and the number moved 35% → 47%.
- Bucketed the win rate by opponent and confirmed a matchup split: wins versus slow/setup mons it out-grinds,
  losses versus burst and Fire that out-race the wall.
- We changed nothing in the engine, so the movement is purely piloting.

*5) What would change my mind.* Already answered: the tank line moved the number, so it isn't structurally weak.

*6) Easy to test?* It was, and it's done.

*7) Simulated result.* Not applicable, because we ran it.

*8) Consistent with (1)?* Amended: not weak, mispiloted.

**[Property] Replace Volatile Punch with Bull Trap, not a damage counter.**

*1) Opinion.* Volatile Punch is dead in every pilot, so it should be replaced. The replacement should be Bull Trap,
a taunt that forces the opponent to use damaging moves.

*2) Property.* This supports synergy, risk/reward, and flavor. It forces the hits Up Only and Iron Wall both want.

*3) Why.* Bull Trap makes the opponent attack, which feeds Up Only's ramp and Iron Wall's regen when they stay in.
It's a control move, not a damage move, so it never competes with Bull Rush. And it's on-flavor: bait them into
charging the wall. One honest caveat: "feeds Up Only" only holds if the opponent stays and is forced to attack.
If they switch to escape, Bull Trap instead denies their setup, which is still fine but doesn't feed the ability.

*4) Better alternatives?* The obvious alternative is a damage counter that hits back for a share of the damage taken.

*5) Their tradeoffs.* We tested the counter, and it fails twice. It's prediction-dependent, dealing 257 when the
opponent attacks and 15 when they don't. And because Aurox is the slowest mon, it always has ammo, so the counter
cannibalizes Bull Rush. Bull Trap avoids both, because it forces the outcome instead of betting on it. Framed
honestly, Bull Trap helps Aurox's good matchups (setup and passive teams), not its burst-and-Fire losses, since
burst mons are already attacking — so it's a flavorful replacement for a dead slot, not a patch for weaknesses
we've agreed are acceptable counters.

*6) Still hold it?* Yes. The sim chose Bull Trap over the counter.

*7) Amend.* Give it a 2-turn duration, and let a switch escape it.

*8) Empirical hook.*
- Mock Bull Trap and confirm it feeds Up Only when the opponent stays and denies setup when they switch.
- Check its usage doesn't dent Bull Rush's, so the two don't compete.

*Summary:*
- **Bull Trap (new)** — 0 / 2 / Metal / Other / 100 / 0 — for two turns the opponent's active mon can only select
  damaging moves; a switch escapes it. Replaces Volatile Punch.
- Existing changed: none.

> **[Predicted]** Bull Trap needs its mechanics pinned down. How does the engine enforce damaging-moves-only —
> is it a filter on move selection? And against a pure support or setup mon, Bull Trap plus Iron Wall could lock
> it out for two turns. Is that the intended power level, or is it oppressive? The switch-escape may be the only
> thing keeping it fair, so we should confirm that out is always available. This lends itself to Validation:
> script Bull Trap against a no-attack mon and check whether the lock is fair.

> **[Addressed]** Feasible on an existing primitive. Sleep already calls engine.setMove(...) to overwrite a
> mon's chosen move with NO_OP at round start. Bull Trap works the same way: a Taunt effect checks the target's
> chosen move and, if its class is Other or Self, overwrites it with NO_OP — so a non-damaging pick is wasted,
> not blocked in the interface. Crucially, Sleep's code skips SWITCH_MOVE_INDEX, so switching is never
> overwritten. Bull Trap inherits that, which means the switch-escape is built into the mechanism, not bolted
> on. On the lock: a pure support mon under Bull Trap either wastes its turn or switches, and since switching is
> always available, it's a tempo tax, not a hard lock. The two-turn cap bounds it further. So the answer is yes,
> the out is always there. Validation stays worthwhile: script Bull Trap against a no-damaging-move mon and
> confirm it can always switch out.

---

## Xmon — 47% (in band)
Cosmic dream and sleep disruptor. The sim leans on Vital Siphon at 60%, never uses Somniphobia, and rarely uses
Night Terrors. Forcing the sleep engine tested worse than just spamming Vital Siphon.

**[Thing] The sleep and Night Terrors engine underperforms the boring Vital Siphon line.**

*1) Reason.* Xmon's signature synergy loses to just spamming Vital Siphon. When we forced the sleep engine, its win
rate dropped from 50% to 44%. So the cool line is worse than the plain one.

*2) Why I know it.* The engine self-harms. Contagious Slumber sleeps Xmon as well as the opponent, and Night Terrors
drains Xmon's own stamina each turn per stack. So the intended combo costs more than it pays, which the forced-line
override run confirmed.

*2.5) Why isn't what we have working.* This is mechanical, not piloting. The pieces have real self-costs that net
negative, so even played correctly the engine loses ground. Vital Siphon, meanwhile, quietly does a lot on its own,
because it also steals stamina, which is separate from its chip.

*3) Uncertain?* Low on the current engine failing, since we measured it. The open question is whether a reworked
engine, with the self-costs removed, actually beats the Vital Siphon line.

*4) Validate?* Scripted test comparing the reworked engine to the spam line.
- Baseline: script a Vital-Siphon-spam line and record its damage and win rate over a fixed number of turns.
- Mock the reworked pieces — no self-sleep on Contagious Slumber, and Night Terrors dealing big damage only against
  a sleeping target with no self-drain — then script Contagious Slumber into Night Terrors against the same target.
- Compare the two lines over the same span; expect the reworked engine to out-damage the spam once the self-costs
  are gone.
- Separate the regimes: the engine should win against mons that rely on resting or stamina, while Vital Siphon stays
  the pick against ones immune to Sleep, so each line keeps its niche.
- If the reworked engine still loses to the spam, Sleep isn't Xmon's best plan and we sharpen the annoyance; if it
  wins, the payoff line is real.

*5) What would change my mind.* If the reworked engine still loses to Vital Siphon, then Sleep isn't Xmon's best
plan and we should sharpen the annoyance instead of chasing a payoff. If it wins, the payoff line is real.

*6) Easy to test?* Yes, both lines are scriptable over a few turns.

*7) Simulated result.* I expect the reworked engine to beat Vital-Siphon-spam, because we've removed the self-costs
that were sinking it.

*8) Consistent with (1)?* Yes. The current engine is a dud, and the fix is a hypothesis to test.

**[Property] Make Sleep the thing Xmon warps around, and let Night Terrors detonate it.**

*1) Opinion.* Somniphobia should make resting or gaining stamina risk Sleep. Night Terrors should pay off big only
against a sleeping target. Contagious Slumber should drop its self-sleep cost.

*2) Property.* This supports meta and risk/reward. It turns "annoying" into a real behavioral lock with a payoff.

*3) Why.* If resting risks Sleep, the opponent's safety valve becomes a trap, and Xmon warps their decisions rather
than just chipping their HP. A Night Terrors that detonates Sleep gives Xmon a clear "if I land Sleep, here's how I
win" line, which it lacks today. Dropping the self-sleep removes the cost that made the setup net-negative.

*4) Better alternatives?* We could accept Xmon as a soft counter and just sharpen the annoyance without a payoff.

*5) Their tradeoffs.* That's safe but caps its ceiling at "tech pick." The payoff version is riskier but gives it a
real win condition, which is more interesting.

*6) Still hold it?* Yes, provided the step-4 test shows the reworked engine beats the spam. If it doesn't, fall back
to the soft-counter version.

*7) Amend.* Make its Sleep reliable or self-immune, so the archetype isn't a coinflip. Nudge Vital Siphon so it
isn't the auto-default.

*8) Empirical hook.*
- Run the engine-versus-spam script from step 4 as the single deciding result.
- If the engine wins, ship the payoff rework; if it loses, fall back to the soft-counter version.

*Summary:*
- **Contagious Slumber** — 0 / 2 / Cosmic / Other — remove the self-sleep, or make Xmon self-immune.
- **Night Terrors** — 0 / 0 / Cosmic / Special — big damage only against a sleeping target; remove the self-stamina
  drain.
- **Somniphobia** — 0 / 1 / Cosmic / Other — today it deals maxHp/8 × stack damage on any stamina gain, applied
  to both mons, so it fires on the global +1/turn regen and chips Xmon itself. Two fixes: make Xmon self-immune,
  and gate the trigger to active stamina gain (Rest or a stamina move) rather than the passive regen, so it
  punishes the opponent's recovery instead of being a passive damage lock.
- **Vital Siphon** — nudged so it isn't the auto-default.
- New moves: none.

> **[Predicted]** Somniphobia interacts with the global stamina regen, and that changes everything. Every mon
> gains 1 stamina per turn by default. If Somniphobia risks Sleep on any stamina gain, it threatens Sleep every
> single turn, not just when the opponent rests. That is a passive lock, not a soft counter, and it is much
> stronger than the section suggests. We need to decide whether it fires on the passive regen or only on active
> resting and stamina moves. That distinction is the whole balance of the move, and it is a clear Validation
> target.

> **[Addressed]** Confirmed from source, and worse than the section said in two ways. First, the mechanic is not
> a Sleep risk at all — Somniphobia's punisher hooks onUpdateMonState and, on any stamina gain with a positive
> delta, deals maxHp/8 × stack in damage. My draft's "risks Sleep" wording was wrong, and I'll fix it. Second,
> the punisher is applied to both mons, and the global StaminaRegen adds +1 stamina every turn, so it fires every
> round on the opponent and on Xmon itself. That self-hit is exactly why the sleep engine "self-harms." So the
> rework needs two fixes: make Xmon self-immune (only punish the opponent), and gate the trigger to active
> stamina gain above the passive +1 — a Rest or a stamina-restoring move — so it punishes the opponent's
> recovery choice rather than the ambient regen. That restores the intended "punish resting" tool instead of a
> passive every-turn damage lock. Validation: script an opponent that rests versus one that doesn't, and confirm
> the punisher bites only the rester and never Xmon.

---

## Ekineki — 55% (strong, pilot-robust)
Liquid sweeper with a comeback ability. The sim uses Bubble Bop, Sneak Attack, and Overflow, and never uses
Nine Nine Nine.

**[Thing] Nine Nine Nine is a dead setup move, because one crit is worth less than two hits.**

*1) Reason.* Nine Nine Nine sets a 90% crit rate for the next turn, but it's used 0.2% of the time. The crit isn't
worth the turn it costs. A crit in Stomp is only 1.5×, not 2×.

*2) Why I know it.* This is exact arithmetic. Nine Nine Nine spends a turn, then buys +50% on one hit. So the line
is: zero damage, then a 1.5× hit. Two normal attacks over the same two turns deal 2× a hit. And 1.5 is less than 2,
so the setup loses damage outright, before you even count the risk that the target switches.

*2.5) Why isn't what we have working.* This is mechanical, plus piloting. The math makes it a loss, and the pilot
also can't value a setup turn. Both point the same way: the move doesn't earn its slot.

*3) Uncertain?* Very low. The 1.5-versus-2 comparison is not close.

*4) Validate?* Static first, and it's decisive; a scripted check confirms it.
- Statically compare the two lines: one Nine Nine Nine setup then a 1.5× crit, versus two plain Overflows. 1.5 < 2,
  so the setup loses.
- Script both two-turn lines and confirm the damage totals match the arithmetic.
- Mock a reworked version — a guaranteed crit on Sneak Attack, or a burst scaling with KOs — and script it against
  the two-attack baseline.
- Separate the regime: the KO-scaling version should spike only late once Ekineki has KOs banked, so confirm it
  stays weak early; if it beats two attacks in its intended regime, it earns the slot, and if not, cut it.

*5) What would change my mind.* If Nine Nine Nine also did something on the setup turn, or if it made a whole team's
turn crit rather than one hit, the math could flip. As a single-target, single-turn crit setter, it can't.

*6) Easy to test?* Yes, and the static answer alone is enough.

*7) Simulated result.* I expect the setup line to lose to just attacking, matching the arithmetic.

*8) Consistent with (1)?* Yes. It's under-tuned, and it should be reworked or cut.

**[Property] Rework Nine Nine Nine into a payoff Ekineki uniquely wants.**

*1) Opinion.* Tie the crit to Ekineki's rule-breaking pieces. It should either guarantee a crit on Sneak Attack, its
hit-the-bench move, or become a burst that scales with the number of KOs.

*2) Property.* This supports synergy and flavor. It ties Ekineki's two weird moves together, and it suits a reserve
sweeper.

*3) Why.* Ekineki's ability rewards holding it in reserve and cashing in on KOs. A 999 that scales with KOs leans on
that identity, so the numbers-mon spikes late, which fits. Alternatively, a guaranteed crit on Sneak Attack makes a
bench-hitting move genuinely threatening, which is unique.

*4) Better alternatives?* We could just buff the global crit multiplier from 1.5× toward 2×.

*5) Their tradeoffs.* Changing the crit multiplier is a game-wide change for one move, and it makes every crit-setup
in the game stronger at once. The self-contained rework is far safer.

*6) Still hold it?* Yes, since Ekineki is already strong and doesn't want raw power.

*7) Amend.* Keep it a setup or a conditional burst, not a free nuke.

*8) Empirical hook.*
- Script the reworked 999 line and compare it to two attacks.
- Separately script the Sneak Attack combo, and confirm the new version actually pays in its intended regime.

*Summary:*
- **Nine Nine Nine** — 0 / 1 / Math / Self — rework the crit-setter into a burst that scales with KOs banked,
  leaning on Savior Complex. (The guaranteed-crit-on-Sneak-Attack alternative is dropped: a crit is only ×1.5,
  so it inherits the same 1.5 < 2 loss.)
- New moves: none.

> **[Predicted]** The guaranteed-crit-on-Sneak-Attack option has the same problem we just diagnosed. A crit is
> only 1.5×, so a guaranteed one is still just +50% on a single hit. That is the exact math that made Nine Nine
> Nine a loss. The KO-scaling burst is the option that actually pays. We should commit to it rather than leaving
> both on the table.

> **[Addressed]** Right, and I'm committing to the KO-scaling burst. A guaranteed crit on Sneak Attack is still
> only ×1.5 on one hit, which is the same 1.5 < 2 math that made the move a loss, just moved onto a bench-hit.
> The KO-scaling burst is the version that fixes the problem: it spikes as Ekineki banks KOs, which rewards its
> reserve-sweeper identity and its Savior Complex ability, so a strong Ekineki closing out a game gets a real
> payoff a two-attack line can't match. Drop the guaranteed-crit option. Validation: compare the burst against
> two normal attacks at 0, 1, and 2 KOs, and confirm it only wins once KOs are banked, so it stays a
> late-game payoff rather than an every-turn button.

---

## Nirvamma — 40% (unreliable; a setup mon the greedy pilot spams into 10% wins)
Math meditation and defillama mon. Already worked. Chronoffense is a fine 2HKO combo, and the gap is the
in-between turns.

**[Thing] Chronoffense is fine, and the in-between turns are the real gap.**

*1) Reason.* Nirvamma has nothing worthwhile to press between arming and firing Chronoffense. Chronoffense buffs on
the first press and 2HKOs on the second, which is a fine self-contained combo. The problem is the turns around it.

*2) Why I know it.* The greedy pilot spams Chronoffense to a 10% win rate, and the hard pilot barely uses it, so the
number is a pilot artifact. Its other slots are Scary Numbers, a plain Math damage move, and a narrow anti-rest
move. So nothing gives Nirvamma a reason to exist between the two Chronoffense presses. The question isn't whether
Chronoffense works — it's whether this arm-then-use-later pattern is fun when the in-between turns are empty.

*2.5) Why isn't what we have working.* The low number is piloting, but the in-between emptiness is design. Scary
Numbers is a fine baseline hit and not the villain. The real gap is that no slot rewards the wait.

*3) Uncertain?* Low on the design gap. The uncertain part is where a properly-piloted Nirvamma lands, which needs the
override to manage the setup.

*4) Validate?* Scripted test once Mean Reversion is mocked, plus a static boost check.
- Static: after a known opponent boost, compute what stripping it returns the target's damage to; removing a +50%
  boost drops the target's damage back to its unboosted value, exact from the formula.
- Mock Mean Reversion as a no-damage strip that also gives Nirvamma half the stripped magnitude, then script it
  against a boosted target.
- Confirm the opponent's post-strip damage matches the unboosted number, and Nirvamma's own boost rises by half.
- Separate the regime: against a non-booster the move should do little, so check it isn't a dead turn there and that
  its job is specifically punishing setup.
- With the override piloting the Chronoffense setup, re-run and see whether the in-between turn now does real work;
  if a filled-in Nirvamma lands mid-pack, the fix worked, and if it stays low the problem is deeper.

*5) What would change my mind.* If a filled-in Nirvamma lands mid-pack, the design fix worked. If it stays low even
when piloted, the problem is deeper than the in-between turns.

*6) Easy to test?* Only after the override can manage the setup. Until then, no arena number here means anything.

*7) Simulated result.* I expect mid-pack when piloted, so the fix is about the in-between, not about power.

*8) Consistent with (1)?* Yes. Chronoffense is fine, and the gap is the surrounding turns.

**[Property] Add Mean Reversion as a no-damage boost-theft to fill the in-between turn.**

*1) Opinion.* Add a move that removes all of the opponent's stat boosts and gives Nirvamma half of the stripped
magnitude as its own boost. It deals no direct damage, so it isn't a third Math damage move.

*2) Property.* This supports risk/reward, meta, and flavor. It's an anti-setup tool, and reversion to the mean fits
the defillama theme.

*3) Why.* You asked how this differs from Scary Numbers, which is already a baseline Math damage move. The answer is
that Mean Reversion doesn't translate into direct damage at all. It cares about interacting with stat boosts: it
strips the opponent's and hands Nirvamma half of them. That gives the in-between turn a real job and does something
no other mon does, which is remove boosts. Setup is close to risk-free right now, so a move that punishes and undoes
it adds the missing risk.

*4) Better alternatives?* We considered a damage-plus-strip version, Compound Interest, and an execute.

*5) Their tradeoffs.* A damage-plus-strip version just becomes a third Math damage move next to Scary Numbers and
Chronoffense, which is the redundancy you flagged. Compound Interest duplicates Chronoffense's invest-then-pay role.
The execute is win-more, strong only when you're already ahead. The no-damage boost-theft is the one that fills the
gap and does something unique.

*6) Still hold it?* Yes.

*7) Amend.* Keep it no-damage, and make the half-steal fraction the tunable knob if it's too strong.

*8) Empirical hook.*
- Static: confirm the strip returns a boosted target's damage to its unboosted value.
- Script it against a boosted target and confirm Nirvamma gains half the stripped magnitude.
- Re-run in the arena once the override pilots the setup.

*Summary:*
- **Mean Reversion (new)** — 0 / 2 / Math / Other / — / 0, no damage — removes all of the opponent's stat boosts,
  and Nirvamma gains half of the stripped magnitude as its own boost. Replaces Hard Reset. The half-steal fraction
  is the tunable knob if it's too strong.
- **Chronoffense** — unchanged; it stays a fine 2HKO combo.
- New moves: Mean Reversion (one).

> **[Predicted]** With no damage, Mean Reversion is a fully dead turn against a mon that has not boosted. We have
> been avoiding fully dead turns everywhere else — Chill Out gets a floor, Double or Nothing still deals 30, Zap
> has value. Is Mean Reversion an accepted exception because it is a pure counter to setup, or does it need a
> small floor too? We should decide that on purpose. There is also a mechanics question. Boosts are
> multiplicative per source, so what does "keep half of the stripped magnitude" actually compute to? We should
> define that before we validate.

> **[Addressed]** The mechanics are implementable. Stripping all boosts is a single existing call —
> clearAllStatBoosts on the opponent. For "keep half," the clean per-stat definition is: read the opponent's net
> boost on each stat, which the engine exposes as the boosted-minus-base delta, halve that fraction, and apply
> it to Nirvamma as a new boost. For example, an opponent at +50% Attack has Nirvamma gain +25% Attack. That's
> concrete and uses only existing primitives. On the dead turn: confirmed, with no damage and nothing to strip,
> Mean Reversion does nothing against a mon that hasn't set up. I'd accept that as the one deliberate exception
> in the doc. Mean Reversion is an explicit anti-setup tech piece, like a Taunt or a Haze, and a floor would
> make it a safe every-turn pick that blunts the punish-setup identity. So unlike Chill Out, Double or Nothing,
> and Zap, which all keep a floor, Mean Reversion is dead against a non-booster on purpose — flagged clearly so
> it's a choice, not an oversight.

---

# Executive summary

One entry per mon. Where a move is changed or added, the full metadata is given as
Name — Power / Stamina / Type / Class / Accuracy / Priority — effect. Current numbers are cited where a move is
only partly changed, so the delta is clear. Every change also carries a validation plan in its section above,
written as a structured list of steps.

> **[Predicted]** These changes are not all the same size, and the summary reads as if they are. Several are
> simple move-number swaps, but several others are engine changes rather than move mockups — the Bull Trap
> move filter, the new Volthare speed status, the Inutia shield and its once-per-game flag, and the Somniphobia
> trigger. Many are also gated on override scripts that do not exist yet. We should separate the cheap swaps
> from the heavier engine work and give a build order, so the validated and arithmetic-certain changes ship
> first.

> **[Addressed]** Categorized, and the reassuring finding is that none of these needs a change to core
> Engine.sol — they all reuse existing hooks and primitives.
> - Pure number swaps (params/JSON): Round Trip 30→50, Pistol Squat stamina, Rock Pull whiff power.
> - New move-logic contracts (no engine change): Gachachacha rework, Double or Nothing, Q5, Chill Out rider,
>   Nine Nine Nine, Foul Language, plus the two that lean on existing primitives — Bull Trap (reuses setMove,
>   the Sleep precedent) and Mean Reversion (reuses clearAllStatBoosts + addStatBoost).
> - New effect contract + wiring: the Volthare Speed-drop status.
> - Ability/effect logic changes: Gorillax Angery, Embursa Tinderclaws degree-scaling, Xmon Somniphobia
>   self-immunity and trigger gate, Inutia Blessed shield + its once-per-game globalKV flag, Iblivion
>   Baselight/Loop economy.
> - Pilot/override scripts only (no contract change): Ghouliath last-resort, Iblivion and Nirvamma setup
>   piloting (Aurox's tank line is already done).
> Build order: ship the arithmetic-certain swaps first (Round Trip, Pistol Squat, Rock Pull whiff, Nine Nine
> Nine, Gachachacha), then the new moves that reuse primitives (Bull Trap, Mean Reversion, Double or Nothing,
> Q5), then the override scripts, which unblock every resource and setup validation, then the trickier
> ability/economy changes (Angery, Tinderclaws scaling, Baselight) that most need sim tuning.

**Ghouliath — leave the moves, fix the pilot.** It's in band, and Eternal Grudge is unpiloted rather than weak.
No move change. Action item: a CPU pilot that fires Eternal Grudge as a last resort (Ghouliath about to be KO'd,
or out of good options), so the move can be measured at all. Design note: its real reward lives in a team partner
that punishes the forced switch.

**Inutia — one changed piece, and it's gated.**
- **Sanctify** — 0 / 2 / Faith / Other / 100 / 0 — targets a friendly mon and grants **Blessed**, reworked into a
  shield that blocks the next incoming hit; limited to once per mon per game.
- **Initialize** — 0 / 2 / Faith / Self / — / 0 — unchanged: +50% ATK and SpATK that transfers on switch-out. Cap
  the transfer to about +30% only if the snowball CPU test shows it's oppressive.
- **Chain Expansion** — unchanged; a mild switch-in hazard-heal, kept mild so it doesn't tax switching.

**Malalien — leave it, on the watch-list.** Coverage is confirmed total (a neutral-or-better hit on all twelve
others, super-effective on five), so it's a safe pick but not broadly dominant. No change now. Tax the coverage
only if it stays the default pick after the other reworks land.

**Iblivion — a resource rework with no new move, gated on an override that manages Baselight.**
- **Baselight (ability)** — earn a point when Iblivion lands a base, non-empowered attack. Base Unbounded Strike
  (80 power, 2 stamina) doesn't consume a stack, so it charges; empowered modes and Loop spend. That resolves the
  earn-into-a-consume conflict.
- **Loop** — 0 / 1 / Yang / Self — same stat gains, but the boost now lasts only 2 turns, so it's a readable window
  the opponent can wait out or punish.
- **Unbounded Strike / Brightback** — raise their empowered modes to pay back the Loop nerf, so net power stays flat.

**Gorillax — two existing-move changes.**
- **Rock Pull** — ? / 3 / Earth / Physical — on a wrong read, deal reduced normal damage to the opponent (about 40
  base) instead of 30 self-damage; the correct-read 80-base hit and its +priority stay.
- **Angery (ability)** — each hit taken builds a stack; at three stacks Gorillax's next attack gains priority (the
  slowest mon strikes first) and ignores the target's defensive stat boosts, then the stacks reset and it heals as
  now. Keep a small per-stack Attack bump. Priority-on-a-brick is the interesting part, not a bigger number.

**Sofabbi — fix the bias, soften the tails, add a wager.**
- **Gachachacha** — ? / 3 / Cyber / Physical — replace the auto-KO bands with heavy self-recoil and a big fixed hit,
  and correct the self-unfavorable bias so it matches the intended 5%/5%. (Validated: the current rate is `rng % 210`
  → ~2.4% self / 1.9% opponent, not the 10% first assumed.)
- **Double or Nothing (new)** — 120 or 30 / 2 / Nature / Physical / 100 / 0 — a coin flip. Heads deals 120, tails
  deals 30. Pay 1 or 2 extra stamina to raise the heads chance to 65% or 80%. A lost flip still deals 30, so it's
  never a dead turn. Replaces Guest Feature or Unexpected Carrot, whichever tests weaker.

**Pengym — two contingent existing-move changes.**
- **Chill Out** — 0 / 0 / Ice / Other — keeps its Frostbite; add a rider so it isn't dead into physical attackers,
  dealing light chip plus a speed drop. Contingent on the field mix being physical enough to matter.
- **Pistol Squat** — 80 / 2 → 3 / Metal / Physical / 100 / −1 — a small stamina tax, only if it still dominates
  after the Chill Out fix.

**Embursa — scale the boost, hand the player the burn dial, fix Q5.**
- **Tinderclaws (ability)** — scale the SpATK boost with the burn degree, and give the player control of the burn
  through **Heat Beacon** (a deliberate self-burn that raises the degree). Keep the Rest-heal as the pressure valve,
  since removing it goes suicidal at high degree.
- **Q5** — 130 / 2 / Fire / Special — reworked from the five-turn delay to: deal 130 now, burn the enemy, and raise
  Embursa's own burn degree by one. Replaces the delayed Q5.
- **Honey Bribe** — unchanged; its SpDef cut is real setup for Embursa's special attacks.

**Volthare — a status rework with no new move.**
- **Zap (status)** — keep it as a stun that skips the target's next turn. If it's too swingy, lower its proc rate or
  shorten it rather than replacing the mechanic.
- **New Speed-drop status** — any value-debuff lives here, lowering Speed, which is easier to tune than priority
  across every move — not folded into Zap.
- **Electrocute / Dual Shock** — re-tuned around the kept Zap, so Dual Shock's self-Zap is a real cost, not a
  self-skip.
- **Round Trip** — 30 → 50 / 1 / Lightning / Special — a small power bump so the pivot is worth clicking.

**Aurox — one new move (validated).**
- **Bull Trap (new)** — 0 / 2 / Metal / Other / 100 / 0 — for two turns the opponent's active mon can only select
  damaging moves; a switch escapes it. Replaces Volatile Punch.

**Xmon — a sleep-engine rework with no new move, gated on the engine beating Vital-Siphon-spam.**
- **Contagious Slumber** — 0 / 2 / Cosmic / Other — remove the self-sleep, or make Xmon self-immune.
- **Night Terrors** — 0 / 0 / Cosmic / Special — big damage only against a sleeping target; remove the self-stamina
  drain.
- **Somniphobia** — 0 / 1 / Cosmic / Other — while it's up, resting or gaining stamina risks Sleep.
- **Vital Siphon** — nudged so it isn't the auto-default.

**Ekineki — one existing-move change (validated: one crit loses to two hits).**
- **Nine Nine Nine** — 0 / 1 / Math / Self — rework the crit-setter: either guarantee a crit on Sneak Attack, or
  make it a burst that scales with KOs, leaning on Savior Complex.

**Nirvamma — one new move.**
- **Mean Reversion (new)** — 0 / 2 / Math / Other / — / 0, no damage — removes all of the opponent's stat boosts,
  and Nirvamma gains half of the stripped magnitude as its own boost. A boost-theft utility that punishes setup
  without being a third Math damage move alongside Scary Numbers and Chronoffense. Replaces Hard Reset. The
  half-steal fraction is the tunable knob if it's too strong.
