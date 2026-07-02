# Design Q&A Discovery Pass

Generated as a companion to `docs/design.md` and the `design-pass` docs. Purpose: surface the
questions a game designer or player would ask after reading the mechanics as they actually exist in
source today, simulate a spread of plausible answers from the author (Owen) for each, and use the
*spread* — not any single guessed answer — to find the questions most worth the real author's time.
This doc does not answer anything on its own behalf. Every "simulated answer" below is a guess at a
plausible stance, written to explore the space of reasonable positions, not a claim about what Owen
actually thinks. Nothing here should be copied into `design.md` as-is — the point is the questions.

**Grounding sources**: direct reads of `Engine.sol` (turn resolution, `_computePriorityPlayerIndex`,
`_inlineStaminaRegen`, `_handleSwitch`), `AttackCalculator.sol` (damage formula), `Constants.sol`,
`DefaultValidator.sol`, `TypeCalcLib.sol` + `drool/types.csv`, `drool/moves.csv` + `drool/abilities.csv`
(full roster), several mon contracts read in full (`Baselight`/`Loop` for Iblivion,
`RiseFromTheGrave`/`EternalGrudge` for Ghouliath, `PreemptiveShock` for Volthare, `Facets.sol`), plus
three research passes: one summarizing `docs/generated/design-pass.md` + `design-pass-v2.md` (the prior
per-mon balance pass and its `[Predicted]`/`[Addressed]` layer), one auditing the matchmaking/ranking
layer (`DefaultMatchmaker.sol`, `SignedMatchmaker.sol`, `BattleOfferLib.sol`, `PackedTeamStore.sol`),
and one doing a full-roster kit sweep (every mon's move + ability contract against `moves.csv`/
`abilities.csv`) that surfaced several concrete code-vs-description mismatches folded in below.

**A roster-wide architecture fact worth stating up front**: there is no same-type-attack bonus (STAB)
anywhere in `AttackCalculator.sol` — a mon's coverage moves cost nothing relative to its own-type
moves except whatever secondary effect differs. The "coverage vs. own-type" tension design.md
describes is really a secondary-effect/stat-allocation tension, not a numeric one.

---

## The 20 questions, at a glance

