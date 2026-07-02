# Stomp design pass (v2)

## Purpose

Per mon: screen the win rate as a health check, then find moves that are never used or superseded and rework
them into something situationally useful, synergistic, and flavorful. Win rate 45–55% is fine, clean counters
are fine — it's a screen, not a target. The arena is zero-sum, so the field averages ~50% and not every mon can
sit above it: **~50% (band centre) is the target**, and a mon's own `hard` or `override` number is a data point,
never a floor it must clear. Cap two new moves per mon.

## How each mon is analyzed

A mon is a woven sequence of as many `[Thing]` and `[Property]` blocks as the reasoning raises, interleaved in
the order the argument actually goes — not one-Thing-then-one-Property, and not one of each. A typical order:

```
[Thing]     an observation about how it works / what's wrong
[Property]  a design response to it
[Property]  a second design angle
[Thing]     a new observation (with its own validation)
[Thing]     another observation
[Property]  the synthesizing / power-direction conclusion
```

Every block carries its full template, at full depth. Adding more blocks never lightens a block. Each sub-section of a block contains at least 3 to 4 sentences.

**`[Thing]`** — an empirical claim.
1) reason · 2) why I know it · 2.5) why isn't what we have working · 3) uncertain? · 4) validate ·
5) what would change my mind · 6) easy to test? · 7) simulated result · 8) consistent with (1)?

**`[Property]`** — a design opinion.
1) opinion · 2) which property (fun / difficulty / risk-reward / meta / complexity / progression) · 3) why ·
4) better alternatives · 5) their tradeoffs · 6) still hold? · 7) amend · 8) empirical hook.

Validation (step 4 of a Thing, step 8 of a Property) is a **structured bullet list**: measure the baseline →
the exact change to make → the delta expected → separate the regimes so the move carves its own niche → how the
call updates in both directions. Static checks (type chart, damage formula, reading the actual contract) stay
static. Plan-based moves (setup, resource, self-sacrifice, delayed payoff) fork on the opponent's branches —
stay versus switch, set-up versus race — and need an override CPU that plays the plan before any arena number
counts.

## Validation tooling

Each validation bullet maps to a concrete tool, not an abstract "scripted test":

- **Static / mechanical** (damage math, move costs, degree tables, mechanic checks): read the contract in
  `src/`, or script an exact 1v1 in `chomp/sims` (`src/harness.ts`: `makeSimContext` / `buildMon` /
  `startBattle` / `executeTurn`, explicit move indices, no CPU, so no peek/prediction confound).
- **Win-rate + move-usage screen** (is it in band, which moves are dead): the chomp-native arena
  `chomp/sims` (`cd sims && bun arena/mon-data.ts --strategies hard,greedy,override`) — per-mon win rate +
  per-move usage, seat-swapped, run over chomp's own transpiled `ts-output` engine (the canonical, current one).
- **Plan-based / scripted-pilot** (does the intended line beat the naive one): the `override` CPU
  (`chomp/sims/src/cpu/strategies/override-cpu.ts`) — base-HP-keyed scripts with `when` / `once` / `maxUses`
  gates, falling through to `hard`. Add the mon's script alongside its analysis, then re-run
  `bun arena/mon-data.ts --strategies override`.
- **In-game instrumentation** (switch-rate to shed a debuff, revive/KO availability, forced-switch value,
  stamina deadlock): a bespoke script over `playGame`'s `onBeforeExecute` hook plus the `engine-view` readers —
  no framework change.
- **New-move mechanics**: mock the move in the transpiled TS (`chomp/transpiler/ts-output/mons/…`) and script it
  in `chomp/sims`. Its **arena** win-rate impact is heavier — the mockup must also be synced into munch's
  generated sim and used by the override — so new-move claims validate mechanics first and defer arena-impact.

## Reasoning rules

1. **Couch every conclusion in the actual win rate and stat line, and match the change's power direction to
   where the mon sits.** Below-band (≤~45%) → the package must be a net buff (nerf one lever only if it's paid
   back with a real, quantified buff). In-band (~45–55%) → laterals / net-neutral. Above-band (≥~55%) → nerf or
   lateral, never raw power. Never ship an all-nerf package on a below-band mon.
2. **Judge every move inside the whole game system, not by a static stat-line comparison.** The stamina economy
   is load-bearing: 5 starting stamina, +1 regen per turn, so a cheap move can earn its slot precisely because
   it's affordable when the expensive ones aren't. Weight 0-stamina moves as spammable; trace a multi-turn line
   before calling anything dead.
3. **Unpiloted is not weak.** Many low scores are piloting floors — the CPU won't self-KO, manage a resource, or
   complete a setup. State the pilot logic, and treat plan-based mons' numbers as floors that need a scripted
   line or override to judge.
4. **Ground every claim in numbers from source.** Read the contract for mechanics and constants; don't assert.
   Damage ≈ basePower × attack ÷ defense × type × crit (1.5×), so relative claims are exact.
5. **Judge moves with the team, and name the concrete partner** — no hand-waved "a partner that punishes
   switches."
6. **Full move metadata always** (Name — Power / Stamina / Type / Class / Accuracy / Priority — effect) and full
   mechanics; no shorthand.
7. **Check feasibility against existing engine primitives** (`setMove` for a taunt, `clearAllStatBoosts`,
   per-battle `globalKV` flags); label each change a cheap number swap, a new move/effect contract, or heavier
   work.
8. **Entertain alternatives generously; gate strong new effects with an anti-spam limiter** (once per game, a
   cost, a drawback). Don't duplicate a baseline move. Avoid stall and immediate heals.

## Executive summary format (per mon)

Nested:

```
- Mon — net direction (buff / lateral / nerf)
  - Findings (couched in win rate + stats)
  - Move X → changed to: <full metadata / behavior>
    - Rationale
  - NEW Move A: <description, full metadata>
    - Rationale
  - Validation gate (where relevant)
  - New moves: count / none
```

