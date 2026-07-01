# Stomp design pass

Per mon we screen the win rate first. Roughly 45–55% is fine, and clean counters are fine. The goal is
not to hit a target win rate. The goal is move quality: find moves that are never used or superseded, and
rework them so they are situationally useful, synergistic, and flavorful. Cap is two new moves per mon.

Claims use two templates.
**[Thing]** 1) reason 2) why I know it 2.5) why isn't what we have working 3) uncertain? 4) validate
5) what would change my mind 6) easy to test? 7) simulated result 8) consistent with (1)?
**[Property]** 1) opinion 2) which property 3) why 4) better alternatives 5) their tradeoffs 6) still hold?
7) amend 8) empirical hook.

Validation is a real experiment: a static data check or scripted test, the exact change, the expected
delta, and how the call updates in both directions. Damage scales as basePower × attack ÷ defense, with a
type multiplier and a 1.5× crit — so relative claims (halving a stat halves the damage) are exact without
the scaling constant. Win rates are the munch arena runs (hard/greedy avg); for setup and combo mons those
numbers are pilot artifacts and are flagged as such.

---

## Second-pass review

After writing the whole roster, four patterns stand out, and two of them are self-criticism.

**Half the numbers are pilot artifacts.** Ghouliath, Inutia, Malalien, Iblivion, Nirvamma, and Aurox all
have a low score or a dead move that traces to the pilot, not the design. The pilot won't self-KO, won't
manage a resource, and won't complete a setup. So the arena under-rates every plan-based mon at once. The
real arbiter for these is a scripted line or an override-CPU, not the raw win rate. Read each setup or
resource mon's number as a floor, not a verdict.

**"Switch to shed it" is the recurring counterplay, and it cuts two ways.** Eternal Grudge's halve, Frostbite,
Bull Trap, and Sleep can all be dodged by switching the affected mon out. That is healthy, because it is the
switching-as-counterplay we want to encourage. But it also caps how much any debuff-based fix can achieve.
And it exposes a mistake in my own doc, which I flag inline at Ghouliath: "make the halve stick through a
switch" fights the encourage-switching value directly.

**Statuses carry standalone utility I have to count every time.** The Pengym lesson generalizes. Frostbite
halves Special Attack, Burn halves Attack, and both chip. Honey Bribe halves the opponent's Special Defense,
and Vital Siphon steals stamina. I applied this to Pengym but under-applied it elsewhere, most clearly at
Embursa, where I judged the kit without crediting Honey Bribe's SpDef cut. Any status-applier needs its
status priced separately from its headline effect.

**Restraint: the doc proposes too much churn.** Several mons get two or three move changes, and that risks
over-tuning a roster that is mostly in band. Malalien and Ghouliath are basically fine and should get minimal
or no change. Some dead matchups are the intended weakness, so not every floor needs raising. The safe order
is to ship the validated and arithmetic-certain changes first, and treat the rest as hypotheses.

**Confidence ranking.** Highest confidence and lowest risk: Aurox's Bull Trap (validated), Ekineki's Nine
Nine Nine (exact arithmetic), and Gorillax's Rock Pull whiff (clear mechanical fix). Middle: the status and
resource reworks (Sofabbi, Volthare, Iblivion, Nirvamma), which are sound but want a scripted check. Lowest
confidence: the two new mons, which are speculative and need real prototyping, and Embursa's burn-fuel, which
rides on an untested premise.

---

## Ghouliath — 51% (in band)
Yin/Fire suicide lead. It cripples with status, then cashes out with Eternal Grudge at +1 priority. The sim
shows it mostly spams Infernal Flame, and Eternal Grudge sits near 1% usage.

**[Thing] Eternal Grudge is unused mostly because the pilot can't value a self-KO, not because it's weak.**

*1) Reason.* Eternal Grudge looks dead, but its payoff is bigger than the usage suggests. It halves both the
opponent's Attack and their Special Attack. That debuff holds until the crippled mon switches out. And the
move has +1 priority, so you can often fire it twice in a game.

*2) Why I know it.* The move reads as: KO self, halve the target's ATK and SpATK. Halving both offenses is a
large, matchup-agnostic cut. A physical attacker and a special attacker are both neutered by it. So the value
is real, even though the mon pays its own life for it. The 1% usage comes from the pilot, which never spends a
whole mon on a delayed payoff it can't score.

> The CPU pilot should likely aim to use this move when there are no other options or Ghouliath is likely to be KOed on this turn, as a last resort.

*2.5) Why isn't what we have working.* The problem is piloting, not the payoff. A greedy or 1-ply pilot will
never choose to KO its own mon, so the cripple-then-grudge plan never appears in the data. The rest of the kit
supports that plan and is also underused. Wither Away drains stamina from both sides via Panic, and Grave
Affliction costs both mons half their HP if the target is already statused. Those are all setup pieces the
sim skips.

*3) Uncertain?* The strength of the halve is not uncertain. What is uncertain is whether the opponent simply
switches out to shed it. If they pivot the crippled mon away, the debuff leaves with them. So the real
question is how sticky the value is, not how large it is.

> Even if the opponent switches out, this is tactically useful, especially if the rest of our team has something to synergize with this, or something to take advantage of this.

*4) Validate?* Start statically. Take any attacker's damage against Ghouliath's teammate, then halve the
attacker's ATK or SpATK and recompute. The formula makes this an exact 50% cut on that mon's hits. Then run
test code. Script Eternal Grudge, then have the opponent attack, and read the damage before and after. Run it
once where the opponent stays in and once where they switch. We change nothing in the engine, since Eternal
Grudge already applies the halve.

> I don't think we can just look at halved attack stats and make a decision. Rather, it forks into:
- either the opponent switches
- or they stay in
And we have to create a CPU pilot that runs Eternal Grudge in the first place, so we can analyze it.

*5) What would change my mind.* If the opponent almost always switches the crippled mon out, the debuff is
easy to dodge, and Eternal Grudge is a worse trade than it looks. If they tend to stay in, the halve pays and
the move is fine.

