# Stomp design pass — generating prompt (v3)

This prompt produces `docs/generated/design-pass-vN.md` in chomp. Run it from the chomp repo root.
Start from data, not from any earlier pass: fresh arena runs, `drool/mons.yaml` for stats, movesets,
and intended flavor, and a light read of `docs/design.md` for where the designer's thinking currently
stands. Do not reuse the content of earlier design passes. Go through mons in numerical id order.

## Purpose

Per mon: screen the win rate as a health check, then find moves that are never used or superseded and
rework them into something situationally useful, synergistic, and flavorful. Win rate 45–55% is fine,
and clean counters are fine. If anything, it's important that each mon has at least 1 other mon that can wall it or check it to some degree. Cap two new moves per mon. Flavor matters.

For example:
- Rise From The Grave fits Ghouliath as a ghoul, 
- Preemptive Shock fits Volthare being so fast it deals damage before the turn even starts. 
- Malalien as a vile milady hurls insults and acts as a glass cannon.

New mechanics should fit their mon the same way.

## Data foundation (run before writing anything)

- Fresh per-mon arena data: `cd sims && bun arena/mon-data.ts --strategies hard,greedy` — 250 random
4v4s per pilot, seat-swapped to cancel the p1 peek. Record win rate and per-move usage per pilot.
- `hard` is a peeking lookahead pilot; `greedy` is a 1-ply evaluator that over-values setup. Read the
avg as the health screen, and the hard/greedy gap as the piloting signal.
- Open the doc with three tables: the win-rate table (bands: above ≥55, in band 45–55, below ≤45),
the dead-slot list (≤~5% usage under both pilots), and the pilot-split list (heavy under one pilot,
ignored by the other).

## How each mon is analyzed

A mon is a woven sequence of as many `[Thing]` and `[Property]` blocks as the reasoning raises,
interleaved in the order the argument actually goes — not one of each, and not alternating by rule.
A typical order:

```
[Thing]     an observation about how it works / what's wrong
[Property]  a design response to it
[Property]  a second design angle
[Thing]     a new observation (with its own validation)
[Thing]     another observation
[Property]  the synthesizing / power-direction conclusion
```

It is acceptable, and in some cases desirable, to adjust earlier statements in light of thinking
revealed in a later block. When that happens, add a new block showing that you have changed your mind, and write the updated block below. Later blocks will superseded in the case of a conflict.

**`[Thing]`** — an empirical claim:

1) Reason about something.
2) Why do you know it?
3) Why isn't what we currently have working?
4) Is there something uncertain about it?
5) ***If so, can you validate it somehow?
6) What information would change your mind?
7) In light of this, is it easy to test?
8) If not, if you imagine simulating it, what do you think the result would be?
9) Is that consistent with the initial claim in 1)?

**`[Property]`** — a design opinion:

1) Give the opinion
2) What property (fun / difficulty / risk / reward / meta / complexity / progression) does it support?
3) Why does it support this property?
4) Are there alternatives that would do a better job?
5) If so, what are the trade-offs to those alternatives?
6) In light of this, do you still hold the original opinion?
7) If not, how would it be amended?
8) ***Is there something empirical we could validate to get more info about 1) or 4)?
9) If so, how would we change our mind after learning this information?

### What every [Thing] must contain

The questions are the order the argument goes. Across them, the block must discharge five
obligations, and a block missing any of them is incomplete no matter how long it is:

1. The claim (step 1).
2. Evidence with provenance (steps 2 and 2.5) — see "No naked numbers" below.
3. A falsifiable prediction with a number attached (step 7), written before the measurement runs.
4. The measurement result, appended to step 7 after the run and labeled as the result.
5. The update (step 8) — and when the result disagrees with the claim, the amendment is carried back
    into earlier blocks and the summary.

### Depth

Depth follows content. The load-bearing claim of a mon gets full multi-paragraph treatment. A step
whose honest answer is one sentence gets one sentence. Padding a step to hit a sentence count is
worse than leaving it short, because manufactured sentences are exactly the un-reasoned text this
format exists to prevent. 

Never restate another step's content to fill space — if step 5's answer is
already covered by step 3, say so in one line and move on. Adding more blocks never lightens the
*reasoning* in any block; what it must not do is trigger padding in steps that have nothing left to
say.

## Validation

Validation (step 4 of a Thing, step 8 of a Property) is a structured bullet list: measure the
baseline, state the exact change to make, state the delta expected, separate the regimes so the move
carves out its own niche, and say how the call updates in both directions. Static checks (type chart,
damage formula, reading the actual contract) stay static. Plan-based moves (setup, resource,
self-sacrifice, delayed payoff) fork on the opponent's branches — stay versus switch, set up versus
race — and need an override CPU that plays the plan before any arena number counts.

### Tooling map

Each validation bullet maps to a concrete tool, not an abstract "scripted test":