## The `[Predicted]` / `[Addressed]` review layer

After each mon's analysis sits a **separate, visible layer** — not folded into the blocks above it:

- **`[Predicted]`** blocks simulate the feedback the designer would give, in his voice, finding gaps in the
  reasoning. They are left *unaddressed*, for his own review pass.
- **`[Addressed]`** blocks answer each one, verified against source where possible. When a finding changes the
  design, that change is carried back into the analysis and the summary above.

## CPU pilot gaps and buff candidates

Many dead moves are piloting artifacts, not weak designs (rule 3), so the fix is often a pilot rule rather than
a move change. Two artifacts come out of this:

- **`[CPU gap]`** — a *hypothesized* pilot rule a harder difficulty should implement so the mon plays its
  intended line (e.g. Ghouliath firing Eternal Grudge when it would otherwise be KO'd). It's a hypothesis until
  an override run measures it, and it can test negative.
- **`[CPU buff]`** — an override rule that *measurably beat `hard`*, the strong baseline pilot. That's evidence
  the production CPU is leaving win rate on the table, so it's a candidate to promote into munch's CPU. The bar
  is beating `hard` by more than sampling noise (≈1 SE; roughly ≥3–4 points at 100–250 games, confirmed at
  larger N) — beating `greedy` or the raw average doesn't count, since `hard` is what ships.

Per-mon protocol: when a mon's override is run, record `override vs hard` in its validation and summary. A
positive delta beyond noise earns a `[CPU buff]` flag on the mon and a PROMOTE row in the buff-candidates table
at the end of the doc; a flat or negative result is recorded as "tested, not promoted" so it isn't silently
retried. The promotion target in munch is a per-mon entry in the CPU's `MonConfig`
(`services/cpu/heuristic-shared.ts` — `CONFIG_PREFERRED_MOVE` / `CONFIG_SWITCH_IN_MOVE` / `CONFIG_SETUP_MOVE`,
read by `hard` via `tryConfiguredMove` / `tryPreferredMove`), so "Iron Wall on entry, then Bull Rush" becomes
Aurox's switch-in + preferred-move config. Actually editing munch is deferred; this doc only tracks the
candidates. Both artifacts collect into the running punch-list at the end of the doc.

## Writing

Simple, clear, complete sentences — one claim, then its supporting data. Contractions are fine; clarity over
ease. No sentence fragments, no clause-stacking, no clever or writerly metaphors, no terse code-comment
shorthand.

---

## Data foundation

Fresh per-mon data from the **chomp-native** CPU arena — 250 random 4v4s per pilot, seat-swapped to cancel the
p1 peek, same strategy both sides (`cd sims && bun arena/mon-data.ts`), run over chomp's own current `ts-output`
engine. `hard` is a peeking lookahead pilot; `greedy` is a 1-ply evaluator that over-values setup. Read the
**avg** as the health screen, and the **hard/greedy gap** as the skill-gate / piloting signal.

These numbers replace an earlier run made on munch's *stale* transpiled engine. The regeneration matters: the
biggest shift is **Xmon's Somniphobia**, which the reworked (current) engine makes a live move — usage jumped
from 1% to **32%** under hard — so it drops off the dead-slot list entirely. Most other win rates moved only a
few points.

### Win rate (wins / (wins + losses))

| Mon | hard | greedy | avg | band |
|---|---|---|---|---|
| Ekineki | 56.5 | 57.5 | **57.0** | above |
| Gorillax | 56.6 | 56.5 | **56.6** | above |
| Sofabbi | 55.9 | 55.6 | **55.8** | above |
| Ghouliath | 53.8 | 56.8 | **55.3** | above (greedy-skewed) |
| Volthare | 50.6 | 57.7 | **54.2** | in band (edge; greedy-skewed) |
| Malalien | 50.6 | 49.6 | **50.1** | in band |
| Xmon | 49.3 | 50.0 | **49.7** | in band |
| Embursa | 47.9 | 49.3 | **48.6** | in band |
| Pengym | 48.6 | 47.5 | **48.1** | in band |
| Nirvamma | 45.7 | 46.7 | **46.2** | in band (low edge) |
| Inutia | 52.0 | 36.6 | **44.3** | below band (greedy floor) |
| Iblivion | 42.6 | 41.8 | **42.2** | below band |
| Aurox | 38.6 | 43.5 | **41.1** | below band |

### Dead slots — ≤~5% usage in **both** pilots (primary rework targets)

Ghouliath **Eternal Grudge** · Inutia **Chain Expansion** · Embursa **Q5** · Aurox **Gilded Recovery** (and low
**Volatile Punch**) · Ekineki **Nine Nine Nine** · Nirvamma **Hard Reset** · Iblivion **Renormalize**. (Gorillax
**Rock Pull** is low too — 2% hard / 8% greedy.) **Xmon Somniphobia is no longer here** — on the current engine
the reworked move is a hard-favored 32% pick, not a dead slot.

### Pilot-split slots — heavy for one pilot, ignored by the other

These are setup / resource moves the CPUs mishandle in opposite directions, so the raw win rate is a floor and
the real read needs a scripted or override line ("unpiloted is not weak"):

Iblivion **Loop** (8% hard / 93% greedy) · Nirvamma **Chronoffense** (5 / 84) & **Modal Bolt** (48 / 9) · Inutia
**Initialize** (5 / 73) · Xmon **Contagious Slumber** (5 / 38) · Pengym **Deadlift** (3 / 43) · Aurox **Iron
Wall** (0 / 26) · Sofabbi **Snack Break** (16 / 66) · Malalien **Triple Think** (5 / 13). The one *hard*-favored
split is Xmon **Somniphobia** (32 / 5) — the strong pilot values the reworked move, the opposite of the
greedy-favored setup moves.

*Method note: current-engine order — the below-band trio is Inutia, Iblivion, Aurox (Aurox the floor at 41.1),
and the big hard/greedy gap at Inutia (52.0 / 36.6) confirms its floor is a piloting artifact. Bands: above ≥55,
in-band 45–55, below ≤45.*

---

## Ghouliath — 55.3% (above band; 53.8 hard / 56.8 greedy)
Yin/Fire, id 0. Ghouliath is a bulky, low-offense mon: HP 303, Defense and Special Defense both 202, Speed 181,
but only ATK 157 and SpATK 151. Its ability, Rise From The Grave, revives it once per game three turns after any
KO at 1 HP, so it effectively carries two life bars. The arena plays it as a plain attacker — Infernal Flame
70%/69% and Osteoporosis 26%/23% — while the signature Eternal Grudge sits at 1%/3% and Wither Away at 3%/5%.
The intent, per `design.md`, is a suicide lead that cripples with status and then cashes out with Eternal
Grudge, and that intended line never appears.

**[Thing] Ghouliath is above band, but it wins as a generic attacker rather than the suicide lead it's designed to be.**

*1) Reason.* At 55.3% average, Ghouliath is above the 45–55 band, so nothing on the scoreboard is broken and
this is not a mon to strengthen. But the win rate comes from a plain damage line, not from its identity. Infernal
Flame is roughly 70% of its turns and Osteoporosis another quarter, which together account for almost everything
it does. The suicide-grudge play the mon is built around is absent from actual games.