*6) Easy to test?* The static half is trivial and mostly already answered by the formula. The "do they switch"
half needs a fuller game, so it leans on the arena.

*7) Simulated result.* I expect the halve to be strong against a mon that stays, and near-worthless against a
mon that pivots. So Eternal Grudge is a good move that the current pilot can't use and a smart opponent can
partly dodge.

*8) Consistent with (1)?* Yes. The claim holds: it is unpiloted, not weak, with a real "they can switch" hole.

**[Property] Make the halve survive one switch so it can't be dodged for free.**

*1) Opinion.* The debuff should follow the opponent for a turn or persist as a team-wide shave, so a single
pivot doesn't erase Ghouliath's whole sacrifice. This keeps the suicide-lead fantasy intact. It also makes the
+1 priority double-grudge threat meaningful.

*2) Property.* This supports risk/reward. Right now the reward for a huge cost is easy to sidestep, which makes
the cost feel unfair.

*3) Why.* Ghouliath pays its life for the grudge, so the payoff should be hard to refund. If the halve stuck for
one switch, the opponent has to eat a turn of weakened offense before they escape. That turns a dodge into a
tempo cost, which is fair.

*4) Better alternatives?* We could instead leave it alone and treat the switch as intended counterplay. Or we
could buff the raw size of the halve.

*5) Their tradeoffs.* Leaving it means the signature move stays easy to dodge, which is a feels-bad on a mon
built around it. Buffing the size doesn't fix the dodge, it just makes the un-dodged case swingier.

*6) Still hold it?* Tentatively. Persistent debuffs can be oppressive, so I hold this only if the "they always
switch" test comes back true.

*7) Amend.* Keep it to one switch, not permanent, so it taxes the escape without locking a mon out of the game.

*8) Empirical hook.* Run the step-4 test and measure how often the opponent switches to shed the halve. If they
switch most of the time, the sticky version is worth it. If they usually stay, leave the move alone.

*Summary:* Existing changed — **Eternal Grudge** halve survives one opponent switch (contingent on the switch-rate
test). New moves: none.

> **2nd pass:** I'd drop this fix. Making the halve survive a switch punishes switching, which we explicitly want
> to encourage — it contradicts a core value. Accept the switch as intended counterplay instead. Also verify first
> whether the halve is a Temp boost that already drops when the killer switches out; if it is, "make it stick"
> means making it permanent, which is a much bigger call than it looks. Net: Ghouliath is probably a leave-it,
> not a change.

---

## Inutia — 42% (unreliable; a support-pivot the greedy pilot can't drive)
Faith utility with weak damage. The sim plays it as a mono-Big-Bite mon and ignores its whole toolkit.

**[Thing] Inutia's utility is unpiloted, and the buff-pass is the part most likely to be strong.**

*1) Reason.* Inutia plays as one damage button because the pilot can't sequence its utility. Big Bite is used
56% of the time. Initialize, Chain Expansion, and Hit and Dip are each used under 7%.

*2) Why I know it.* Initialize gives +50% ATK and SpATK, and it transfers to the incoming mon when Inutia
switches out. That is a baton pass in all but name. A greedy pilot just casts it on Inutia and never completes
the handoff, so its usage looks like noise. The transfer is the strong part, and it never happens in the data.

*2.5) Why isn't what we have working.* The failure is piloting, but it hides a real balance risk. A passed +50%
can let a frail nuker sweep, which is the classic degenerate baton-pass pattern. So the danger here is not that
the kit is weak. The danger is that it snowballs once a pilot actually plays it.

*3) Uncertain?* I don't know how strong the completed pass is. It could be fair, or it could be oppressive with
the right partner. That is the load-bearing unknown for this mon.

> Correct, we have to run some CPU tests using the stat buff and other moves to better understand how useful they are.

*4) Validate?* This one needs test code, not a static check, because the payoff is a multi-turn line. Script
Initialize, then Hit and Dip into a frail attacker, then that attacker's hit. Read the damage with and without
the passed boost. We change nothing, since the transfer already exists. The snowball question also needs a full
game, so it wants an arena run we don't have yet.

*5) What would change my mind.* If the passed boost turns a 2-hit-KO into a 1-hit-KO on common targets, the pass
is too strong and needs a cap. If it barely changes the math, the pass is fine and Inutia is just underpiloted.

*6) Easy to test?* The single-handoff damage is easy to script. The "does it snowball across a game" question is
harder and is the one place this mon may need the arena.

*7) Simulated result.* I expect the pass to be strong, and possibly too strong if uncapped. So the design should
throttle it before we lean on it.

*8) Consistent with (1)?* Yes, with a caveat. It is unpiloted, and its real problem is a snowball risk, not weakness.

**[Property] Build Inutia into a throttled, tempo-positive buff-passer.**

*1) Opinion.* Keep the transfer as the identity, sized so it's strong but not degenerate. Turn Chain Expansion
from a passive hazard into a fast, predicted switch-punish. Together these give Inutia a real job: enable a
partner, and tax the opponent's response.

*2) Property.* This supports meta and risk/reward. It makes Inutia a team-building piece rather than a filler
attacker, and it avoids a stally heal.

*3) Why.* Inutia is fast, so it can pass a boost and pivot in one motion, the way Hit and Dip already does. That
is tempo-positive support, not turtling. The active Chain Expansion then punishes the switch the opponent wants
to make to dodge the setup.

*4) Better alternatives?* We could instead make Inutia a dedicated cleric by fixing Blessed into a real shield.
Or we could just buff Big Bite and accept a plain attacker.

> I think a one-hit shield is interesting as long as we find ways to prevent it from being spammed (e.g. once per game, or some other drawback)

*5) Their tradeoffs.* A cleric drags games toward stall and leans on Blessed, which barely does anything today.
Buffing Big Bite throws away the whole unique kit for a generic mon.

*6) Still hold it?* Yes, but gated on the snowball test. If the pass is oppressive, the cap has to come first.