- **Static / mechanical** (damage math, move costs, degree tables, mechanic checks): read the
contract in `src/`, or script an exact 1v1 in `chomp/sims` (`src/harness.ts`: `makeSimContext` /
`buildMon` / `startBattle` / `executeTurn`, explicit move indices, no CPU, so no peek confound).
- **Win-rate + move-usage screen**: `cd sims && bun arena/mon-data.ts --strategies
hard,greedy,override`.
- **Plan-based / scripted-pilot** (does the intended line beat the naive one): the override CPU
(`sims/src/cpu/strategies/override-cpu.ts`) — base-HP-keyed scripts with `when` / `once` /
`maxUses` gates, falling through to `hard`. Add the mon's script alongside its analysis, then
re-run with `--strategies override`.
- **In-game instrumentation** (switch rate to shed a debuff, forced-switch value, stamina deadlock):
a bespoke script over `playGame`'s `onBeforeExecute` hook plus the `engine-view` readers.
- **New-move mechanics**: mock the move in the transpiled TS (`transpiler/ts-output/mons/…`) and
script it in `chomp/sims`. Validate mechanics first; defer the arena-impact claim, since the mock
must also reach munch's generated sim before an arena number means anything.

### No naked numbers

Every quantitative claim carries its provenance: a contract path, a run (command plus game count), or
an explicit `[estimate]` tag. Every win-rate delta carries its sample size and whether it clears
noise (≈1 SE; roughly 3–4 points at 250-500 games; confirm anything that matters at larger N). A
number with no source is not evidence and must not appear.

### Predict, then measure

For any claim whose validation runs the sim, the order of operations is fixed:

1. Write the block through step 7's prediction, with a number and a direction, before the run.
2. Run the measurement.
3. Append the result to step 7, labeled as the result. Do not rewrite the prediction.
4. Update step 8, and carry any amendment backward.

Data that already exists when the block is written (the opening arena screen, a contract read) is
evidence for step 2, not a prediction. Step 7 is reserved for measurements that have not run yet. A
prediction written after seeing the data is a postdiction and is worth nothing.

### Calibration

When a prediction falsifies, diagnose why the internal model was wrong — which mechanic was
mis-weighted (a Temp debuff shed by switching, a stamina line that never binds, a priority
interaction) — and record the correction in the block. If the sim result would change the analysis,
that is a sign the internal simulation needs grounding, and the correction is part of the deliverable.

If every prediction in a pass confirms, the predictions were too safe.

## Reasoning rules

1. **Couch every conclusion in the actual win rate and stat line, and match the change's power
    direction to where the mon sits.** Below band (≤~45) → the package must be a net buff (nerf one
    lever only if it's paid back with a real, quantified buff). In band → laterals / net-neutral.
    Above band (≥~55) → nerf or lateral, never raw power. Never ship an all-nerf package on a
    below-band mon.
2. **Judge every move inside the whole game system, not by a static stat-line comparison.** The
    stamina economy is important! For example, with 5 starting stamina, +1 regen per turn, a cheap move can may be important precisely because it's affordable when the expensive ones aren't. Trace a multi-turn line before calling anything dead.
3. **Unpiloted is not weak.** Many low scores are piloting floors — the CPU won't self-KO, manage a
    resource, or complete a setup. State the pilot logic, and treat plan-based mons' numbers as floors that need a scripted line or override before judgment.
4. **Ground every claim in numbers from source.** Read the contract for mechanics and constants.
    Damage ≈ basePower × attack ÷ defense × type × crit (1.5×), so relative claims are exact.
5. **Judge moves with the team, and name the concrete partner.** No hand-waved "a partner that
    punishes switches."
6. **Full move metadata always** (Name — Power / Stamina / Type / Class / Accuracy / Priority —
    effect) and full mechanics; no shorthand.
7. **Check feasibility against existing engine primitives** (`setMove` for a taunt,
    `clearAllStatBoosts`, per-battle `globalKV` flags); label each change a cheap number swap, a new
    move/effect contract, or heavier work.
8. **Entertain alternatives generously; gate strong new effects with an anti-spam limiter** (once per
    game, a cost, a drawback). Don't duplicate a baseline move. Avoid stall and immediate heals.

## Per-mon data block

Each mon's section ends with a small YAML block so the pass can be checked mechanically (direction
versus band, the two-move cap, open gates). The prose argues; this block is the diffable record.

```yaml
mon: Aurox
band: below                      # above / in / below
win_rate: {hard: 35.6, greedy: 40.3, avg: 38.0, n: 250}
direction: buff                  # must be consistent with band per rule 1
changes:
- {move: Gilded Recovery, kind: rework, cost: new-effect}
new_moves: 0                     # cap 2
gates:
- override tank line vs hard baseline at larger N
predictions:
- {claim: "Iron Wall entry line beats hard baseline", number: "+5 pts or more", result: "+9.0 at 150 games", verdict: confirmed}
```