> Note that the win rate % itself is subject to some uncertainty depending on the trials that we run.

*2) Why I know it.* The move-usage split is nearly flat across both pilots, which rules out a single pilot's
blind spot. Infernal Flame is 70% under hard and 69% under greedy; Osteoporosis is 26% and 23%. Eternal Grudge
is 1% and 3%, and Wither Away is 3% and 5%. When a myopic evaluator and a lookahead pilot both converge on the
same two buttons, that two-button line is what is producing the 55.3%.

*2.5) Why isn't what we have working.* Nothing fails on win rate, so the gap here is identity, not power.
Ghouliath's offense is low at 157/151, so it plainly isn't winning on raw damage. It's winning on durability —
Defense and Special Defense both 202, plus Rise From The Grave's second life — and on Infernal Flame's 30% burn
chipping the opponent across that long life. The design's whole reason to pick Ghouliath, the cripple-then-grudge
sequence, contributes none of that.

*3) Uncertain?* The open question is whether the dormant identity is a piloting artifact or a genuinely bad move.
The fact that Eternal Grudge is dead under both pilots points toward piloting, since a self-KO is exactly the
kind of move a win-maximizing evaluator refuses. But usage alone can't distinguish "too clever for the CPU" from
"actually bad," so I need the mechanics before judging. That is what the next block establishes.

*4) Validate?*
- Read the move-usage table across both pilots and confirm Eternal Grudge and Wither Away are near-zero under
  each, so this isn't one evaluator's quirk (done: 1/2% and 2/5%).
- Read the Eternal Grudge and Rise From The Grave contracts to decide whether the signature is weak or merely
  unpiloted, which the next block does.
- Stand up an override that fires Eternal Grudge on time, re-run the win rate, and see whether the identity line
  is competitive with the plain attacker line.
- The call updates cleanly: if the piloted line matches or beats the plain line, the move is fine and dormant; if
  it loses even when piloted, it's a real rework target.

*5) What would change my mind.* If Eternal Grudge turns out to be a bad trade even when a competent pilot fires
it at the right moment, then it's a genuine move-quality problem and belongs on the rework list. If instead it's
strong but simply never chosen, then Ghouliath is healthy and the fix is a pilot rule. The deciding evidence is
the mechanics plus the piloted win rate, not the raw usage. My prior is strongly toward unpiloted, given the
self-KO.

*6) Easy to test?* The usage is already measured and the mechanics are a direct source read, so those halves are
cheap and mostly done. The piloted value is not a one-liner, because it needs an override that will actually
choose a self-KO at the right time. That override is the same tooling this whole pass depends on, so it's worth
building once. Until it exists, the piloted number is an estimate.

*7) Simulated result.* I expect the analysis to land on unpiloted-not-weak, because the mechanics below show the
self-KO is nearly free given the revive. A competent Ghouliath should be able to fire the grudge on the turn it
would die anyway and come out ahead. So the plain line is a floor on Ghouliath's strength, not its ceiling. That,
on an already-above-band mon, is the source of the guardrail concern later.

*8) Consistent with (1)?* Yes. The mon is above band and its identity is dormant, and the whole section is about
why the signature never fires and what, if anything, to do given the mon is already winning. It is a
move-quality and piloting question sitting on top of a healthy win rate, not a power problem.

**[Thing] Eternal Grudge is unpiloted, not weak — the revive triggers on any KO, so the self-KO is nearly free.**

*1) Reason.* Eternal Grudge — 0 / 2 / Yin / Self / 100 / +1 — applies a Temp 50%/50% ATK-and-SpATK debuff to the
opponent and then KOs Ghouliath. Because Rise From The Grave revives Ghouliath three turns later at 1 HP, and it
fires on any first KO, the self-KO is refunded whenever the revive is still in hand. So the move's real cost is
the timing, and its benefit is the entire two-stat debuff. That is a very different trade from the pure sacrifice
the usage implies.

*2) Why I know it.* I read both contracts to be sure rather than trusting the flavor text. `EternalGrudge.move`
applies the Divide-50 stat boosts as a Temp effect and then deals exactly lethal self-damage. `RiseFromTheGrave.
onAfterDamage` triggers whenever `IsKnockedOut` flips to 1, with no check on the damage source, so a self-KO
revives just like an enemy KO. The interaction is therefore real and confirmed, not assumed.

*2.5) Why isn't what we have working.* This is piloting, and specifically the two failure modes we expect. Greedy
will never select a move that KOs its own mon, because its evaluator reads that as a catastrophic loss. Hard's
1-ply lookahead can't value a revive that lands three turns later, so it scores the grudge as a wasted, suicidal
turn. Neither sees that the +1 priority lets Ghouliath fire the grudge before an inevitable death and keep the
same revive.