*7) Amend.* Keep the pass soft: one stat line, survivable pivot, small on-swap debuffs. Don't stack it into an
omniboost.

*8) Empirical hook.* Run the step-4 handoff test for size, then an arena game for snowball. If the pass tips
into no-counterplay wins, cap it further before shipping.

*Summary:* Existing changed — **Initialize** capped; **Chain Expansion** becomes a fast predicted switch-punish, not
a passive hazard. New moves: none.

> The summary here is not clear enough. What does Chain Expansion actually change to? Remember we need the full metadata for moves when summarizing.

---

## Malalien — 49% (skill-gated: 55% hard, 43% greedy)
Cyber glass cannon. It 2HKOs most of the roster with coverage plus a self-buff. The sim shows Triple Think
barely used and Foul Language as the odd slot.

**[Thing] Malalien is not broadly dominant. Its strength is skill-gated.**

*1) Reason.* The aggregate says Malalien is in band, not oppressive. It only looks scary under a strong pilot.
Its 12-point gap between hard and greedy is the tell.

*2) Why I know it.* Under greedy it drops to 43%, because a greedy pilot feeds a frail mon into its own death.
Under hard it climbs to 55%, because a planner sets up Triple Think and sweeps. Triple Think is used about 1%
of the time, so the "very strong" read comes from a setup the average pilot never performs.

*2.5) Why isn't what we have working.* Nothing is broken here. The kit works when piloted, and the low-pilot
number is the artifact. The only real question is whether its all-types coverage is too forgiving.

*3) Uncertain?* Low uncertainty on the power. Some uncertainty on whether the coverage makes it too safe to
pick, which only matters once the rest of the roster shifts.

*4) Validate?* Static check first. Malalien has three special moves spanning Cyber, Math, and Cosmic, so it
almost always has a neutral-or-better hit. Count, from the type chart, how many of the 13 mons it lacks a
super-effective or neutral option against. If the answer is near zero, its coverage is total. Test code isn't
needed for this; it's a chart lookup.

*5) What would change my mind.* If, after other reworks land, Malalien is still the default best pick at over
55%, then the coverage is too safe and should be taxed. If it settles in band, leave it.

*6) Easy to test?* Yes, the coverage count is a static lookup. The "still dominant later" part is an arena recheck.

*7) Simulated result.* I expect near-total coverage, which is exactly why it feels safe to bring. That is a
watch-list item, not a bug.

*8) Consistent with (1)?* Yes. It is a fine, skill-gated glass cannon, not a problem mon.

*Summary:* Existing changed — none. New moves — none. Watch-list: recheck field win rate after other reworks; tax
coverage only if it stays the default pick.

---

## Iblivion — 43% (unreliable; the most piloting-sensitive mon)
Yang/Air resource mon. Baselight gives a free point every turn. The sim shows hard ignoring Loop at 4% and
greedy spamming it at 83% for 8% wins.

**[Thing] Baselight is a timer feeding one button, not a resource.**

*1) Reason.* There is no decision in earning Baselight, and there is one dominant thing to spend it on. A point
arrives every turn no matter what you do. Loop is the only sink that matters.

*2) Why I know it.* Loop sets all stats to +15, +30, or +40% based on Baselight level, which is a huge one-button
swing. The greedy pilot sees that stat gain and mainlines Loop, but wins only 8% of the time doing so. The hard
pilot barely touches it. Neither number tells us anything about a well-managed Iblivion.

*2.5) Why isn't what we have working.* Two things fail at once. Generation is free, so there's no risk in earning
the resource. And spending collapses to Loop, so there's no hold-versus-spend choice. The empowered attacks exist
but never compete, because Loop is simply better.

*3) Uncertain?* I don't know where a properly-piloted Iblivion lands. My guess is mid-pack, but the sim can't show
it, because no pilot manages Baselight well.

*4) Validate?* Test code, since this is a multi-turn resource line. Script "Loop once early, then empowered
Unbounded Strike," and compare it to Loop-spam over the same turns. Read the win margin or the damage total.
This needs the override to pilot the plan, which is the change: add an Iblivion script, not an engine edit. We
can also statically confirm Loop's raw value by summing the stat gains it grants.

*5) What would change my mind.* If managed Iblivion lands near 50%, its low score was piloting, and the design
work is about making the resource interesting, not about power. If it stays low even when managed, then the kit
is genuinely weak and needs more than a resource rework.

*6) Easy to test?* The scripted comparison is easy once the override runs it. The number is only trustworthy with
a competent pilot, which is the gating requirement.

*7) Simulated result.* I expect roughly 50% when managed. So the real problem is a boring resource, not a weak mon.

*8) Consistent with (1)?* Yes on the design claim. Baselight is dull even though the mon isn't weak.

**[Property] Earn Baselight by dealing damage, give it real sinks, and make Loop readable.**

*1) Opinion.* Gate Baselight on landing hits instead of on the clock. Make empowered Unbounded Strike and
Brightback real alternatives to Loop. And rein Loop into a committal play the opponent can punish.

*2) Property.* This supports fun through decision density, plus risk/reward.

*3) Why.* A resource you earn for free is a timer, and a timer is not interesting. A resource you earn by pressing
the attack rewards a fast attacker for doing its job. Competing sinks then create the hold-versus-spend choice
that a resource mon is supposed to have.

*4) Better alternatives?* We could just nerf Loop and touch nothing else.

*5) Their tradeoffs.* Nerfing Loop alone tanks a mediocre mon and gives nothing back. It also leaves the resource
just as boring, only weaker.

*6) Still hold it?* Yes. The package fixes the design problem while keeping net power flat.

*7) Amend.* Pay the Loop nerf back with a higher empowered ceiling, so overall strength stays put and only the
shape changes.

*8) Empirical hook.* This is blocked on the override managing Baselight. Until a pilot can do that, no arena number
here means anything.

*Summary:* Existing changed — **Baselight** (earn on damage), **Loop** (readable commitment), **Unbounded Strike / Brightback**
(stronger empowered modes). New moves: none.

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