1. Should starting stamina be below max (3-4 of 5), per design.md's own musing?
2. Should Rest get more identity than "+1 stamina, nothing else"?
3. Switching is free, always-first, and "sacrosanct" per prior design-pass reasoning — is that blanket rule still right, no exceptions?
4. Metal resists 5 types, is weak to only 3, and sits on exactly one mon (Aurox) — intentional concentration or a gap?
5. Loop turns out to be gated once-per-game (not freely repeatable as design.md's own note implies) — did the author know that, and is the Renormalize-to-recharge combo the right shape for it?
6. Eternal Grudge's self-KO triggering Rise From The Grave — the debuff-stacking angle was measured and falsified; is the revival-banking angle still worth a look?
7. Is "self-damage as investment" (Grudge, Bull Rush, Foul Language, Dual Shock) a deliberate signature axis, and should more mons get one?
8. Should hard CC (Zap's turn-skip, Sleep) be costlier than damage-status (Burn/Frostbite) given the tempo swing?
9. Crit is 1.5x, not 2x — does a guaranteed-crit tool (Nine Nine Nine) need a bigger number to be worth a turn?
10. Design-pass v1 explicitly deferred on Malalien ("tax it only if still top pick after other reworks ship") — is it time to revisit?
11. Move-unlock-by-level exists and the balance-testing pipeline can't see gated moves at all — fix the testing gap first, the fairness gap first, or both at once?
12. Gorillax's Angery counter uses strict equality and can get permanently stranded above 3 stacks — bug to fix regardless of balance, or was the strictness intentional?
13. There is no ELO/ranking system anywhere — is one coming, or does meta-health stay a designer-driven (sim + playtest) process indefinitely?
14. Team selection is asymmetrically blind (whoever accepts a signed offer sees the proposer's real team first) and full rosters are publicly enumerable at all times — intentional or a gap?
15. Doubles and/or bigger team sizes — which format expansion (if either) is actually worth pursuing at a 13-mon roster?
16. The kit sweep found several CSV/code mismatches (Embursa's Q5 never actually applies the Burn its own description promises, plus three other numeric mismatches) — does `validateMoves.py` check behavioral claims at all, and is closing that gap worth doing before the next balance pass?
17. How much move-level RNG survives if prediction-market/spectator stakes ever attach to match outcomes?
18. Is gacha purely about roster access/breadth rather than raw power, and is preserving that distinction important?
19. Is the streak/quest daily-engagement design in tension with the "not a job" philosophy in `stomp_intro.md`?
20. Only 3 of many design-pass predictions were ever actually closed out with a measured run (1 confirmed, 2 falsified) — is that an acceptable rate, or does the process need a harder gate?

---

## Full analysis

### Q1. Starting stamina below max?

**Grounding.** Every mon has `stamina: 5` (`Constants.sol: DEFAULT_STAMINA = 5`; confirmed uniform across `SetupMons.s.sol`). Regen is +1 to both active mons at round end, plus +1 more to a mon that explicitly Rests (`_inlineStaminaRegen`, `StaminaRegenLogic._isRestingMove`). Design.md, verbatim: "giving mons a starting stamina of 3 or 4, while keeping the maximum at 5... opens up the decision tree of the early game."

- **A1**: Yes — start low, front-load the interesting decision instead of stapling it to the end of a game that's already mostly decided.
- **A2**: Skeptical it fixes anything — regen still catches everyone back up to full in a few turns; the deadline moves, it doesn't disappear. Look at regen rate, not starting value.
- **A3**: Wrong lever entirely — if a kit is all 2-3 stamina moves, stamina never binds regardless of starting value. Fix the cost distribution of moves themselves.
- **A4**: Worried about collateral damage — a 4-stamina move becomes dead-on-arrival turn 1 for a mon starting at 3, asymmetrically punishing whichever mon happens to have the priciest opener.
- **A5**: Reframe — the real problem is stamina rarely swings the *matchup*, only the *timing*, since it drains symmetrically. More asymmetric tools (Vital Siphon's steal, Somniphobia's punish-on-gain) matter more than the starting number.

**Variance: HIGH.** Five genuinely different diagnoses (starting value / regen rate / cost distribution / turn-1 legality risk / symmetry). This is also the question design.md already poses to itself without resolving — worth closing the loop.

---

### Q2. Should Rest have more identity?

**Grounding.** Design.md floats two fixes: empowered follow-ups after Resting, or (via the Xmon section) a chance for Resting itself to inflict Sleep.

- **A1**: Empowered-follow-up is the best of the floated ideas — forward-looking payoff, and any mon's kit could adopt the pattern without a new global system.
- **A2**: Reward is the wrong shape — if Resting is strictly good, it becomes the new correct default the same way full starting stamina did. Make it risky (Xmon's idea), not rewarding.
- **A3**: Leave it alone — not every action needs a wrinkle; the boring safe option is what gives the flashy options something to be measured against.
- **A4**: Mon-specific, not universal — a handful of mons (Embursa, Nirvamma) already get Rest-interactions; touch the base action for everyone and the blast radius is the whole game at once.
- **A5**: Rest is a symptom, not the disease — it looks unrewarding because the competing options (attack/switch/apply pressure) are too reliably correct. Fix those, and Resting becomes a real fourth option instead of a fallback.

**Variance: HIGH.**

---

### Q3. Is the "switching is sacrosanct" blanket rule still right with no exceptions?

**Grounding.** New finding from the design-pass summary: this is already an explicit, repeatedly-invoked value in the prior pass, not just my inference — cited by name against a Ghouliath debuff-persistence idea, a bigger Inutia hazard ("the exact Stealth-Rock oppression `design.md` explicitly avoids"), and built structurally into Aurox's new Bull Trap (switch always escapes, reusing the same exemption Sleep's `setMove` uses). Mechanically, switching is genuinely free: `SWITCH_PRIORITY = 6` always beats `DEFAULT_PRIORITY (3) + up to 3`, and no stamina is deducted for it (`Engine.sol` `_handleSwitch`).

- **A1**: Reaffirm with no exceptions — a blanket rule's value is in being reliable enough that players don't re-derive it per matchup; any tax makes every status/hazard quietly stronger by default.
- **A2**: The rule is right for forced (post-KO) switches, but voluntary pivot-chaining (Hit and Dip → fresh attacker → Round Trip) is a different case that was never meant to be covered by "don't punish retreating."
- **A3**: No exception needed — Hit and Dip (2 stamina) and Round Trip (1 stamina) already aren't free; a switch-tax on top would double-charge the same decision.
- **A4**: Agree with the rule, but flag that the "protect status counterplay" reasoning was never actually arena-tested against a pivot-specific tax — trusting a reasoned-through rule isn't the same as a measured one.
- **A5**: Keep every individual switch free, but bound the *loop* structurally (e.g. a cooldown on reusing a switch-out move) rather than economically.

**Variance: MEDIUM-HIGH.** Mostly reaffirms the existing precedent, but genuinely splits on whether chain-pivoting is a real exception and what mechanism would carve it out.

---

### Q4. Metal's concentration (5 resistances, 3 weaknesses, on exactly one mon)

**Grounding.** Computed directly from `drool/types.csv` (14x14 chart, `TypeCalcLib.sol` confirms encoding: 0=immune, 1=neutral, 2=super-effective/2x, 5=resisted/0.5x). Metal: weak to 3 types, resists 5, immune to 0, and only super-effective against 1 type as an attacker — the most defensively lopsided type in the chart. Exactly one mon (Aurox) is monotype Metal; no other mon carries it as primary or secondary. Relatedly, dual-typing itself is rare roster-wide: only Ghouliath (Yin/Fire), Iblivion (Yang/Air), and Volthare (Lightning/Cyber) have a second type; the other 10 of 13 are monotype.

- **A1**: Intentional, and good — one dominant wall on one mon keeps the type an answer to a specific game plan rather than a mandatory tax everyone pays if it were spread across three mons.
- **A2**: More accident than plan — the chart was built for asymmetry first, mon assignments second. On reflection, a second Metal-adjacent mon would be healthy so the type isn't a single point of failure.
- **A3**: Wrong axis to worry about — Metal's 1-type offensive coverage matters more than its defensive concentration; very few mons can lean on Metal *offensively* regardless of how many defend with it.
- **A4**: Fix via dual-typing an existing mon rather than designing a new one — Pengym already uses Metal-typed moves (Deadlift) despite being pure Ice; Ice/Metal would spread the profile cheaply.
- **A5**: Skeptical it matters much in isolation — type effectiveness is one multiplier among several, and Aurox is already slow/low-offense enough that being hard to hit for weakness damage may just be compensating for its other costs, not overperforming.

On the dual-typing ratio specifically, answers split further between "concept-driven, no target ratio" (a second type should only appear when the mon's identity calls for covering a real weakness, per Ghouliath/Volthare) and "under-used as a tool to patch the roster's many all-neutral matchups now, while the roster is still small enough that individual assignments matter a lot."

**Variance: HIGH.** Genuine fork between "intentional," "accidental oversight," "wrong axis," "fix via dual-typing," and "doesn't matter much."

---

### Q5. Loop is gated once-per-game — did the design intend that, and is Renormalize the right way to recharge it?

**Grounding.** `Baselight.sol`, read in full: starts at 1 on first switch-in (ever, per mon, via a `globalKV` flag), +1 at every `RoundEnd` up to a max of 3, entirely time-driven with no condition. `Loop.sol`: 1 stamina, up to +40% to all 5 stats (Attack/Defense/SpAtk/SpDef/Speed) at level 3, Temp (cleared on switch-out). Design.md, verbatim: "a free Baselight point at the end of every turn may be a bit too programmatic... Currently, Loop is very strong... using it after a swap means it's already at Baselight level 2 in many cases."

**Correction from the full-roster kit sweep**: Loop is not freely recastable as Baselight climbs. `Loop.sol` sets a `_loopActiveKey` flag to 1 on first use, and that flag is **never cleared anywhere except by Renormalize's explicit `LOOP.clearLoopActive()` call** — not by switching out, not by time, not automatically. So Loop is a one-time buff per game unless the player also spends an entire separate turn (Renormalize: 0 stamina, priority −1, resets Baselight to 3 *and* re-arms Loop, but also clears all of Iblivion's own stat boosts, including a still-active Loop buff) to recharge it. Design.md's note reads as though Loop is a lever that gets recast turn over turn as Baselight refills — the real mechanic is closer to "one big buff per game, rechargeable at the cost of a whole extra move that also wipes your current boosts."

- **A1**: Didn't have the once-per-game gate in mind when writing that note — was picturing Loop as recastable whenever Baselight ticked up again. That's a much more contained, one-shot-feeling payoff than the note worried about; wants to re-ask the strength question fresh now that the real shape is clear.
- **A2**: Likes it better now that it's clear — Loop-then-later-Renormalize-then-Loop-again is a real two-move combo with its own tempo cost (a whole extra turn spent on Renormalize doing nothing offensively), a more interesting resource story than "free stacking buff." Wouldn't change the gate, just fix the notes.
- **A3**: Doesn't love that something this load-bearing (whether Loop can be used at all) is invisible to a player without reading the contract — wants the UI to clearly surface "already used, needs Renormalize to reset" rather than a move that mysteriously stops working.
- **A4**: Reconsiders whether Renormalize should be required at all — the "spend a whole separate move to get your buff back" pattern may not have been intended; would consider letting Loop recast for a smaller marginal top-up instead of a hard one-time gate, with Renormalize's value resting entirely on its boost-clearing effect.
- **A5**: More worried about the documentation problem than the design problem — if design notes described the wrong mechanic with confidence once, wants a pass that checks prose against actual current contracts before trusting any existing balance take at face value.

**Variance: HIGH.** A case where the author's own stated understanding may not match the shipped mechanic — discovered by reading source, not by arena data. Directly demonstrates the value of the "measure before deducing" habit for future design work.

---

### Q6. Eternal Grudge → Rise From The Grave: is the revival-banking angle still open?

**Grounding.** Read `EternalGrudge.sol` and `RiseFromTheGrave.sol` in full. Eternal Grudge (priority `DEFAULT_PRIORITY + 1`, 2 stamina, Self) halves the opponent's Attack/SpAtk (Temp) and then calls `dealDamage` on its own user for exactly lethal — a voluntary self-KO. `RiseFromTheGrave.onAfterDamage` fires on *any* KO of its holder, opponent-inflicted or self-inflicted (`engine.getMonStateForBattle(...IsKnockedOut) == 1`, no distinction), converting from a per-mon effect into a 3-turn global countdown that revives the mon at 1 HP. So the first Eternal Grudge use, on a mon that hasn't triggered the ability yet, banks its own revival on its own schedule — design.md's "fire it off twice per game" line.

**New finding (design-pass agent):** this exact interaction was investigated. An override run testing "script Grudge-on-lethal" found the "nearly free self-KO" framing **falsified** — usage moved 1%→13% but win rate was flat (54.5% vs. 53.8%, "a wash"), because the Temp Attack/SpAtk debuff gets shed by the opponent simply switching before it's collected. The planned guardrail nerf was shelved. But three `[Predicted]` critiques on this exact mon in `design-pass-v2.md` were left with **no `[Addressed]` response**: how often the revival is actually still banked at the moment you'd want to use Grudge (versus already spent on an ordinary death), and whether manufacturing a guardrail nerf on an otherwise-healthy mon is worth it at all.

- **A1**: Closed — if the debuff-stacking doesn't overperform, the interaction is a non-issue; the only reason banking early would matter is if it enabled something broken, and the measurement says it doesn't.
- **A2**: Still worth a narrow, non-numeric look — win rate answers "is this broken," not "does this feel right"; whether the revival read as earned-by-tanking-a-hit versus manufactured-on-command is a fairness/flavor question the arena number can't answer.
- **A3**: One more test, then closed either way — check whether real (non-scripted) opponents actually punish the 3-turn revival window hard enough that the line isn't worth taking on purpose; if they do, done.
- **A4**: Closed for balance, open as a taste/precedent call — satisfied it's not overpowered, but hasn't decided whether a self-KO move bootstrapping its own death-triggered ability is the "right kind of clever" independent of the numbers.
- **A5**: Mostly closed, but write down the general ruling — self-inflicted KOs trigger on-death abilities the same as opponent-inflicted ones; treat that as default for any *future* mon pairing a self-KO move with a death-triggered ability, rather than re-litigating per mon.

**Variance: HIGH.** Good split between "fully done," "one more empirical check," and "it's no longer a balance question, it's a precedent/taste question" — exactly the kind of question that benefits from the real author closing it out explicitly rather than leaving it as an unaddressed `[Predicted]` block indefinitely.

---

### Q7. Is "self-damage as investment" a deliberate signature axis?

**Grounding.** Eternal Grudge (full self-KO), Bull Rush (140 power, 20% max HP recoil to self, per `moves.csv`), Foul Language (60 power, half of damage dealt taken as recoil), Dual Shock (deals damage, inflicts Zap — full turn-skip — on self, to Overclock the team). Four different mons, four different currencies of self-harm (permanent-feeling KO / flat % max HP / damage-proportional / a full status condition).

- **A1**: Yes, it's the identity — Pokemon mostly treats recoil as a downside bolted onto a strong move rather than a deliberate axis; every mon should get at least one "pay yourself, not just stamina" move.
- **A2**: Incidental, not a pillar — each example solves a local problem (a strong move needs *some* downside); branding it retroactively as a unifying theme risks forcing it onto mons where it doesn't fit.
- **A3**: Good idea, not yet consistent enough to extend — three completely different currencies of self-harm with no shared exchange rate; decide on one currency (HP%, status, or genuinely-varies-by-mon) before adding more.
- **A4**: Actually want fewer, not more — worried recoil-heavy kits make big numbers look "balanced" on paper while being unpleasant to pilot; a 140-power move that also costs 20% of your own max HP is still a 140-power move most of the time.
- **A5**: Concept-first, not axis-first — self-damage fits mons whose flavor is already about sacrifice or excess (undead Ghouliath, tank-that-thrives-on-damage Aurox); forcing it onto Sofabbi or Nirvamma because the axis is liked would be flavor working backwards from mechanic.

**Variance: HIGH.**

---

### Q8. Should hard CC be costlier than damage-status?

**Grounding.** `moves.csv`: Electrocute (Zap, "skips its next turn") lands at 10% effect chance; Set Ablaze (Burn) lands at 30%. Contagious Slumber puts *both* mons to sleep (self-cost baked in). Somniphobia punishes stamina-gain for 4 turns, stacking. New finding: the design-pass summary confirms Xmon's Somniphobia rework (originally punished *any* stamina gain, including the universal passive regen, effectively firing every turn for both sides — a cross-cutting engine interaction exposed by one mon's analysis) already shipped and measurably changed its usage from 1%→32% under the `hard` CPU in the v2 data table.

- **A1**: Yes — a skipped turn is worth roughly a whole move, a bigger swing than Burn/Frostbite's DoT/stat penalty; noting Zap's chance (10%) is already lower than Burn's (30%) suggests this might already be informally handled.
- **A2**: No — Sleep and Zap already carry their own soft caps (Contagious Slumber's mutual cost, Zap's single-turn-only skip versus Pokemon's multi-turn sleep); no extra tax needed.
- **A3**: The imbalance is between mons, not between statuses — fix the free-switch escape valve (see Q3) and the CC-severity question mostly resolves itself, since escape cost is what actually determines how punishing CC feels.
- **A4**: Fix duration/chaining, not per-move chance — the real complaint is being CC-looped across multiple turns, not any single proc landing; cap chainability before touching individual numbers.
- **A5**: Genuinely unresolved without arena data — gut says CC matters less than it looks on paper because stamina and accuracy already gate it, but wants the sim to confirm before committing to a rule either way.

**Variance: HIGH**, including one explicit "need data first" answer, which is itself informative.

---

### Q9. Does a guaranteed-crit tool need a bigger multiplier?

**Grounding.** `AttackCalculator._calculateDamageCore`: crit is `CRIT_NUM/CRIT_DENOM = 3/2 = 1.5x`, not Pokemon's 2x. Nine Nine Nine (Ekineki): 1 stamina, 0 power, sets 90% crit rate for all moves next turn. New finding from the design-pass summary: this exact move was already arithmetically proven strictly dominated (1.5x from a spent turn always loses to two plain hits: `1.5 < 2`) and was **reworked** into a KO-count-scaling burst tied to Savior Complex; a "guaranteed crit on Sneak Attack" alternative was explicitly rejected for inheriting the same `1.5 < 2` problem.

- **A1**: 1.5x baseline is right (crit shouldn't define most turns), but a move whose *whole job* is enabling one is competing against just attacking twice — needs its own bigger number or an added effect to be worth a full turn.
- **A2**: Keep 1.5x everywhere — value should come from stacking with damage-triggered effects (Brightback's heal-on-damage, effect-accuracy checks needing damage > 0), not from a special-cased multiplier for one move archetype.
- **A3**: The stamina/scope pricing is the lever, not the multiplier — a full-turn, 0-damage setup for one hit next turn is the wrong shape regardless of the crit number; the fix already shipped (KO-scaling rework) rather than needing a global multiplier change.
- **A4**: The whole crit system might be undertuned — if 1.5x is deliberately lower than Pokemon's 2x, want to be able to articulate why; absent a clear reason, lean toward raising the baseline and re-testing rather than special-casing one move.
- **A5**: Skeptical guaranteed-crit tools should exist as a pattern at all — "remove the RNG from a later move" reads as a combo-enabler on paper but plays as a do-nothing turn, which cuts against the exact problem Rest already has (see Q1/Q2).

**Variance: HIGH.**

---

### Q10. Malalien: time to revisit the deferral?

**Grounding.** Design.md, verbatim: "Malalien is very strong as-is... Only a few mons or +priority moves can take it out, and it can usually 2HKO if not OHKO every mon." New finding from the design-pass summary: v1 explicitly punted rather than nerfing — coverage confirmed total (neutral-or-better on all 12 other types, super-effective on 5), the call was "watch-list... tax only if it's still the top pick *after every other mon's rework ships*" — a stated, conditional, roster-holistic trigger, not an immediate change. Several other mons' reworks have since been designed (Aurox validated +8.4 pts via override; Ghouliath, Inutia, Gorillax, Sofabbi, Pengym, Embursa, Volthare, Xmon, Ekineki, Nirvamma all got at least a lateral pass) — but none of this has been confirmed as *deployed* to production, only designed in docs.

- **A1**: Not yet — design-doc-shipped isn't the same bar as actually-live; wait for real deployment to production contracts/CPU configs, not just a design pass, before re-measuring the environment Malalien wins inside of.
- **A2**: Yes, now — a conditional deferral with no scheduled review point is how permanently-strong mons happen by default; put an actual date or milestone on it rather than letting "later" mean "never."
- **A3**: Right policy, wrong trigger variable — "have other mons been reworked" is a proxy for "is Malalien still the best answer to most teams"; check that directly with fresh arena data now, independent of roster-completion status.
- **A4**: Revisit, but commit to a specific lever and threshold in advance this time (e.g., Triple Think's 75% SpAtk boost, under a stated win-rate trigger) rather than producing a third open-ended deferral.
- **A5**: Don't touch the mon yet, but audit the *counter count* first — get an exact number of how many of the 13 mons currently beat it in a straight matchup rather than relying on 2-3 examples from memory; that number determines whether "a few answers exist" is an honest description or an undersell.

**Variance: HIGH.** Directly extends a stated-but-unexecuted trigger condition from the prior work — high actionability.

---

### Q11. Move-unlock-by-level: testing gap, fairness gap, or both first?

**Grounding.** `drool/moves.csv` has an `UnlockLevel` column; confirmed wired into `MonRegistry.sol` (comment: "lanes >= MOVES_PER_MON... unlock by level, see `MonExp._unlockLevelForLane`" — a real learnset system beyond the 4 battle slots, not CSV metadata only). Four moves currently gated at level 6: Ghouliath's Grave Affliction, Inutia's Sanctify, Malalien's Foul Language, Xmon's Invoke Taboo. New finding from the matchmaking research: no level-normalization exists anywhere in matchmaking — team proposals carry a team index and mon list, nothing about level parity. New finding from the design-pass summary: the arena/CPU balance-testing pipeline **only tests each mon's level-0 default kit** — the prior pass explicitly flags this as a scope gap it never resolved, meaning the tooling this project already leans on for balance conclusions has never evaluated these four moves at all.

- **A1**: Testing gap first — can't have an informed fairness opinion about content that's never been measured; don't know if the gated moves are worth grinding for at all yet.
- **A2**: Fairness gap first — even a mediocre gated move creates a "the grinder's mon can do something mine can't" perception problem independent of whether it's measurably strong; ship level-normalized ranked mode first, leave testing-completeness as backlog.
- **A3**: Same fix, actually — build the arena harness at (say) level 10 with all unlocked moves available; this produces the missing balance data *and* directly answers whether normalization is even necessary (if the gated moves are marginal, there's no fairness problem to fix).
- **A4**: Neither urgent yet — no ranking, no wager, minimal stakes per match today (confirmed: flat 2/1 gacha points win/loss); fixing fairness for a competitive mode that doesn't exist yet is solving out of order.
- **A5**: Testing gap first, but because it changes what "balanced" even means for 4 specific mons — suspects some gated moves (Grave Affliction reads like a finishing tool for a mon that otherwise can't clean up a crippled opponent) were designed as answers to base-kit gaps, meaning "balanced at level 0" may be systematically undercounting intended design for exactly the mons that have one.

**Variance: HIGH.** Nicely forks on sequencing — a decision that benefits from the real author's priorities, and directly touches the "automated discovery" tooling this whole exercise is meant to feed.

---

### Q12. Gorillax's Angery: a strandable counter — bug, or intentional strictness?

**Grounding (new, from the kit sweep).** `abilities.csv`: "Each time Gorillax takes damage, they get Angerier. At 3 stacks, they heal for 16.6% of max HP." The actual implementation checks for **strict equality** to 3 at `RoundEnd`, not `>= 3`. If Gorillax takes two or more separate instances of damage inside a single round (e.g., a multi-hit move landing, or a hit plus an end-of-turn status tick before the check runs), the counter can overshoot 3 — and since it only ever resets on hitting exactly 3, once it's past 3 it can mathematically never equal 3 again for the rest of that game. Design.md already flags "it doesn't seem to trigger often enough to be useful"; this looks like a concrete mechanical explanation that's a meaningfully worse problem than "rare" — a permanently dead ability slot from one unlucky round, not merely an uncommon one.

- **A1**: Clear bug, fix the comparison regardless of balance — nobody decided on purpose that the ability should be able to permanently break for the rest of the game from two hits in one round; fix to `>=` (or cap the counter) as a correctness fix, separate from any balance conversation after.
- **A2**: Wants to check whether the strictness was intentional anti-double-trigger protection first — if the worry was a multi-hit move double-firing the heal in one round, the fix needs to preserve "at most one heal per round" while still letting the counter settle at exactly 3 afterward, not just flip to `>=` and hope nothing else breaks.
- **A3**: Fix it — and update the mental model, since "can become mathematically incapable of ever triggering again" is worse than what the design note described ("doesn't trigger often enough"). Some games currently have a permanently dead ability slot purely from variance.
- **A4**: Fix it, but re-measure before deciding it needed a power buff at all — if the real issue was this stranding bug rather than the trigger threshold, the fix might be purely the comparison operator, no numeric buff required.
- **A5**: Before patching just this one, wants to know if any other mon's stacking counter (Baselight, Somniphobia, Night Terrors, Tinderclaws' burn degree) uses the same strict-equality pattern — if it's a copy-paste convention, worth one sweep instead of a one-off fix.

**Variance: MEDIUM-HIGH on approach, but high-confidence this needs a fix of some kind** — the live question for the author is whether the strictness was ever deliberate and how broadly to sweep for the same pattern, not whether to act.

---

### Q13. No ranking system anywhere — coming, or permanent?

**Grounding (new, from matchmaking research).** Grepped the whole repo for `elo|rating|ranking|leaderboard|mmr` — zero real hits in contracts, sims, or frontend. Opponents are matched by naming a specific address or posting an open offer anyone can accept (`DefaultMatchmaker.sol:76-122`, `SignedMatchmaker.sol:42-83`); `computeBattleKey` mixes in a replay nonce, not a skill metric. The only "opponent" concept in the game layer is the PvE-CPU `isWhitelistedOpponent` flag. There is no discovery/lobby/queue system anywhere — opponent-finding is entirely off-chain/social. Meanwhile design.md explicitly frames metagame health as a design goal: "What is an oppressive or reductive strategy, and how can I eliminate those?" — a question that, in the wild (as opposed to CPU arena sims), currently has no instrumented way to even be observed.

- **A1**: Coming, just sequenced late — ranking on top of an unbalanced or unfun game just produces a precisely-measured unfun experience; nail CPU-sim-driven balance first.
- **A2**: Not wanted, possibly ever — a ladder optimizes players toward the single most efficient strategy, close to the opposite of wanting team-building creativity; named-opponent/open-offer matches keep the game feeling social rather than MMR-grindy.
- **A3**: A soft signal, not real MMR — doesn't need rating math, but wants *some* visible signal (even a win/loss record) so an open-offer match isn't always a coin flip between a brand-new player and a veteran.
- **A4**: The CPU sim already is the ranking system, deliberately kept separate from live PvP — the arena is a controlled lab for balance, live PvP is social opponent self-selection; fine keeping those two systems permanently distinct.
- **A5**: Genuinely undecided, contingent on the prediction-market vision — if that ever ships, markets would want a legible skill signal to price a match confidently, which would force the issue regardless of any independent reason to build one today.

**Variance: HIGH.** Completely fresh ground — neither design.md nor the prior design-pass docs touch this at all.

---

### Q14. Asymmetric blind team selection + fully public rosters — intentional?

**Grounding (new, from matchmaking research).** In the production path (`SignedMatchmaker.sol`, explicitly marked as the production matchmaker in `DefaultMatchmaker.sol`'s own header comment), p0's team index is signed in plaintext as part of the EIP-712 offer (`BattleOfferLib.hashBattle`). Whoever accepts that offer — named or open — necessarily already holds and can read it, so they see p0's real team before submitting their own. There is no simultaneous reveal. Separately, `PackedTeamStore`'s `getTeam`, `getPlayerTeams`, `getOrderedLiveTeams`, and `getTeamCount` are all unauthenticated `external view` — anyone can enumerate any player's entire 16-team roster at any time, whether or not a battle is even proposed. So the only thing ever hidden, and only asymmetrically, is *which* of your already-public teams you'll use this match — not what teams you own. Design.md names "opponent prediction" as one pillar of the yomi it wants.

- **A1**: Intentional and correct — the yomi that matters is turn-by-turn (move choice, switch timing), not deck-building mindgames; competitive Pokemon itself often plays with fully public team sheets (VGC) or public Showdown teams.
- **A2**: A real gap, but only the ordering half — fine with rosters being public (closer to a deck archive than a secret), but the accept-side's structural always-moves-second advantage isn't a design choice, it's an artifact of the signing flow; wants simultaneous commit-reveal on the team index specifically.
- **A3**: A gap on both counts, roster-privacy the bigger one — anyone enumerating a full 16-team roster unprompted feels like a bigger, weirder hole than a temporary one-proposal-flow ordering advantage; would want at least opt-in roster privacy first.
- **A4**: Not costing anything today, revisit the moment stakes exist — with no ranking and no wager, "you saw my team first" isn't costing anyone anything real yet; revisit exactly when ranking or real stakes ship.
- **A5**: Surprised by the finding, not ready to rule — assumed this worked like simultaneous team preview; wants to sit with the fact that the mental model of the matchmaking flow was wrong before deciding whether it's actually bad.

**Variance: HIGH.** Concrete, surprising, and completely unaddressed anywhere in existing docs.

---

### Q15. Doubles vs. bigger teams — which format expansion is worth pursuing?

**Grounding.** Design.md flags doubles as WIP ("many moves will need to be updated to support more than 1 target"); confirmed zero multi-target code anywhere in `src/` (no `doubles`/`multiTarget` hits). 5v5/6v6 floated in the same paragraph. Roster is 13 mons — 6v6 alone would require ~46% of the entire roster on a single team.

- **A1**: Neither yet — grow the roster before growing the format; 6v6 at 13 mons means playing almost the whole card pool every game, and doubles needs a design pass of its own before it's worth building.
- **A2**: Doubles over bigger teams — genuinely a different kind of game (positioning, targeting) rather than a longer version of the same game; bigger teams mostly buy variance and length.
- **A3**: Bigger teams over doubles, purely for cost — `MONS_PER_TEAM` is already a parameter, so a 6v6 experiment costs nothing engine-side, while doubles needs nearly every move rewritten for targeting; a cheap experiment either confirms or kills the "need more depth" theory.
- **A4**: Both are the wrong axis — a draft format or a 1v1 gauntlet changes what kind of decisions matter (drafting/counter-picking) without touching per-battle rules at all, which might be the more interesting expansion.
- **A5**: Pursue doubles, but as a from-scratch second roster built around ally-targeting/redirection/spread damage — don't retrofit the existing 13, leave 4v4 singles exactly as tuned as it is today.

**Variance: HIGH.**

---

### Q16. CSV/code mismatches found across the roster — is this a tooling gap worth closing?

**Grounding (new, from the kit sweep).** Reading every mon's contracts directly against `moves.csv`/`abilities.csv` turned up four concrete mismatches: Inutia's Interweaving is coded as −15% Attack **and** −15% SpAttack (the CSV/ability text says "10%... 15%"); Aurox's Iron Wall heals 20% max HP on first activation (`INITIAL_HEAL_PERCENT = 20` in source; CSV/abilities.csv say "25%"); Sofabbi's Gachachacha KO odds are actually ~2.38% self-KO / ~1.90% opponent-KO — asymmetric and roughly half the documented "5%/5%," from an off-by-one in the modulo range; and, most substantially, **Embursa's Q5 never applies Burn at all** — the dev description says "Deals damage in 5 turns and Burns the enemy," but `Q5.sol` only calls `AttackCalculator._calculateDamage`, a helper with no effect/status parameter, so Embursa's signature delayed-damage move simply doesn't burn anyone. `processing/validateMoves.py` exists specifically to check contracts against the CSVs.

- **A1**: High priority — worried this means design commentary has been reasoning from wrong premises (Embursa's whole risk/reward story assumes Q5 burns the target, and it doesn't); wants `validateMoves.py` extended to check DevDescription keywords (Burn/Frostbite/Zap/Panic/Sleep/heal-percent) against a corresponding on-chain effect before trusting any further analysis.
- **A2**: Structural-only checking is fine for now — suspects `validateMoves.py` only checks numeric/enum fields because verifying free-text claims against arbitrary Solidity is close to building a mini interpreter; treats semantic checking as a real but expensive project, not a quick validator addition.
- **A3**: Fix the four found bugs directly this week rather than waiting on general tooling — a short, concrete list shouldn't be blocked on building a more general checker first; the tooling gap is real but shouldn't gate fixing what's already found.
- **A4**: Wants the check to live in the sims/arena layer instead of `validateMoves.py` — a battery of "does move X actually apply status Y" assertions run against the transpiled engine (which the harness already supports) would catch this class of bug more reliably than parsing English descriptions statically.
- **A5**: Most worried about what this implies for the *existing* design-pass corpus — if four mismatches turned up from one read-through of 13 mons, the two prior balance-pass documents likely inherited at least one wrong premise too (Embursa's rework was reasoned about its burn/heal loop); wants a mismatch sweep across the whole roster before trusting any existing balance conclusion, not just before writing new ones.

**Variance: HIGH.** Arguably the single highest-leverage new finding for "automated discovery" specifically — it means the corpus already used to make balance calls may have reasoned from at least one incorrect premise, independent of any new content being generated.

---

### Q17. RNG vs. prediction-market determinism

**Grounding.** Nearly every move has some form of RNG: `AttackCalculator._calculateDamageCore` rolls accuracy, ±volatility (~±10% typical), and crit chance from disjoint slices of one hash; most status-inflicting moves have an independent effect-accuracy roll. `stomp_intro.md`, verbatim, names "prediction markets that resolve on who wins a game" as part of the long-term vision. Confirmed (matchmaking research): no stake/wager mechanism exists in any contract today — this is purely forward-looking.

- **A1**: RNG is core, stays — real yomi needs real risk; a fully deterministic game reduces "reading the opponent" to solving a fixed-information problem once. Let markets price the uncertainty the way any prediction market prices any real-world variance.
- **A2**: Shrink the "unearned" variance only — accuracy checks and the ambient ±10% volatility roll reward nothing about reading the opponent, whereas crit/status chance are at least attached to a choice (which move, when); cut the former before touching the latter if stakes ever get real.
- **A3**: Doesn't matter yet — redesigning core damage variance to serve a hypothetical future integration is exactly the "design for the tokenomics instead of the game" failure mode from other web3 games; revisit only once markets are a real, shipping feature.
- **A4**: Depends on market granularity — a "who wins" market absorbs turn-level variance fine (like sports betting absorbs a bad bounce); a market on something narrower (exact turn count, whether a specific mon survives) would feel manipulated by RNG in a way that damages trust. Only worry about variance for the second kind.
- **A5**: The fix isn't less RNG, it's more legible RNG — commit-reveal + deterministic RNG-from-salts already means every roll is verifiable after the fact; the real work for a market-friendly game is exposing that verifiability, not cutting the variance the mechanics depend on.

**Variance: HIGH.** Directly ties the stated long-term vision to a concrete, current mechanical property.

---

### Q18. Gacha: access/breadth only, or does it quietly become a power axis?

**Grounding.** Confirmed (matchmaking research + Constants.sol): rolls cost points (16/roll), rewards are flat and non-staked (2 pts/win, 1/loss), base mon stats are fixed once owned. Facets (a real power lever) are gated behind exp/levels, which is gated behind playing — not behind the roll itself.

- **A1**: Yes, and preserving it is close to the most important property of the economy — power should come from skill/facets/play, never from roll luck, or this is pay/grind-to-win with extra steps.
- **A2**: Mostly true, but facets already quietly complicate the story — facets ARE a power lever gated behind time invested (exp/levels), so it's closer to "gacha decides access, *time* decides power" than "gacha decides access, *play skill* decides power" — a softer but real form of grind-to-win.
- **A3**: Breadth is the current truth for casual/ladder play, but there's likely a real audience (plausibly the same audience a prediction market would attract) that wants a mode where roster access is *also* equalized — a draft or shared-pool format so stakes never ride on gacha luck at all.
- **A4**: Not as clean a distinction as it sounds — not owning the one mon that answers a given archetype is a real disadvantage even if every individual mon is internally balanced, the same way missing one card is a real disadvantage in an otherwise-balanced card game. Roster breadth is a soft power axis whether or not that's the intent.
- **A5**: Likely self-resolving with scale — at 13 mons, missing one specific mon is a big deal; at 60 mons, most decks need a stable core plus a couple of situational picks, so "access, not power" becomes truer as the roster grows, independent of any rule.

**Variance: HIGH.**

---

### Q19. Streak/quest daily pressure vs. the "not a job" philosophy

**Grounding.** `Constants.sol`: `STREAK_FLAT_BONUS_MAX = 5`, `STREAK_GRACE_WINDOW = 36 hours`, `QUEST_REWARD_MULT = 2`. One quest active per day, evaluated against the *pre-rotation* quest so today's battle is judged fairly. `stomp_intro.md`, verbatim: "You cannot play-to-earn, win-to-earn, risk-to-earn... for a game. That is called having a job."

- **A1**: Intentional, and gentle enough to be fine — a missed day loses a flat +5 max bonus on top of a 2-point win, not a multiplicative loss, with a 36-hour grace window; "don't punish missing a day hard" is different from "no daily incentive at all."
- **A2**: Real tension, would cut it rather than compromise the stated philosophy — a streak is specifically the mechanic genre most associated with "feels like a job" (the Duolingo playbook); would rather find a non-streak-shaped way to reward engagement.
- **A3**: Tension is about framing, not math — the same numbers read as pressure ("keep your streak!") or as a bonus ("nice, bonus round today") purely based on UI presentation; workshop the client-side framing before touching the contract.
- **A4**: The daily quest is the bigger tension, not the streak — a streak just rewards logging in and playing; a specific daily quest with specific predicate conditions is closer to "play in the specific way I've decided today," a step further toward homework than a login bonus.
- **A5**: Can't be answered from the contract code alone — the real test is whether players who skip a day report feeling bad about it or just shrug, and that data doesn't exist yet; would ask players directly rather than deciding from the numbers.

**Variance: HIGH.** Directly pits two of the project's own stated values against each other.

---

### Q20. Prediction discipline: 3 closed-out predictions across ~2,350 lines of analysis

**Grounding (new, from design-pass summary).** Across `design-pass.md` (1652 lines) and `design-pass-v2.md` (698 lines), only 3 step-7 predictions were ever closed out with an actual measured run: Aurox (35%→47%, **+12 pts measured, then re-confirmed at +8.4 pts in the v2 buff-candidate table**, promoted), Ghouliath (+0.7 pts, "a wash," not a buff), Inutia (-2.7 pts, not a buff). The rest of both documents' predictions remain open ("I expect X") with no attached measurement — including, by the summarizing agent's count, most of Iblivion's rework, Xmon's "does the fixed sleep-engine beat spamming Vital Siphon" question (explicitly called "the single deciding result" and never run in v1, though v2's usage data suggests the fix shipped anyway), and several others.

- **A1**: Unacceptable rate, needs a hard gate — a section shouldn't ship a final recommendation with an unmeasured prediction still inside it, even if that means a much shorter doc.
- **A2**: Acceptable given real constraints — this is a throughput problem, not a discipline problem; building a working override script per mon is real work, and 3 fully-closed predictions out of many attempted is a reasonable hit rate for the effort each one costs.
- **A3**: Rate is fine, the writing is the problem — an unmeasured claim currently reads with the same confidence as a measured one; needs a visibly distinct callout for "guessed" vs. "measured," not a stricter gate on what ships.
- **A4**: The 2 falsified predictions matter more than the 1 confirmed one, and that's the process working, not failing — a process that only ever confirms its own guesses teaches nothing; both falsifications (switching sheds the debuff; mono-attacking beats the "intended" line) changed the model of a real mechanic.
- **A5**: Wants to check which predictions got skipped before judging the rate at all — worried the unmeasured ones might be systematically the *riskiest* claims (hardest to build a script for) rather than the least-confident ones, which would mean the process isn't measuring its biggest risks, just its easiest tests.

**Variance: HIGH.** The most direct question about the methodology this project already uses for automated design work — a natural capstone.

---

## Additional grounding notes (didn't earn a full question, still worth knowing)

From the full-roster kit sweep, a few smaller findings that inform several questions above without
needing their own entry:

- **Ekineki's Nine Nine Nine, quantified**: spending a full 0-damage turn for 90% crit next turn works
  out to an expected ≈1.45x multiplier on that following turn's hit, versus two un-boosted attacks
  averaging ≈1.025x each. Using it is an expected-damage *loss* over the 2-turn window — precise
  confirmation of design.md's "weak" verdict, relevant to Q9.
- **Nirvamma's Chronoffense anchor keeps counting while benched** — nothing resets it on switch-out,
  so a patient line (set the anchor, bench Nirvamma for many turns, cash in a near-guaranteed
  999-power hit later) exists and isn't mentioned in design.md's "too binary" framing.
- **Modal Bolt's three modes are power/status-identical twins** (90 power / 33% status each,
  differing only in type) — design.md's framing of a "lower-status/lower-damage mode" being rarely
  worth it doesn't match the code; the live choice is purely type-matchup preference.
- **Xmon's Night Terrors is a non-consuming, ever-escalating, stamina-gated recurring hit** — stacks
  never decrease, and it keeps auto-firing every round (scaled by total stacks) as long as Xmon can
  afford the stamina, silently skipping (stack preserved) when it can't. Worth a second look
  independent of the rest of Xmon's kit (Q8/Q9 territory) since it reads as a materially different
  risk profile once several stacks are banked than "not well set up" suggests.
- Two further numeric softenings beyond the four in Q16: Sofabbi's Snack Break floor and Xmon's
  Dreamcatcher heal are both actually 6.25% (1/16), not the "6.6%" in `moves.csv`/`abilities.csv` —
  minor on their own, but the same class of finding as Q16.

## Highest-leverage questions to answer first

All 20 came back high-variance, which is itself a signal the underlying design space is genuinely
open in most of these places. Ranked by how much *future* design work — including automated
content/balance passes — hinges on the answer:

1. **Q16** (four concrete CSV/code mismatches, including a signature move that never applies the
   status its own description promises) and **Q20** (only 3-of-many design-pass predictions ever
   measured) are the same finding at two different scales: the tooling and documentation this project
   already leans on to reason about balance has real, named blind spots, and at least one prior
   balance conclusion (Embursa) may have been reasoned from an incorrect premise. Highest-leverage
   pair to resolve before trusting — or running more of — an automated pass.
2. **Q11** (testing pipeline blind to level-gated moves) extends the same concern to progression
   content specifically: four shipped moves have never been arena-tested at all.
3. **Q13** (no ranking) and **Q14** (asymmetric blind team select, public rosters) are both completely
   fresh findings nothing in `design.md` or the prior passes has ever addressed, and both are
   foundational to whatever "the metagame" is even measured against.
4. **Q1** and **Q5** (stamina start value; Loop's real once-per-game gate versus what design.md's
   note assumed) are cases where the author's own written understanding is worth checking against the
   current mechanic before deciding anything else about them.
5. **Q10** extends a real, previously-stated trigger condition ("revisit after other reworks ship")
   that has no owner or deadline right now. **Q12** (Angery's strandable counter) is a likely correctness
   bug independent of any balance call and probably the cheapest fix in this whole document.
6. **Q17** and **Q19** are both places where a value stated in `stomp_intro.md` (determinism-friendly
   markets; not-a-job engagement) is in tension with a live or planned mechanic — worth an explicit,
   on-the-record resolution rather than leaving the tension implicit.

The other questions (Q2, Q3, Q4, Q6, Q7, Q8, Q9, Q15, Q18, and the Malalien-adjacent detail in Q10)
are all still worth the author's attention, but are more contained — a wrong answer to any one of
them is cheaper to reverse than a wrong answer to the six items above.