*3) Uncertain?* The load-bearing unknown is how strong the piloted line actually is, and whether it pushes an
already-above-band mon out of the band. A free 50/50 offense cut on the opponent's active mon is a large swing,
so a Ghouliath that reliably lands it could climb well past 56%. But the debuff is Temp, so the opponent can
switch to shed it, which caps how much it's worth. The net of those two forces is exactly what the override needs
to measure.

*4) Validate?*
- Add an override that fires Eternal Grudge when the revive is still available and Ghouliath is about to be KO'd,
  then re-run the 250-game win rate.
- Log how often the opponent switches the crippled mon out to shed the Temp debuff, since that's the counterplay
  that bounds the move's value.
- Compare the piloted win rate to the current 55.3%: a large jump means the grudge is too strong for an
  above-band mon, and a small one means it's a fine, underused identity play.
- Confirm the debuff size by reading the boost (Divide-50 halves both offenses), so the damage swing behind the
  win-rate move is grounded, not guessed.

*5) What would change my mind.* If the opponent almost always switches out the debuffed mon and the piloted line
barely moves the win rate, then Eternal Grudge is a worse trade than the mechanics suggest and the identity is
genuinely weak. If the piloted line holds or climbs, it's strong and the only question is by how much. The
switch-rate is the single most informative number here, because it decides how much of the debuff is actually
collected. I expect it to be shed often but not always, since switching itself costs tempo.

*6) Easy to test?* The mechanics are settled statically, so that half is done. The piloted value needs the
override that sequences the grudge before death, which is real work but reusable across the roster. The
switch-rate falls out of the same run at no extra cost. So this is medium-effort, gated on the override existing.

*7) Simulated result — override pass falsifies my prediction.* I expected the piloted line to over-perform. It
doesn't. Scripting Eternal Grudge to fire on the turn Ghouliath would otherwise be KO'd moved its usage from
~1% to 13% but left the win rate flat: 54.5% override vs 53.8% hard (250-game current-engine pass, Δ +0.7). So
the grudge neither over- nor under-performs on the current engine — it's a wash. The likely reason is the
counterplay: the debuff is Temp and gets shed by a switch, and the revive fires whether or not you grudge, so
the self-KO just buys a droppable debuff. So the open question flips off the guardrail entirely — either the
naive "grudge on any lethal" rule is too coarse (it should fire only when the opponent can't switch to shed it),
or Eternal Grudge is simply marginal. A smarter grudge gate is the next test, not a nerf.

*8) Consistent with (1)?* Partly, and the data forces an amendment. The identity is still dormant (block 1), but
"dormant because unpiloted, not weak" is now in doubt: the piloted pass did not over-perform (54.5% vs 53.8%,
a wash). So the "over-strengthen an already-healthy mon" twist is off the table, and the guardrail below is
probably unnecessary — the live question is whether a smarter grudge rule pays at all.

**[Property] Don't buff it — make the identity accessible with a pilot fix, and keep a guardrail because it's above band.**

*1) Opinion.* Ghouliath is above band, so the goal is its identity and move quality, not more power. The action is
a pilot rule that fires Eternal Grudge in its right spot, plus a guardrail held in reserve. If the piloted grudge
pushes the win rate out of band, trim the interaction rather than leave the mon oppressive. The pilot fix comes
first because it costs no power and might be the whole answer.

*2) Property.* This is meta and progression — restoring the intended suicide-lead play — with a power-direction
guardrail attached. It is explicitly not a fun-through-power change, because the data says the mon doesn't need
power. The guardrail is the risk/reward lever that keeps the identity honest if the pilot fix over-delivers. So
the property is really "identity, bounded by the win rate."

*3) Why.* You don't strengthen a mon that already wins 56% of its games. The real problem is that Ghouliath wins
as a generic attacker instead of as the suicide lead it was built to be, which is a design failure hiding behind
a healthy number. A pilot fix restores the identity at almost no power cost, and the guardrail catches the case
where the free debuff tips the mon over the top of the band. That sequencing respects the above-band constraint
while still fixing the identity.

*4) Better alternatives?* We could buff Eternal Grudge to entice usage, leave the move dormant and accept the
generic line, or design a lateral that makes the grudge the efficient play without adding net power. Each is a
different answer to "the signature never fires." Only some of them respect the above-band constraint, which is
what separates them.

*5) Their tradeoffs.* Buffing the grudge pushes an above-band mon higher, which is the exact wrong direction on
the data. Leaving it dormant wastes the design and keeps the mon's whole identity off the table. The lateral is
the right shape, but it can't be tuned until we have the piloted number, so it has to come after the pilot fix,
not before. That ordering is the crux of the recommendation.

*6) Still hold it?* Yes, because the 55.3% sets the direction unambiguously: the change must not be a net buff.
The only open question is whether even the pilot fix over-performs, which is a measurement rather than a
disagreement. If it lands in band, we stop after the pilot fix. If it doesn't, the guardrail is ready.

*7) Amend.* Lead with the pilot, and make the guardrail concrete rather than vague. The cleanest guardrail is
that Rise From The Grave stops refunding a self-KO, which turns Eternal Grudge back into the true sacrifice it's
themed as and caps the free-debuff power in one change. That is the subject of the final block, kept separate
because it's a distinct design opinion with its own tradeoffs.

*8) Empirical hook.*
- Run the piloted override, read the win rate, and let that number decide whether any mechanical change is needed
  at all.
- If the win rate lands out of band, apply the guardrail and re-run until it settles back inside, so the fix
  never ships as a net buff.

**[Property] Guardrail: if piloted Ghouliath leaves the band, make Eternal Grudge a true sacrifice.**