*4) Validate?* Static first: compare the wrong-read self-damage to just clicking a normal attack that turn. If
self-damage plus zero offense is worse than a plain 95-power Pound Ground, the read is dominated. Then test code:
script Rock Pull against a switching opponent and a staying one, and read both outcomes. The change is the fix
itself: swap the self-damage for a weak hit, then re-check the wrong-read line is now merely mediocre.

*5) What would change my mind.* If the correct-read payoff is so large that the rare hit justifies the frequent
self-damage, then it's a high-variance tool, not a dead one. My read is that it isn't, but the numbers settle it.

*6) Easy to test?* Yes, both halves are cheap and scriptable.

*7) Simulated result.* With the whiff softened to a weak hit, Rock Pull becomes a low-risk read people will
actually make.

*8) Consistent with (1)?* Yes. It's dead because the downside is punishing, and softening it fixes that.

**[Property] Soften the whiff, and give Angery a rage payoff so the ability matters.**

*1) Opinion.* A wrong Rock Pull should deal reduced normal damage, not hurt Gorillax. And at three Angery stacks,
Gorillax's next hit should ignore defensive stat boosts, on top of the existing heal.

*2) Property.* This supports risk/reward and synergy. The read becomes clickable, and the slow body finally has a
reason to soak hits.

*3) Why.* Gorillax is slow, so it eats hits going second, which charges Angery on its own. An armor-piercing hit at
three stacks makes it a specific answer to bulky setup mons, rather than a generic big hitter. That is a niche, not
just more damage.

*4) Better alternatives?* We could instead make the three-stack payoff a free, empowered nuke.

*5) Their tradeoffs.* A free empowered nuke risks overtuning a mon that's already at 54%, and it overlaps Aurox's
take-a-hit ramp. Armor-piercing is a narrower, safer payoff aimed at walls.

*6) Still hold it?* Yes, since Gorillax is strong and we don't want to add raw power.

*7) Amend.* Keep a small per-stack Attack bump too, so early Angery stacks aren't wasted before you reach three.

*8) Empirical hook.* Run the step-4 static compare to confirm the softened Rock Pull is "mediocre, not punishing,"
and script a stacked-Angery hit into a boosted wall to confirm the pierce lands.

*Summary:* Existing changed — **Rock Pull** (whiff → weak hit), **Angery** (three stacks → armor-piercing hit plus the heal,
small per-stack Attack). New moves: none.

---

## Sofabbi — 51% (in band; incoherent gambling theme)
Nature gambler with high bulk. Only Gachachacha actually gambles, and the greedy pilot spams Snack Break.

**[Thing] Gachachacha's auto-KO tails are no-counterplay swings.**

*1) Reason.* Gachachacha can delete a mon on a dice roll. It has a 5% chance to KO Sofabbi and a 5% chance to KO
the opponent outright. Neither outcome involves a decision.

*2) Why I know it.* The move rolls uniform power from 0 to 200, with those two 5% KO bands on top. So one in
twenty casts ends a mon regardless of HP or play. That is the worst kind of variance, because it can decide a game
with no read on either side.

*2.5) Why isn't what we have working.* This is a design problem, not a piloting one. The gamble has no agency: you
click it and pray. And the rest of the kit doesn't share the gambling theme, so the identity is only half there.

*3) Uncertain?* Low on the tails being feel-bad. The softer question is how often they actually swing a game, which
is a frequency, not a mystery.

*4) Validate?* This is a static probability check plus a quick test. Statically, the auto-KO rate is 10% per cast,
split evenly. To ground the swing, run test code: cast Gachachacha across many seeds and count how often each KO
band fires. We change nothing to measure the current move. If we soften the tails, the change is to replace the
KO bands with heavy recoil and a big fixed hit, then re-run the count to confirm no more instant kills.

*5) What would change my mind.* If the KO tails almost never fire in practice, they're a rare flavor moment rather
than a problem. But at a flat 10% per cast, they will fire often enough to matter.

*6) Easy to test?* Yes. The probability is exact, and the seed sweep is cheap.

*7) Simulated result.* I expect the tails to fire about one cast in ten, which is far too often for a no-counterplay
kill.

*8) Consistent with (1)?* Yes. The tails are frequent, uninteractive swings.

**[Property] Turn the gamble into a decision, using stamina as chips.**

*1) Opinion.* Soften the tails so no cast is an instant kill. Then add a wager move where you spend stamina, fed
by Carrot Harvest, to skew the odds in your favor.

*2) Property.* This supports fun through real risk/reward, and it ties the kit together through synergy.

*3) Why.* Sofabbi is bulky and stamina-rich, because Carrot Harvest regenerates stamina half the time. So stamina
is the natural currency for a gambler. Paying chips to improve a bet turns raw variance into a press-your-luck
choice, which is what makes gambling fun.

*4) Better alternatives?* We could instead make every move random.

*5) Their tradeoffs.* Four independent dice is noise, not a plan, and it gives the opponent nothing to read. One
wild spin plus one controllable bet is a cleaner identity and an actual decision.

*6) Still hold it?* Yes. It fixes the feel-bad and the incoherence at once.

*7) Amend.* Make a losing bet still deal chip, so a wager is never a fully dead turn. Keep Snack Break and Guest
Feature as the sustain that buys more spins.

*8) Empirical hook.* Re-run the seed sweep after softening the tails to confirm no instant kills, and script a lost
wager to confirm it still chips.

*Summary:* Existing changed — **Gachachacha** (softened tails). New move — a **wager** attack (spend stamina to skew a
high-variance hit; a loss still chips). Replaces Guest Feature or Unexpected Carrot, whichever tests weaker.

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

*4) Validate?* Start statically. The damage formula scales with attack over defense, and Frostbite halves Special
Attack, so a special attacker's next hit should land at about half its normal value. That is exact from the
formula. Then run test code: script Chill Out on turn one, the opponent's attack on turn two, and read Pengym's HP
loss, once versus a special attacker and once versus a physical one. We don't change any code, because Chill Out
already applies Frostbite.

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

