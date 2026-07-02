import { offensiveMatchupScore, popcount8 } from './heuristic-shared';
import { BattleView, MonView } from './battle-view';

/**
 * SEARCH SUBSTRATE — layer 3: a single static evaluation of a position from the CPU's (p1's) point of
 * view. HIGHER = better for the CPU.
 *
 * This is deliberately an AGGREGATOR, not a new combat model: every term is either a `BattleView`
 * field or an existing `heuristic-shared` / `engine-view` primitive. There are NO invented combat
 * heuristics, damage models, or threat tables here — a search routine layers those on top by calling
 * `applyHypotheticalMove` and scoring the resulting views with this function.
 *
 * Terms (all from the CPU's perspective; p1 = CPU, p0 = opponent):
 *   1. HP swing      — Σ (cpu hp% − opp hp%) over active rosters, scaled to be the dominant term.
 *   2. KO differential — (opp mons KO'd − cpu mons KO'd), heavily weighted (a KO is worth a lot).
 *   3. Matchup edge  — active-mon `offensiveMatchupScore` (CPU→opp) minus the opponent's (opp→CPU).
 *   4. Stamina edge  — small bonus for the CPU active mon having more stamina than the opp active mon.
 *   5. Stat-stage edge — active-mon `statDeltaScore` diff: setup boosts score positive, burn's attack
 *      divide / frostbite's spatk divide negative. (Panic is a stamina drain — term 4 already sees it.)
 *   6. Skip edge     — the active mon's pending ShouldSkipTurn (zap) costs its next action. Sleep is
 *      NOT visible to a static snapshot (it NO_OPs the sleeper's move instead of flagging); a deeper
 *      search still prices it in as zero damage output across the simulated turns.
 */

// Weights. HP/KO dominate; matchup and stamina are tie-breakers. Kept as named constants so the
// composition is legible — none of these are engine values, just the relative emphasis of the
// already-existing signals.
/** The relative emphasis of the six position signals. Tunable: `fit-eval.ts` fits these from logged
 *  game outcomes; strategies can carry their own weights for A/B without touching the default. */
export interface EvalWeights {
  hp: number;
  ko: number;
  matchup: number;
  stamina: number;
  statDelta: number;
  skip: number;
}

export const DEFAULT_EVAL_WEIGHTS: EvalWeights = {
  hp: 1, // hp% diff is already 0..100 per mon; summed it is the primary signal.
  ko: 150, // one KO swing ≈ a mon at full HP plus margin.
  matchup: 0.5, // offensiveMatchupScore is in scale-10 units summed over type pairs.
  stamina: 2, // tiny nudge per point of active-mon stamina advantage.
  statDelta: 40, // a full base-stat of boost (Σ delta/base = 1.0) ≈ 40 hp%; burn's half-attack ≈ -20.
  skip: 30, // losing the next action ≈ eating a strong hit.
};

/** hp% (0..100) for a slot: current hp / max hp — both already on the snapshot, so this is pure-view
 *  (no engine read), which matters when a search scores thousands of forked positions. */
function hpPercent(mon: MonView): number {
  if (mon.maxHp <= 0) return 0;
  return (Math.max(0, mon.hp) * 100) / mon.maxHp;
}

/**
 * The six UNWEIGHTED terms, CPU-perspective (higher = better for the CPU). `scoreStateWith` is their
 * weighted sum; the fitting script consumes them raw so features and scoring can't drift apart.
 */
export function evalFeatures(view: BattleView): [number, number, number, number, number, number] {
  // 1. HP swing: Σ cpu hp% − Σ opp hp% over all roster slots.
  let cpuHpPct = 0;
  for (let i = 0; i < view.mons.p1.length; i++) {
    cpuHpPct += hpPercent(view.mons.p1[i]);
  }
  let oppHpPct = 0;
  for (let i = 0; i < view.mons.p0.length; i++) {
    oppHpPct += hpPercent(view.mons.p0[i]);
  }
  const hp = cpuHpPct - oppHpPct;

  // 2. KO differential: opponent KOs are good for the CPU, CPU KOs are bad.
  const ko = popcount8(view.oppKO) - popcount8(view.cpuKO);

  // 3-6. Active-mon terms: matchup edge, stamina edge, stat-stage edge (setup / burn / frostbite),
  // pending turn-skips (zap).
  const cpu = view.mons.p1[view.cpuActive];
  const opp = view.mons.p0[view.oppActive];
  let matchup = 0;
  let stamina = 0;
  let statDelta = 0;
  let skip = 0;
  if (cpu && opp) {
    matchup =
      offensiveMatchupScore(cpu.type1, cpu.type2, opp.type1, opp.type2) -
      offensiveMatchupScore(opp.type1, opp.type2, cpu.type1, cpu.type2);
    stamina = cpu.stamina - opp.stamina;
    statDelta = cpu.statDeltaScore - opp.statDeltaScore;
    skip = (opp.skipTurn ? 1 : 0) - (cpu.skipTurn ? 1 : 0);
  }

  return [hp, ko, matchup, stamina, statDelta, skip];
}

export function scoreStateWith(view: BattleView, w: EvalWeights): number {
  const [hp, ko, matchup, stamina, statDelta, skip] = evalFeatures(view);
  return w.hp * hp + w.ko * ko + w.matchup * matchup + w.stamina * stamina + w.statDelta * statDelta + w.skip * skip;
}

export function scoreState(view: BattleView): number {
  return scoreStateWith(view, DEFAULT_EVAL_WEIGHTS);
}