*1) Opinion.* This guardrail was premised on the piloted grudge over-performing, and the override pass says it
doesn't (54.5% vs 53.8% hard, a wash). So it's probably unnecessary, and I'm keeping it on the shelf for
one case only: if a smarter grudge rule — fire only when the opponent can't switch to shed the Temp debuff —
turns the grudge into a real over-performer, then change Rise From The Grave so it does not refund a
self-inflicted KO. Eternal Grudge would then become the true sacrifice the design describes, with the revive
reserved for surviving an opponent's hit. Absent that over-performance, no change ships.

*2) Property.* This is risk/reward and flavor, plus the power-direction guardrail. It restores the tension the
design intends: the grudge should cost you the mon, and the revive should be your reward for enduring a real hit.
Right now the two combine into a nearly costless debuff, which is neither a real sacrifice nor a real survival
tool. Splitting them makes each mean what it says.

*3) Why.* The revive-refunds-the-grudge interaction is almost certainly unintended, since the design text calls
Eternal Grudge a self-KO and Rise From The Grave a way to survive a fatal hit. Splitting them restores both
intents and trims the free-debuff power in a single, surgical change. It bites only the degenerate line and
leaves the honest sacrifice case untouched. That precision is why it beats a blunt debuff nerf.

*4) Better alternatives?* We could shrink the debuff from 50/50 to something smaller, or add an explicit
once-per-game cap on Eternal Grudge. Both are ways to reduce the move's ceiling. Neither is as targeted as
cutting the revive refund, and each has a cost the surgical option avoids.

*5) Their tradeoffs.* Shrinking the debuff weakens the signature everywhere, including the honest sacrifice, so
it over-corrects. An explicit once-per-game cap barely matters, because the self-KO already limits how often the
move can fire. Cutting the revive refund is the surgical option, because it only removes the free-debuff synergy
while leaving the intended sacrifice play whole. So it's the least collateral change of the three.

*6) Still hold it?* Weakly, and the data has pushed it toward "no." The piloted grudge didn't over-perform, so
the win-rate case for a nerf hasn't materialized. It stays in the drawer unless a smarter grudge rule
over-performs, which now looks unlikely on the first pass.

*7) Amend.* Keep it gated behind the data: pilot first, measure, and apply this only if Ghouliath leaves the
band. If it does ship, re-check that the grudge still fires as a real sacrifice at a reasonable rate, so the
identity survives the nerf. The goal is a mon that plays its suicide-lead line, not one that stops using the
grudge because the sacrifice is now real.

*8) Empirical hook.*
- After the pilot fix, if the win rate is out of band, apply the no-refund-on-self-KO change and re-run.
- Confirm it settles Ghouliath back into the band while still letting the grudge fire as an intended, unrefunded
  sacrifice at a reasonable rate.

*Summary:*

**Ghouliath — above band (55.3%); leave the moves, refine the pilot, guardrail shelved.**
- *Findings:* Above band, carried by durability (Defense and Special Defense both 202) plus Rise From The Grave's
  second life plus Infernal Flame's burn chip — not by damage, since offense is only 157/151. It wins on a
  generic Infernal Flame (71/68%) + Osteoporosis (25/24%) line, while the signature Eternal Grudge is dead (1/2%)
  and Wither Away is low (2/5%). This is an identity gap, not a power gap.
- **No move change — but the "unpiloted, not weak" read is now in doubt.** The override pass (fire Eternal Grudge
  on any lethal turn) moved usage 1% → 13% and did **not** over-perform: 54.5% vs 53.8% hard (a wash, Δ +0.7).
  So the naive grudge line isn't a hidden buff — probably because the Temp debuff is shed by a switch while the
  revive fires either way.
- **Guardrail — shelved.** Rise From The Grave no-longer-refunds-a-self-KO was premised on the grudge
  over-performing; the data doesn't support that, so it's likely unnecessary. Hold it only for the case where a
  *smarter* grudge rule (fire only when the opponent can't switch to shed the Temp debuff) over-performs.
- *Validation gate:* naive grudge-on-lethal is measured (54.5% vs 53.8% hard, flat). Next: a targeted grudge
  gate (opponent can't switch away). If even that doesn't beat the generic line, Eternal Grudge is genuinely
  marginal, not just unpiloted.
- *New moves:* none.

> **[CPU gap]** The naive rule — fire **Eternal Grudge** on any turn Ghouliath would be KO'd — tested *flat*,
> not a gain (54.5% vs 53.8%), because a droppable Temp debuff for your last action doesn't help when the
> opponent can just pivot. The refined rule: fire Eternal Grudge only when Ghouliath is about to be KO'd,
> the revive is available, **and** the opponent can't immediately switch to shed the debuff (their last mon, or
> trapped). Lower-priority rules: use **Wither Away** to spread Panic in long grinds, and treat the revive as a
> resource to spend deliberately, not a passive backstop.

>> Is this true? If the opponent was going to switch, then we shouldn't use Eternal Grudge. Ideally we test it under conditions only when we think it's likely (either through first peek or by analyzing the situation) we will be KOed.

> **[Predicted]** The "self-KO is nearly free" argument leans entirely on the revive being available when you'd
> want to grudge. But Rise From The Grave fires on the first KO, and Ghouliath is a lead that trades early — how
> often is the revive actually still in hand at the moment you'd fire Eternal Grudge, versus already spent on a
> normal death? If it's usually spent, the grudge is a real sacrifice most of the time and the whole "nearly
> free" framing softens. That availability rate should gate the conclusion, not sit as a caveat inside it.

> **[Predicted]** I'm wary of manufacturing a nerf on a mon that's fine. If the pilot fix pushes Ghouliath to
> 60%+, we've created a balance problem where there wasn't one, purely to satisfy a fantasy that the mon wins
> fine without. What's the real cost of the suicide-lead identity staying dormant if Ghouliath is already above
> band? Maybe the honest answer is to leave it and note the identity as aspirational, and not touch the pilot at
> all.

> **[Predicted]** Wither Away is low at 2/5% and you waved past it — it inflicts Panic on both mons, which is a
> stamina drain that should matter more on a bulky mon built to win long games. Is it actually bad, or is it a
> second unpiloted setup piece like Eternal Grudge? And Grave Affliction is an unlock-6 move that never enters
> this analysis; are we ignoring the progression layer, where the "real" Ghouliath kit might differ from the
> level-0 default the arena tests?

---

## Inutia — 44.3% (below-band avg, but a piloting floor: 52.0 hard / 36.6 greedy)
Faith, id 1. A fast, bulky, low-offense pivot: HP 351, Speed 229, Defense 189, Special Defense 192, but only
ATK 171 and SpATK 175. Its ability, Interweaving, shaves the opponent's active ATK by 15% on swap-in and their
SpATK by 15% on swap-out (both Temp), so it's a hit-and-run debuffer that's paid to keep pivoting. The arena
splits hard: hard plays it as a mono-Big-Bite attacker (84%) and reaches 52.0%, while greedy spams Initialize
(73%), never completes the handoff, and floors at 36.6%. The intended weave — pivot in and out debuffing, pass a
boost, drop a hazard — never appears.

**[Thing] The 42% average is a piloting floor, not weakness — the 15-point hard/greedy gap says so.**

*1) Reason.* 42.2% is below the band, but that average hides a 15-point split between the two pilots: 52.0% under
hard and 36.6% under greedy. A mon whose win rate swings 17 points on who's driving it is not a fixed-strength
mon; it's one that neither pilot plays the way it's built. So the headline number is a piloting artifact before
it's anything else. That is exactly the floor rule 3 warns about.