*8) Empirical hook.* Statically, count the roster's physical versus special attackers from their attack and
specialAttack stats. If special attackers dominate, Chill Out is rarely dead and the fix isn't worth it. Then, in
test code, mock the reworked Chill Out and script it into a physical matchup to confirm it now does non-zero work.

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

*4) Validate?* Test code. Script Pistol Squat against a plain 80-power hit with no switch, and measure the
win-margin difference that comes purely from the forced switch. We change nothing, since both moves exist. The
delta is the value of the disruption.

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

*8) Empirical hook.* After the Chill Out change, re-run move-usage. If Pistol Squat is still above 35% and the combo
is below 10%, it needs the tax.

*Summary:* Existing changed — **Chill Out** (optional physical-matchup rider, contingent on field mix), **Pistol Squat**
(small tax, contingent on it still dominating). New moves: none.

---

## Embursa — 47% (in band)
Fire burn-fuel bear. The sim carries with Set Ablaze, never uses Q5, and greedy spams Honey Bribe. Rest
auto-heals Burn, so the fuel never stacks.

**[Thing] The burn-fuel identity never turns on, because Rest cleans the Burn.**

*1) Reason.* Embursa is supposed to thrive while Burned, but it's almost never Burned for long. Tinderclaws gives
it a 50% SpATK boost while Burned. But resting removes the Burn, so the boost rarely persists.

*2) Why I know it.* The ability burns Embursa about a third of the time after a move, and grants +50% SpATK while
that Burn holds. Rest, the default recovery action, heals the Burn. So the risk-reward loop the mon is named for
resets itself every time you top up stamina, and you usually sit at one stack or zero.

*2.5) Why isn't what we have working.* This is mechanical. The self-heal on Rest fights the identity directly. The
moves also don't key off being Burned, so even when the boost is up, it only changes a number, not a plan.

*3) Uncertain?* Low on the mechanism. The open question is whether a stacked-burn Embursa actually out-damages a
safe one, once it can stay Burned. That is the untested premise the whole rework rides on.

*4) Validate?* Static first. A +50% SpATK boost multiplies special damage by 1.5, which is exact from the formula.
Then test code: script a Burned Embursa and an un-Burned one, have each use Set Ablaze, and compare the damage and
the self-inflicted HP loss over several turns. The change is to stop Rest from healing Burn, then re-run and confirm
the boosted line out-damages the safe line without Embursa killing itself.

*5) What would change my mind.* If the burn chip plus the boost nets out negative, staying Burned isn't worth it,
and the identity should be softened rather than leaned into. If the boosted damage clearly beats the safe line, the
premise holds.

*6) Easy to test?* Yes. The multiplier is exact, and the several-turn script is cheap.

*7) Simulated result.* I expect the boosted line to win on damage but to demand real HP management, so it's a proper
risk-reward rather than free power.

*8) Consistent with (1)?* Yes. The fuel never turns on because Rest cleans it, and the rework hinges on the boosted
line actually paying.

**[Thing] Q5 is a dead slot, because a myopic pilot can't value 5-turn-delayed damage.**

*1) Reason.* Q5 is used about 0% of the time. It deals its damage in five turns and burns the enemy. The pilot never
picks a payoff it can't score now.

*2) Why I know it.* The move fires its 150 damage five turns after it's cast. A 1-ply pilot can't see that far, so
it scores as zero value on the turn you'd click it. Its usage confirms that: near-zero in both pilots.

*2.5) Why isn't what we have working.* This is partly piloting and partly design. The pilot can't value delay, but
even for a human, banking on damage five turns out is hard, because the target can switch or the game can end first.

*3) Uncertain?* I'm unsure whether Q5 is player-usable even though the CPU can't see it. That's the real question:
is it a good move nobody's pilot can score, or a bad move full stop?

*4) Validate?* Test code, since it's a multi-turn payoff. Script Q5, then five turns of a normal attacker for
comparison. Compare Q5's eventual 150 to two normal hits landed over the same span. We change nothing to measure
the current move.

*5) What would change my mind.* If the delayed 150 beats what Embursa could have done attacking over those five
turns, it's a strong tool a smarter pilot could use. If it loses to just attacking, it's a dead slot.

*6) Easy to test?* Yes, it's a fixed five-turn script.

*7) Simulated result.* I expect Q5 to lose to just attacking, because delayed damage is easy to dodge and Embursa
gives up tempo to set it up.

*8) Consistent with (1)?* Yes. It's a weak slot, not just an unpiloted one.

**[Property] Keep Burn through Rest with a bigger boost, and make a move key off being Burned.**

*1) Opinion.* Rest should no longer clear Burn, and the burn SpATK boost should be larger to pay for the ongoing
damage. One attack should also gain a bonus effect while Embursa is Burned.

*2) Property.* This supports risk/reward, synergy, and flavor. The mon literally burns itself for power.

*3) Why.* Keeping Burn creates the stay-Burned decision the mon is named for. A move that keys off Burn makes the
status change your options, not just a number. Together they turn a passive boost into an actual identity.

*4) Better alternatives?* We could instead rework Q5 into an immediate burst move.

*5) Their tradeoffs.* Reworking Q5 loses the delayed-bomb flavor, and it still doesn't fix the burn-fuel loop. The
Rest change is the one that actually turns the identity on.

*6) Still hold it?* Yes, gated on the step-4 test showing the boosted line pays.

*7) Amend.* Cap the self-burn so it's a risk, not a suicide. If Q5 tests as a dead slot, rework it into an immediate
move as the one new/changed slot.

*8) Empirical hook.* Run the burned-versus-safe damage script from step 4, and the Q5-versus-attacking script, to
decide both the Rest change and Q5's fate.

*Summary:* Existing changed — **Tinderclaws/Rest** (Rest keeps Burn, larger boost), one attack gains a Burned-only bonus.
New move — **Q5 rework** to an immediate burst if the delayed version loses its test (replaces Q5). Two changes max.