## Executive summary format (per mon)

Focus on clarity rather than being punchy or terse. Full move mechanics and metadata whenever a
change is proposed. Nested:

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

## The [Predicted] / [Addressed] review layer

After each mon's analysis sits a separate, visible layer — not folded into the blocks above it.

- **`[Predicted]`** blocks simulate the feedback the designer would give, finding gaps in the
reasoning. They follow his direction of thought — interesting risk/reward payoffs, balancing the
game, the correct degree of complexity, options over flat stats — and they are left *unaddressed*
for his review pass. Their style follows the Writing section like all other text.

- **`[Addressed]`** blocks answer each one, verified against source where possible. When a finding
changes the design, the change is carried back into the analysis and the summary above.

Generate the `[Predicted]` layer in a fresh context: a separate agent given only `docs/design.md`,
the mon's finished section, this document, and three to five of the designer's real inline comments from earlier passes as examples of direction. The context that wrote the analysis pre-answers its own objections; an independent one does not.

## CPU pilot gaps and buff candidates

Many dead moves are piloting artifacts, not weak designs (rule 3), so the fix is often a pilot rule
rather than a move change. Two artifacts come out of this:

- **`[CPU gap]`** — a *hypothesized* pilot rule a harder difficulty should implement so the mon plays
its intended line. It is a hypothesis until an override run measures it, and it can test negative.

- **`[CPU buff]`** — an override rule that *measurably beat `hard`*, the pilot that ships. The bar is
beating `hard` beyond sampling noise, confirmed at larger N; beating `greedy` or the raw average
doesn't count.

Per-mon protocol: when a mon's override runs, record `override vs hard` in its validation and
summary. A positive delta beyond noise earns a `[CPU buff]` flag and a PROMOTE row in the
buff-candidates table at the end of the doc; a flat or negative result is recorded as "tested, not
promoted" so it isn't silently retried. The promotion target in munch is a per-mon entry in the CPU's
`MonConfig` (`services/cpu/heuristic-shared.ts` — `CONFIG_PREFERRED_MOVE` / `CONFIG_SWITCH_IN_MOVE` /
`CONFIG_SETUP_MOVE`). Editing munch is deferred; the doc only tracks candidates.

## Prediction ledger

The doc ends with a table of every step-7 prediction made during the pass: mon, the prediction with
its number, the measured result, and the verdict (confirmed / falsified / pending). This is the
calibration record. A pass where nothing falsifies is a pass whose predictions were written too
safely, and that is worth flagging in the ledger itself.

## Writing Style

### Register

Match the register of the designer's own writing. Two samples from `docs/design.md`:

> Gorillax is intended to be a simple bulky attacker that can hit hard. Rock Pull is intended to be a
> Pursuit-alike predicting move, but I think the downside of getting it wrong is rather steep. Throw
> Pebble was intended to be an interesting trade-off between stamina and power, but I think it may be
> too efficient when it is used, and it often doesn't need to be used.

> Keeping the Rest from healing Burn (but increasing the attack boost %) may be an interesting way of
> handling the risk/reward curve. As is, its moves don't really benefit directly from being burned.
> Q5 is very strong and can be spammed. Ideally it has low stamina to justify it being used early,
> but it can't be armed to go off multiple turns in a row.

> Wither Away and Grave Affliction are mentioned a lot. However, we need to do a deeper dive into
> their viability. Grave Affliction deals damage to both players — is this symmetry beneficial for
> the user? Do we need to tweak it?

Plain nouns and verbs, first person where an opinion is held. One claim per sentence, ideally one subject and one object, with supporting data after the claim. Contractions are fine; clarity over ease. No sentence fragments.

### Rules

- **No coined compound names for lines or concepts.** Refer to lines by their move names: "Initialize,
then Hit and Dip to pivot out" — never "the weave-and-pass line," "cripple-then-grudge," or
"unpiloted-not-weak." If a concept genuinely recurs, name it once when introduced, then use the
plain description.
- **The "X, not Y" contrastive construction appears at most once per mon section.** It is the single
strongest generated-text hallmark; spell out the contrast as two sentences instead.
- **No aphoristic paragraph closers.** Do not end a paragraph with a summarizing flourish ("That
ordering is the crux of the recommendation."). If the paragraph made its point, stop.
- **No compressed or colorful verbs** ("name-dropped," "waved at," "cashes the tempo"). Say what
happened in plain words, even if it takes a few more of them.
- **Don't pack multiple claims into one sentence.** Bad: "For example, chip plus a speed drop. Then
it is never a fully dead turn." Good: "For example, we can deal chip damage and lower the
opponent's speed. Then, it's never a dead turn."

### De-quirk pass

After the doc is complete, run a separate style pass whose only instructions are: match the register
samples above, apply the rules above, and change no number, claim, or conclusion. Style editing is
far more reliable as a rewrite pass than as a constraint during generation.