*2) Why I know it.* The move-usage split explains the gap cleanly. Hard plays Big Bite 84% of the time — a plain
mono-attacker line — and lands at 52.0%, which is in band. Greedy spams Initialize 73% of the time, casts it on
Inutia and never pivots to complete the pass, and floors at 36.6%. So the low half of the average is one pilot
setting up and never cashing in, not a weak kit.

*2.5) Why isn't what we have working.* The average is dragged down by greedy's mispiloting, not by Inutia losing
on its merits. Under a pilot that simply attacks, Inutia is already in band, which means the raw kit clears the
bar. The failure is that neither pilot plays the pivot-and-pass identity the kit is designed around, so its
actual ceiling is untested. The number we can see is a floor for "just attack," and the interesting line is
invisible.

*3) Uncertain?* The real unknown is where a pilot that plays the weave-and-pass line lands. The hard number is a
floor for mono-attacking, and the intended line could sit above it, or it could snowball, or it could even be
worse than just attacking. Only the override, driving Initialize into a pivot into a partner's hit, can tell.
That is the single measurement this whole section waits on.

*4) Validate?*
- Add an Inutia override script (base HP 351): Initialize on a safe entry, then Hit and Dip to pivot and pass,
  then attack — done, and now runnable via `mon-data.ts --strategies override`.
- Read the piloted win rate against the ~50% band centre: reaching the band means the kit is fine and underused;
  landing below it (or below hard's own mono-attack line) means the weave is actually worse than just attacking.
- Separate the regimes: check whether the pivot line beats mono-attacking against bulky opponents (where the
  Interweaving debuffs and the pass matter) and loses the race against fast attackers.
- The pivot target is engine-picked, not frailest-partner-aware, so read this as "does weaving beat attacking,"
  and flag that the true pass ceiling needs a target-aware override extension.

*5) What would change my mind.* If the piloted weave lands near or above band, Inutia is a piloting-and-dead-slot
problem, not a power one, and no raw buff is warranted. If it stays below band even when piloted well, then the
low offense really is holding it down and it needs power. The override number decides between those two, and
nothing else does.

*6) Easy to test?* The screen and the mechanics are already in hand — the split is measured and the kit is a
source read. The piloted number needs the override run, which now exists and just needs the Inutia script (added
above). So this is medium-effort and unblocked, gated only on the run finishing.

*7) Simulated result — override pass confirms the floor.* The weave-and-pass script (Initialize on a safe entry,
then Hit and Dip to pivot, then attack) moved Initialize to 21% and Hit and Dip to 30%, and Inutia scored 49.3%
(250-game override pass) — up from the 44.3% average and squarely in the band, right at the ~50% target. So the
intended line lands where a healthy mon should, which confirms the piloting-floor read: Inutia isn't weak, it's
underpiloted, and the below-band average was the greedy floor. No overshoot appeared, but the script's pivot
target is engine-picked rather than a hand-chosen frail partner, so the pass ceiling is still untested.

*8) Consistent with (1)?* Yes. This is a piloting floor on a mon that's already in band under one pilot, and the
whole question is what the intended line actually does once someone plays it.

**[Thing] The weave identity is unpiloted, and Chain Expansion is a dead slot on top of it.**

*1) Reason.* Inutia's whole kit is built to reward pivoting, and none of it gets played. Interweaving debuffs on
both swap-in and swap-out, Hit and Dip is a damaging pivot, and Chain Expansion heals Inutia's own switch-ins
while chipping the opponent's. Yet Chain Expansion sits at 1/3%, Hit and Dip at 9/17%, and the Interweaving
swaps are never sequenced into a plan.

*2) Why I know it.* I read the contracts rather than the flavor text. Interweaving applies a Temp −15% ATK on
swap-in and a Temp −15% SpATK on swap-out to the opponent's active mon. Chain Expansion is a 4-charge global
hazard that heals the owner's switch-ins for 1/8 of max HP and deals escalating damage (1/16 → 1/8 → 1/4) to the
opponent's switch-ins. Both mechanics pay out exactly on the pivoting the CPUs refuse to do, which is why they
read as dead.

*2.5) Why isn't what we have working.* Two failures stack here. The pivot line is multi-turn setup that a myopic
evaluator skips, and Chain Expansion is worse still — it pays literally nothing on the turn you cast it, since
all its value is future switch-ins. A 1-ply pilot scores that as a wasted turn, and even a human needs a plan
that spans several switches before it pays. So the move is both unpiloted and genuinely slow.