> **2nd pass:** I under-analyzed Honey Bribe and should reprice it before touching the kit. It halves the opponent's
> Special Defense, which is real setup for Embursa's own special attacks — that's separate from the heal-both, and
> it's easy to miss because the greedy pilot just spams it as a heal. Once the SpDef cut is credited, Honey Bribe may
> be a stronger slot than the usage suggests, and the burn-fuel rework should be judged against a kit that already
> has a real setup move. Two changes max still holds, but Honey Bribe might not be one of them.

---

## Volthare — 50% (in band)
Fast Lightning/Cyber. The sim uses Dual Shock, Electrocute, and Mega Star Blast, and rarely picks Round Trip.
Zap, a turn-skip status, is swingy and under-leveraged.

**[Thing] Zap is a swingy, no-counterplay status, and Round Trip is a weak pivot.**

*1) Reason.* Zap's skip-a-turn is all-or-nothing, and Round Trip barely gets picked. Zap either does nothing or
steals a whole turn. Round Trip is a 30-power pivot, which is thin.

*2) Why I know it.* A Zapped mon skips its next action entirely, so a low-chance proc is either wasted or
game-deciding, with nothing you can do about it. Round Trip deals 30 and switches, but 30 damage is small even for
a pivot, so its 3–11% usage is honest. Volthare's better buttons crowd it out.

*2.5) Why isn't what we have working.* Zap is a design problem: it's binary. Round Trip is mechanical: the payoff
is just too small. Both leave Volthare's kit feeling like a few good moves plus filler.

*3) Uncertain?* Some, on how a reworked Zap actually plays. A value-Zap is a design change, so its feel is a guess
until scripted.

*4) Validate?* Test code. Script a Zapped attacker under the current turn-skip and under a value-Zap that drops
priority and cuts damage by 25%, and measure the tempo swing in each. The change is the Zap rework in the mockup.
Read whether the value version ever produces a "did nothing and lost" turn.

*5) What would change my mind.* If a value-Zap creates a usable window without stealing games, it's the better
design. If it turns out to do too little to matter, then the swingy skip was at least impactful, and I'd retune
rather than replace it.

*6) Easy to test?* Yes, the tempo swing is scriptable in a couple of turns.

*7) Simulated result.* I expect the value-Zap to be more consistently useful and far less feel-bad. So spreading
it becomes a real plan.

*8) Consistent with (1)?* Yes. Zap is swingy and Round Trip is thin, and both are fixable.

**[Property] Rework Zap into a value debuff and build Volthare around spreading it.**

*1) Opinion.* Zap should drop the target to minimum priority and cut its damage by about 25% for two turns, with no
skipped turn. Volthare should get a cheap, reliable Zap-spreader so its job is neutering a threat.

*2) Property.* This supports meta and risk/reward. Zap becomes a status you weave for value, and Volthare gets a
defined role.

*3) Why.* A value-Zap is something you apply for ongoing tempo, not a coinflip that either wins or whiffs. It leans
on Preemptive Shock's hit-and-run identity: come in, chip, and leave the target weakened. It also gives the opponent
a real out, since they can switch to clear it, which is healthy.

*4) Better alternatives?* We could keep the skip-turn and just raise its proc rate.

*5) Their tradeoffs.* Raising the rate doubles down on the swing, which is the exact feel-bad we're removing. The
value version is more consistent and more interactive.

*6) Still hold it?* Yes.

*7) Amend.* Dual Shock's self-Zap becomes a real cost rather than a self-skip, and bump Round Trip's power so the
pivot is worth clicking.

*8) Empirical hook.* Run the step-4 tempo script and confirm the value-Zap never produces a dead-turn loss.

*Summary:* Existing changed — **Zap** (value debuff, no skip), **Electrocute/Dual Shock** re-tuned around it, **Round Trip**
power bump. New moves: none.

---

## Aurox — 41% (validated: mispiloted, not weak)
Metal permabull tank. Already worked and validated. The tank line moves it from 35% to 47%, and the
per-opponent split shows a real matchup-defined role.

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

*4) Validate?* Done, in the chomp scripted rig. We changed nothing in the engine and added an override script, then
re-ran win rate and the per-opponent split.

*5) What would change my mind.* Already answered: the tank line moved the number, so it isn't structurally weak.

*6) Easy to test?* It was, and it's done.

*7) Simulated result.* Not applicable, because we ran it.

*8) Consistent with (1)?* Amended: not weak, mispiloted.

**[Property] Replace Volatile Punch with Bull Trap, not a damage counter.**

*1) Opinion.* Volatile Punch is dead in every pilot, so it should be replaced. The replacement should be Bull Trap,
a taunt that forces the opponent to use damaging moves.

*2) Property.* This supports synergy, risk/reward, and flavor. It forces the hits Up Only and Iron Wall both want.

*3) Why.* Bull Trap makes the opponent attack, which feeds Up Only's ramp and Iron Wall's regen. It's a control
move, not a damage move, so it never competes with Bull Rush. And it's on-flavor: bait them into charging the wall.

*4) Better alternatives?* The obvious alternative is a damage counter that hits back for a share of the damage taken.

*5) Their tradeoffs.* We tested the counter, and it fails twice. It's prediction-dependent, dealing 257 when the
opponent attacks and 15 when they don't. And because Aurox is the slowest mon, it always has ammo, so the counter
cannibalizes Bull Rush. Bull Trap avoids both, because it forces the outcome instead of betting on it.

*6) Still hold it?* Yes. The sim chose Bull Trap over the counter.

*7) Amend.* Give it a 2-turn duration, and let a switch escape it.

*8) Empirical hook.* Mock Bull Trap, then confirm it feeds Up Only and doesn't dent Bull Rush's usage.

*Summary:* Existing changed — none. New move — **Bull Trap** (0 power, 2 stamina, Metal, Other, 100 accuracy; for two turns
the opponent can only use damaging moves) **replaces Volatile Punch**.

> **2nd pass:** Bull Trap's "feeds Up Only" is conditional, and I stated it too flatly. It only ramps if the
> opponent stays in and is forced to attack. If they switch to escape, Bull Trap instead denies their setup, which
> is still fine but doesn't feed the ability. Worse for the "fix Aurox" framing: it helps Aurox's *good* matchups
> (setup and passive teams), not its burst-and-Fire losses, because burst mons are already attacking. So justify
> Bull Trap as a flavorful replacement for a dead slot that synergizes with the ability — not as a patch for
> Aurox's weaknesses, which we've agreed are acceptable counters anyway.

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

*4) Validate?* Test code. Mock the reworked pieces, then script Contagious Slumber into Night Terrors against a
target, and compare its damage to a Vital-Siphon-spam line over the same turns. The changes are: no self-sleep on
Contagious Slumber, and Night Terrors deals big damage only against a sleeping target with no self-drain. Re-run and
check the engine now beats the spam.

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

*8) Empirical hook.* Run the step-4 engine-versus-spam script. That single result decides between the payoff rework
and the soft-counter fallback.

*Summary:* Existing changed — **Contagious Slumber** (no self-sleep), **Night Terrors** (big versus asleep, no self-drain),
**Somniphobia** (Rest risks Sleep), **Vital Siphon** nudged. New moves: none.

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

*4) Validate?* Static first, and it's already decisive: one 1.5× hit beats no move only if the setup turn does
nothing else, which it doesn't. Then test code to confirm: script Nine Nine Nine into a crit hit, and compare its
two-turn damage to two plain Overflows. We change nothing to measure the current move.

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

*8) Empirical hook.* Script the reworked 999 line and compare it to two attacks, and separately to the Sneak Attack
combo, to confirm the new version actually pays.

*Summary:* Existing changed — **Nine Nine Nine** reworked (crit tied to Sneak Attack, or burst scaling with KOs). New moves:
none.

---

## Nirvamma — 40% (unreliable; a setup mon the greedy pilot spams into 10% wins)
Math meditation and defillama mon. Already worked. Chronoffense is a fine 2HKO combo, and the gap is the
in-between turns.

**[Thing] Chronoffense is fine, and the in-between turns are the real gap.**

*1) Reason.* Nirvamma has nothing worthwhile to press between arming and firing Chronoffense. Chronoffense buffs on
the first press and 2HKOs on the second, which is a fine self-contained combo. The problem is the turns around it.

*2) Why I know it.* The greedy pilot spams Chronoffense to a 10% win rate, and the hard pilot barely uses it, so the
number is a pilot artifact. Its other slots are a plain damage move and a narrow anti-rest move. So nothing gives
Nirvamma a reason to exist between the two Chronoffense presses.

*2.5) Why isn't what we have working.* The low number is piloting, but the in-between emptiness is design. Scary
Numbers is a fine baseline hit and not the villain. The real gap is that no slot rewards the wait.

*3) Uncertain?* Low on the design gap. The uncertain part is where a properly-piloted Nirvamma lands, which needs the
override to manage the setup.

*4) Validate?* Test code, once Mean Reversion is mocked. Script a filled-in Nirvamma against a boosted target and
measure whether the in-between turn now does real work. This needs the override to pilot the setup, which is the
gating requirement.

*5) What would change my mind.* If a filled-in Nirvamma lands mid-pack, the design fix worked. If it stays low even
when piloted, the problem is deeper than the in-between turns.

*6) Easy to test?* Only after the override can manage the setup. Until then, no arena number here means anything.

*7) Simulated result.* I expect mid-pack when piloted, so the fix is about the in-between, not about power.

*8) Consistent with (1)?* Yes. Chronoffense is fine, and the gap is the surrounding turns.

**[Property] Add Mean Reversion to fill the in-between turn.**

*1) Opinion.* Add a move that scales with how much the opponent has boosted, and that strips those boosts on hit,
with a damage floor so it's never a dead turn.

*2) Property.* This supports risk/reward, meta, and flavor. It's an anti-setup tool, and reversion to the mean fits
the defillama theme.

*3) Why.* It gives the in-between turn a real job, and it does something no other mon does: remove boosts. Setup is
close to risk-free right now, so a move that punishes and undoes it adds the missing risk. The floor means it isn't
a blank turn against a non-booster.

*4) Better alternatives?* We considered Compound Interest and an execute.

*5) Their tradeoffs.* Compound Interest duplicates Chronoffense's invest-then-pay role. The execute is win-more,
strong only when you're already ahead. Mean Reversion is the one that fills the actual gap and does something unique.

*6) Still hold it?* Yes.

*7) Amend.* Keep the floor so it always does modest damage, and keep the strip as the point.

*8) Empirical hook.* Static: after a known boost, the strip should return the target's damage to its unboosted value,
which is exact from the formula. Test: script it against a boosted target and confirm the strip plus scaled damage.
Arena only once it's piloted.

*Summary:* Existing changed — **Chronoffense** curve smoothed, optional. New move — **Mean Reversion** (roughly 60 power plus
scaling, 2 stamina, Math, Physical; strips boosts). Replaces **Hard Reset**.

---

# Speculative new mons

> **2nd pass:** these two are the lowest-confidence entries in the doc, and the templates strain here. A speculative
> mon has no "why isn't it working," so the [Thing] leans on a role-gap claim that's closer to assertion than data.
> Both also need real mechanical prototyping — a persistent field-state system and live type-shifting are non-trivial
> to build and balance, not a one-line mockup like the moves. Treat these as concepts to greenlight, not specs to
> implement, and only after the existing roster's cheaper, higher-confidence fixes are settled.

## New mon A — field-setter ("Oracle", working name)
The roster has no persistent battlefield axis except Overclock, which only touches team speed. A field-setter would
add a team-building keystone. The crypto-native flavor is a price-oracle creature that "sets the market."

**[Thing] The roster is missing a persistent-field role, and that's a real gap, not just a missing flavor.**

*1) Reason.* Almost every mon fights over the same axes: damage, status, and switching. Only Overclock changes the
shared battlefield, and only for speed. So there's an untouched design space that a whole mon could own.