*3) Uncertain?* The open question is whether Chain Expansion is merely unpiloted or actually too weak to justify
a turn, and whether the pivot line is strong enough to carry Inutia's low offense. The heal is only 1/8 per
friendly switch-in and the opponent-chip starts at 1/16, which are small numbers. So I suspect the hazard is
underpowered even when piloted, unlike the pass, which I think is only unpiloted.

*4) Validate?*
- Statically, the numbers are read: heal 1/8 max HP per friendly switch-in, opponent chip 1/16 → 1/8 → 1/4,
  4 charges total, 1 stamina to arm.
- In the override, cast Chain Expansion early and log how much heal and opponent-chip it actually collects over a
  game, since that total is the move's whole payoff.
- Compare an Inutia line that arms Chain Expansion against one that doesn't, holding the rest of the pivot line
  fixed, and read the win-rate delta attributable to the hazard.
- If the collected value is small even when piloted, the move needs a buff, not just a pilot — which separates it
  from Initialize.

*5) What would change my mind.* If arming Chain Expansion and pivoting turns Inutia into a real tempo engine that
out-values mono-attacking, then the pieces are fine and only need a pilot. If the hazard collects almost nothing
even when played correctly, it's the one genuine move-quality target on the kit. My prior is that the pass is
unpiloted-not-weak and the hazard is actually weak.

*6) Easy to test?* The mechanics are already read, and the piloted value drops out of the same override run as
the pass line, so there's no extra tooling. The only cost is threading Chain Expansion into the Inutia script and
logging the collected heal/chip. That's a small instrumentation add over the existing hook.

*7) Simulated result.* I expect the pivot-and-pass line to add real value from the Temp debuffs and a completed
pass, but Chain Expansion to stay marginal because its per-switch-in payoff is small. So the likely split is:
keep and pilot the pass, rework the hazard.

> "Pivot-and-pass" is an example of a condensed verbiage I want to avoid.

*8) Consistent with (1)?* Yes. It refines the first block — the piloting floor is real, but layered on top is one
slot (Chain Expansion) that's probably weak on its own, not just unpiloted.

**[Property] Fix the pilot first, keep the pass, and measure before buying any raw power.**

*1) Opinion.* Inutia's average is below band, but its hard number is in band, so the first move is a pilot that
plays the weave-and-pass, not a raw buff. Keep Initialize as-is, because the data says it's mispiloted rather
than oppressive. Only if the piloted line stays below band does Inutia actually need power.

*2) Property.* This is meta and progression — restoring the pivot identity — with the power direction held
contingent on the override number. It deliberately avoids the reflex of buffing a below-band mon, because the
split says the mon may already be fine. So the property is "identity plus measurement," not "power."

*3) Why.* Rule 1 buffs below-band mons, but with the caveat that a mon already in band under a competent pilot
gets an interesting-but-neutral fix instead. Inutia is precisely that caveat: 52.0% under hard means it isn't
weak, so a blind offensive buff risks overshooting. And the snowball fear about Initialize is falsified by the
data — the pilot that casts it most (greedy, 73%) wins least (36.6%) — so the pass is a completion problem, not
a power problem.

*4) Better alternatives?* We could buff Inutia's offense to lift the floor directly, cap the Initialize transfer
to +30% pre-emptively, or leave the mon entirely and accept the pilot floor. Each is a different reading of the
42%. Only some of them survive the hard/greedy split.

*5) Their tradeoffs.* Buffing offense fights the design (Inutia is meant to be low-offense support) and probably
overshoots, since hard is already in band. Capping the transfer nerfs a move the data shows isn't winning, which
is backwards. Leaving it wastes the pivot identity. Pilot-plus-measure is the only path that respects both the
design and the split.

*6) Still hold it?* Yes — the data says measure, not swing. If the override lands in band, the change budget goes
to the dead hazard, not to raw power. If it lands below, then and only then do we revisit offense.

*7) Amend.* Lead with the override; keep Initialize untouched unless the completed pass proves oppressive; and
reserve the one real change for Chain Expansion, covered next. Hold the +30% transfer cap purely as a
contingency behind a genuine snowball result.

*8) Empirical hook.*
- Run the override weave-and-pass line and read the win rate against the ~50% band centre (and against hard's
  own mono-attack line, to see whether the weave adds anything).
- Separately, complete a pass into a frail attacker (once a target-aware override exists) and check whether it
  turns common 2HKOs into 1HKOs — the only thing that would justify the +30% cap.

**[Property] Rework Chain Expansion into the weave-enabler it's meant to be.**

*1) Opinion.* Chain Expansion is the dead slot, and the fix is to make it reward the pivot identity more sharply
rather than sit as a slow do-nothing. The cleanest version raises the opponent-chip on forced switches, or ties
the hazard to Interweaving so pivoting compounds. `design.md` itself says it "could be more of a threat," so
sharpening it is sanctioned intent, not invention.

*2) Property.* This is meta and synergy — the move should turn the weave into a real tempo engine, so that
pivoting isn't just a mild annoyance but a plan the opponent has to answer. It's the one move-quality change on
the kit, targeting the slot the data flags as dead. It stays within the two-change cap.

*3) Why.* Chain Expansion already pairs with the kit — heal on Inutia's re-entry, chip on the opponent's forced
switches — but its per-switch-in numbers are small (heal 1/8, chip starting at 1/16), so nobody spends a turn
arming it. Sharpening the chip, or making the hazard amplify Interweaving's debuffs, converts the pivot from an
annoyance into a threat. That's exactly the "situationally useful, synergistic" bar this pass is looking for.

*4) Better alternatives?* We could buff the raw hazard damage into a Stealth-Rock-style threat, make it a
persistent on-switch debuff, or replace the slot entirely. Each raises the hazard's impact a different way. They
differ mostly in how much they risk becoming oppressive.