*2) Why I know it.* Look at the 13 kits. The status effects are all per-mon, and the one field effect is Overclock.
Nothing sets a lasting, symmetric condition both players navigate. A field-setter would create counter-teaming and
new synergies, which is where we want initial advantage to come from.

*2.5) Why isn't what we have working.* There's no failure to fix, because the role simply doesn't exist yet. The gap
is that team-building has fewer axes than it could, so games lean more on in-battle play than on composition.

*3) Uncertain?* The uncertainty is complexity. A field system can become a bookkeeping burden, and the game promises
to be easy to understand. So the open question is whether one legible field earns its complexity.

*4) Validate?* Test code, as a proof of concept. Mock one field state, say "Volatility" that raises all damage and
crit variance, and script a 4v4 with and without the field. Read whether outcomes and best-lines change. The change
is the mocked ability and field.

*5) What would change my mind.* If the field barely changes 4v4 outcomes, it isn't worth the complexity. If it clearly
reshapes team-building without dominating, the role is worth adding.

*6) Easy to test?* The 4v4 proof of concept is scriptable once the field is mocked, though tuning it takes iteration.

*7) Simulated result.* I expect one well-chosen field to shift matchups meaningfully, so the role justifies itself.

*8) Consistent with (1)?* Yes, provided the field stays legible and opt-in.

**[Property] Give it an ability that sets one persistent field, and moves that exploit its own field.**

*1) Opinion.* On switch-in it sets a single field state for several turns, and its own moves gain a rider under that
field. Keep it to one or two field states tied to this mon, so complexity is opt-in.

*2) Property.* This supports meta and risk/reward, by adding a team-building axis both players must plan around.

*3) Why.* A symmetric field both sides navigate creates yomi, and it pushes advantage up to composition. Attaching the
complexity to a mon you chose to bring keeps the base game simple for everyone else.

*4) Better alternatives?* We could build a full weather system, or make it a one-off self-buff.

*5) Their tradeoffs.* A weather system is complexity creep across the whole game. A one-off buff is just another setup
move, not a new axis. A single mon-bound field is the middle path.

*6) Still hold it?* Yes, as a speculative concept to prototype.

*7) Amend.* Cap it at one or two fields, and make sure the field helps the opponent's counters too, so it isn't a
one-sided buff.

*8) Empirical hook.* The step-4 4v4 proof of concept: does the field change outcomes without dominating.

*Summary:* New mon. Ability sets one persistent field; three attacks gain a rider under its own field, plus one utility.
Niche: a team-building keystone, weak when the field is played around. At most one ability plus two signature moves.

## New mon B — type-shifter ("Wrapped", working name)
Type-fluidity is an identity nobody owns; only Modal Bolt and Guest Feature flirt with it. This mon games the
deliberately asymmetric type chart. The crypto flavor is a wrapped or synthetic asset that takes the form of others.

**[Thing] Type manipulation is an underused, Stomp-native axis, and the asymmetric chart is what makes it work.**

*1) Reason.* The type chart is deliberately lopsided, and right now players just endure their matchups. A mon that
changes its own type would turn that chart from a static constraint into a skill. Two existing moves hint at it, but
no mon is built around it.

*2) Why I know it.* Modal Bolt picks an element, and Guest Feature borrows an ally's type, so the engine already
supports type-fluidity. But both are one-off riders, not an identity. The asymmetric chart means a shift can swing a
matchup hard, which is exactly what makes the mechanic interesting rather than flat.

*2.5) Why isn't what we have working.* Again, the role doesn't exist yet, so there's nothing broken. The gap is that
the game's most distinctive asymmetry, the type chart, is something players suffer rather than game.

*3) Uncertain?* The uncertainty is legibility and balance. A type-shifter can be confusing to play against, and it
could be too strong if it dodges every weakness. So the open question is whether it stays soft to something.

*4) Validate?* Test code, as a matchup grid. Mock the shift ability, then script it into several matchups and check
whether shifting flips the ones it should. Also check it stays weak to type-agnostic pressure, like status or stamina
denial, which ignore its type. The change is the mocked ability.

*5) What would change my mind.* If shifting lets it dodge every weakness, it's oppressive and needs a hard limit. If
it flips the intended matchups but still folds to status and stamina pressure, it's a healthy tech piece.

*6) Easy to test?* The matchup grid is scriptable once the ability is mocked, though balancing the shift set takes
iteration.

*7) Simulated result.* I expect it to win the matchups it reads correctly and lose to type-agnostic pressure, which
is the intended shape.

*8) Consistent with (1)?* Yes, provided it keeps a real weakness.

**[Property] Build it around changing its own type as a read.**

*1) Opinion.* Give it a move that sets its type for the turn from a fixed set, chosen before the opponent's move
resolves. The ability makes it take on the type of its last move, so its defense follows its offense.

*2) Property.* This supports fun through yomi, and meta through matchup manipulation.

*3) Why.* Because the shift is a commit, it's a prediction: resist the hit you expect, or gain STAB on the hit you'll
land. That rewards knowing the chart, which is the initial-knowledge edge we want. It makes the asymmetric chart a
tool rather than a tax.

*4) Better alternatives?* We could make it adapt on being hit, like Nirvamma's Adaptor, or give it fixed dual-typing.

*5) Their tradeoffs.* Adapt-on-hit is reactive, so it's a defensive gimmick, not a read. Fixed dual-typing is just a
statline, with no agency. The active shift is the only version that's a decision.

*6) Still hold it?* Yes, as a concept to prototype.

*7) Amend.* Make it frail, so it wins on matchup, not stats, and keep it soft to status and stamina pressure.

*8) Empirical hook.* The step-4 matchup grid: does the shift flip the right matchups while staying weak to
type-agnostic pressure.

*Summary:* New mon. Ability: takes on the type of its last move. Signature: a type-set move as the read, plus moderate
attacks it retunes. Niche: a control and tech piece, not raw power. At most one ability plus two signature moves.