*5) Their tradeoffs.* A big raw hazard risks the exact Stealth-Rock oppression `design.md` says it wants to
avoid, so that's out. A persistent debuff overlaps Interweaving and muddies the identity. Replacing the slot
throws away a piece that already synergizes. Sharpening its synergy with the pivot, without making it a
standalone threat, is the surgical option.

*6) Still hold it?* Yes, but gated behind the override showing the pivot line is worth enabling. If the weave
doesn't pay even with a better hazard, the problem is deeper than one slot. So this ships after the pilot number,
not before.

*7) Amend.* Keep the 4-charge cap as the built-in anti-spam limiter, and tune the chip numbers up rather than
bolting on a new mechanic. The goal is a hazard people arm because the pivot pays, not a second win condition.

*8) Empirical hook.*
- Mock the sharpened chip in the transpiled TS and script Inutia's pivot line in `chomp/sims`, confirming the
  per-switch-in payoff is now worth a turn.
- Re-run the override with the reworked hazard and read whether Chain Expansion's usage and Inutia's win rate
  both rise.

*Summary:*

**Inutia — below-band avg (44.3%), a piloting floor; fix the pilot, rework Chain Expansion, keep the pass.**
- *Findings:* 44.3% average hides a 15-point split — 52.0% hard (mono-Big-Bite, in band) vs 36.6% greedy
  (Initialize-spam, floored). A fast, low-offense pivot (Speed 229, ATK/SpATK 171/175) whose weave identity —
  Interweaving's −15%/−15% debuffs, Hit and Dip pivot, Chain Expansion hazard-heal — never gets piloted. Chain
  Expansion is dead (1/3%). The below-band average is a floor, not a verdict.
- **Chain Expansion → sharpen it.** (0 / 1 / Faith / Other; 4-charge global hazard, heals owner's switch-ins 1/8
  max HP, chips opponent's switch-ins 1/16 → 1/4.) Raise the opponent-chip or tie it to Interweaving so pivoting
  compounds, keeping the 4-charge anti-spam cap.
  - *Rationale:* it's the one dead slot and the natural weave-enabler; `design.md` sanctions making it "more of a
    threat," but as pivot synergy, not a standalone hazard.
- **Initialize → unchanged** (0 / 2 / Faith / Self; +50% ATK/SpATK, transfers to the incoming mon on switch-out).
  - *Rationale:* the snowball fear is falsified by the data — greedy spams it (73%) and loses (36.6%) — so it's
    mispiloted, not oppressive. Hold a +30% transfer cap only as a contingency if a completed pass proves
    oppressive under the override.
- *Power direction:* contingent, not a raw buff. The below-band average is a piloting floor; the override decides
  whether Inutia needs power or just piloting plus the hazard fix.
- *Validation gate:* the override weave-and-pass line is measured at **49.3%** (up from the 44.3% avg, right at
  the ~50% target), which confirms the piloting floor — so the fix is the pilot + Chain Expansion, not offense.
  Still open: a target-aware pass (pivot to the frailest partner) to test whether a completed pass overshoots.
- *New moves:* none.

> **[CPU gap]** Harder difficulties should complete the **Initialize** pass — cast it, then **Hit and Dip** to
> pivot to a frail partner — instead of casting it and staying in (greedy's floor). They should also lead **Chain
> Expansion** early to arm the hazard, and pivot in and out to stack **Interweaving**'s debuffs rather than
> mono-attacking with Big Bite. The current override script does the first of these; a target-aware pivot (pick
> the frailest partner) is the extension needed to test the pass ceiling.

> **[Predicted]** The 52.0% under hard is "just spam Big Bite," which isn't the weave either — so is the in-band
> hard number evidence the mon is fine, or just that a bulky plain attacker is mediocre-but-okay? The weave might
> actually be *worse* than mono-attacking, in which case the identity is the problem and no pilot fix saves it.
> The override's 49.3% only *matches* the plain line, so it hasn't shown the weave beats just attacking — the bar
> isn't clearing the band, it's out-performing hard's own mono-attack line.

> **[Predicted]** "Sharpen the chip" is vague — give me the actual number you'd change 1/16 → 1/4 to, and show it
> doesn't become the Stealth-Rock oppression the design explicitly avoids. And "tie it to Interweaving" risks a
> debuff-stack that's exactly that oppressive hazard by another name. What is the specific rework, in numbers?

> **[Predicted]** You keep Initialize on the grounds that greedy loses with it — but greedy loses with every
> setup move, so that's evidence greedy is bad, not that the completed pass is fair. The snowball test still
> needs the override completing the pass into a frail nuker and measuring whether it manufactures 1HKOs, not a
> hand-wave from greedy's floor. Until that runs, "keep it" is a guess.

---

## CPU strategy buff candidates (promote to munch)

Override lines measured against the `hard` baseline. Only **PROMOTE** rows raise the production CPU and should
be ported into munch's `MonConfig`; the rest are recorded so a tested-flat rule isn't re-proposed. This table
grows as each mon's override runs (mon sections are inserted above it).

| Mon | hard | override | Δ | winning rule | status |
|---|---|---|---|---|---|
| Aurox | 38.6 | 47.0 | **+8.4** | Iron Wall on a fresh, stamina-flush entry, then Bull Rush | **PROMOTE** (confirmed over 250 games) |
| Ghouliath | 53.8 | 54.5 | +0.7 | Eternal Grudge on any lethal turn | not a buff (flat — the naive rule neither helps nor hurts; try the refined "opponent can't switch to shed" gate) |
| Inutia | 52.0 | 49.3 | −2.7 | Initialize on entry → Hit and Dip pivot | not a buff (≈/below hard; an identity/design line, not a CPU gain) |

Deltas are from 250-game current-engine passes. **Aurox is the one confirmed PROMOTE so far** — porting "Iron
Wall on entry, then Bull Rush" into munch's `MonConfig` (`CONFIG_SWITCH_IN_MOVE` + `CONFIG_PREFERRED_MOVE`)
should lift its prod win rate ~8 points.
