import { Hex } from './hex';
import { MoveClass, MonStateIndexName, Type } from '../../../transpiler/ts-output/Enums';
import { moveSlotLib } from '../../../transpiler/ts-output/moves/MoveSlotLib';
import { DamageCalcContext, MoveMeta } from '../../../transpiler/ts-output/Structs';
import { NO_OP_INDEX, SWITCH_MOVE_INDEX } from './constants';
import { BattleView } from './battle-view';
import { RevealedMove, monCurrentHp, monCurrentSpeed, monCurrentStamina } from './engine-view';
import { applyHypotheticalMove, disposeFork, HypotheticalMove } from './forward-model';
import { scoreState } from './evaluator';
import {
  SIMILAR_DAMAGE_THRESHOLD,
  SWITCH_THRESHOLD,
  buildDamageCalcContext,
  estimateDamage,
  estimateDamageMeta,
  findBestDamageMove,
  loadMonMetas,
  offensiveMatchupScore,
} from './heuristic-shared';

/**
 * TS-NATIVE shared strategy helpers — NOT Solidity ports. `heuristic-shared.ts` is the faithful
 * HeuristicCPUBase.sol port and stays 1:1; helpers invented client-side that more than one strategy
 * uses live here instead. Two families:
 *   - band/anti-wall picks (any strategy);
 *   - FAIR-INFO pool analysis: worst case over the opponent's AFFORDABLE move pool (no peeking;
 *     stamina is public info, so an unaffordable nuke is not a threat). Shared by Medium and Stall.
 */

const CPU_PLAYER_INDEX = 1n;
const OPP_PLAYER_INDEX = 0n;

// A matchup is "walled" if our best move does LESS than this % of the opponent active mon's CURRENT HP
// (a near-useless attack). Tuned low so the breaker fires only on a true wall, never on a slow-but-OK
// matchup — keeping switches rare and preventing oscillation.
export const WALL_DAMAGE_PCT = 5;

/**
 * Uniform pick among the moves inside the similar-damage band (within {@link SIMILAR_DAMAGE_THRESHOLD}%
 * of the best damage). The deterministic `findBestDamageMove` always resolves the band to the
 * cheapest-stamina member, which makes a strategy's default move scriptable game after game; sampling
 * the band trades a little stamina efficiency for unpredictability at near-equal damage. Returns an
 * index into `moves`, or -1 if no move deals damage.
 */
export function pickSimilarDamageMove(damages: number[], rng: () => number): number {
  let bestDamage = 0;
  for (let i = 0; i < damages.length; i++) {
    if (damages[i] > bestDamage) bestDamage = damages[i];
  }
  if (bestDamage === 0) return -1;

  const threshold = Math.floor((bestDamage * SIMILAR_DAMAGE_THRESHOLD) / 100);
  const band: number[] = [];
  for (let i = 0; i < damages.length; i++) {
    if (damages[i] >= threshold) band.push(i);
  }
  return band[Math.floor(rng() * band.length)];
}

/**
 * Anti-wall stalemate-breaker. Returns the index (into `switches`) of a bench mon to pivot to when the
 * active mon is WALLED — its best move can't meaningfully damage the opponent's active mon — and a bench
 * mon has a strictly better offensive type matchup; else -1.
 *
 * This fills the gap a threat-based defensive switch leaves: it only fires on a THREAT, so a passive
 * opponent that we also can't hurt produces an endless flail at a wall. The breaker pivots to a mon that
 * can actually do something. It only fires when we're NOT making progress and a STRICTLY better attacker
 * exists, so a productive matchup is never abandoned and it can't oscillate (the better mon, by
 * definition, is the new best — nothing beats it next turn).
 */
export function antiWallSwitch(
  view: BattleView,
  metas: MoveMeta[],
  moves: RevealedMove[],
  damages: number[],
  switches: RevealedMove[],
  forkPick?: { revealIdx: number; revealExtra: number; salt: bigint },
): number {
  if (switches.length === 0) return -1;
  const e = view.engine;
  const bk = view.bk as Hex;
  const opponentMonIndex = view.oppActive;
  const oppHp = monCurrentHp(e, bk, OPP_PLAYER_INDEX, opponentMonIndex);
  if (oppHp <= 0) return -1;

  // Progress check: best move does >= WALL_DAMAGE_PCT% of the opp's current HP => productive, stay in.
  const bestIdx = findBestDamageMove(metas, moves, damages);
  const bestDmg = bestIdx >= 0 ? damages[bestIdx] : 0;
  if (bestDmg * 100 >= oppHp * WALL_DAMAGE_PCT) return -1;

  // Walled: only bench mons whose offensive matchup STRICTLY beats the current one qualify — each
  // pivot strictly improves the active matchup, so pivots can't oscillate.
  const oppStats = e.getMonStatsForBattle(bk, OPP_PLAYER_INDEX, BigInt(opponentMonIndex));
  const ourStats = e.getMonStatsForBattle(bk, CPU_PLAYER_INDEX, BigInt(view.cpuActive));
  const currentScore = offensiveMatchupScore(
    ourStats.type1 as Type, ourStats.type2 as Type, oppStats.type1 as Type, oppStats.type2 as Type,
  );
  const qualified: { idx: number; matchup: number }[] = [];
  for (let i = 0; i < switches.length; i++) {
    const candStats = e.getMonStatsForBattle(bk, CPU_PLAYER_INDEX, BigInt(switches[i].extraData));
    const score = offensiveMatchupScore(
      candStats.type1 as Type, candStats.type2 as Type, oppStats.type1 as Type, oppStats.type2 as Type,
    );
    if (score > currentScore) qualified.push({ idx: i, matchup: score });
  }
  if (qualified.length === 0) return -1;

  // Among the qualified candidates, pick the pivot TARGET by fork score when a reveal is available
  // (type matchup alone repeatedly picked the wrong mon); without one, keep the best-matchup pick.
  if (forkPick && qualified.length > 1) {
    let best = qualified[0].idx;
    let bestScore = -Infinity;
    for (const q of qualified) {
      const s = forkScoreAction(e, bk, forkPick.revealIdx, forkPick.revealExtra, switches[q.idx], forkPick.salt);
      if (s > bestScore) {
        bestScore = s;
        best = q.idx;
      }
    }
    return best;
  }
  let best = qualified[0];
  for (const q of qualified) if (q.matchup > best.matchup) best = q;
  return best.idx;
}

// ---------------------------------------------------------------------------------------------
// Fair-info pool analysis (no peek): worst case over the opponent's AFFORDABLE move pool.
// ---------------------------------------------------------------------------------------------

/**
 * Max damage the opponent could deal to a defender given a prepared `defendCtx` (opp -> defender) and
 * their decoded metas, over the Physical/Special moves they can afford this turn.
 */
export function maxPoolDamage(defendCtx: DamageCalcContext, oppMetas: MoveMeta[], oppStamina: number): number {
  let maxDmg = 0;
  for (let i = 0; i < oppMetas.length; i++) {
    const meta = oppMetas[i];
    if (Number(meta.stamina) > oppStamina) continue;
    // Only Physical/Special moves deal damage.
    if (meta.moveClass === MoveClass.Physical || meta.moveClass === MoveClass.Special) {
      const dmg = estimateDamageMeta(defendCtx, meta);
      if (dmg > maxDmg) maxDmg = dmg;
    }
  }
  return maxDmg;
}

/**
 * Max priority across the opponent's AFFORDABLE move pool. Default-zero metas contribute priority 0 —
 * the correct pessimistic floor.
 */
export function maxPoolPriority(oppMetas: MoveMeta[], oppStamina: number): number {
  let maxPrio = 0;
  for (let i = 0; i < oppMetas.length; i++) {
    if (Number(oppMetas[i].stamina) > oppStamina) continue;
    const p = Number(oppMetas[i].priority);
    if (p > maxPrio) maxPrio = p;
  }
  return maxPrio;
}

/**
 * Evaluate every switch candidate against the opponent's worst-case-over-affordable-pool damage —
 * max(static model, sim-measured) per candidate, apples-to-apples with a measured
 * `worstIncomingDmgToActive`. Switch when (a) staying in is lethal AND a candidate survives the
 * worst case, OR (b) staying-in damage% exceeds the best candidate's by >= SWITCH_THRESHOLD.
 * Candidate forks only run past the severity gate, so safe turns cost nothing.
 */
export function evaluateDefensiveSwitchFair(
  e: any,
  bk: Hex,
  activeMonIndex: number,
  opponentMonIndex: number,
  oppMetas: MoveMeta[],
  worstIncomingDmgToActive: number,
  switches: RevealedMove[],
  severeDamagePct: number,
  oppStamina: number,
  salt: bigint,
): { shouldSwitch: boolean; switchIdx: number } {
  // Our active mon's max + current HP.
  const ourMaxHp = Number(e.getMonValueForBattle(bk, CPU_PLAYER_INDEX, BigInt(activeMonIndex), MonStateIndexName.Hp));
  const ourCurrentHp = monCurrentHp(e, bk, CPU_PLAYER_INDEX, activeMonIndex);

  // Damage% taken and whether staying in is lethal.
  const damagePctToUs = ourMaxHp > 0 ? Math.floor((worstIncomingDmgToActive * 100) / ourMaxHp) : 0;
  const lethalToUs = worstIncomingDmgToActive >= ourCurrentHp;

  // Below the severe threshold and not lethal => never switch defensively.
  if (damagePctToUs < severeDamagePct && !lethalToUs) {
    return { shouldSwitch: false, switchIdx: 0 };
  }

  let bestDamagePct = Number.MAX_SAFE_INTEGER;
  let bestSwitchIdx = 0;
  let bestSurvives = false;

  for (let i = 0; i < switches.length; i++) {
    const candidateMonIndex = switches[i].extraData;
    // opp(active) -> candidate: static worst over the affordable pool, raised by the sim measurement.
    const ctx = buildDamageCalcContext(e, bk, OPP_PLAYER_INDEX, opponentMonIndex, CPU_PLAYER_INDEX, candidateMonIndex);
    const candWorst = Math.max(
      maxPoolDamage(ctx, oppMetas, oppStamina),
      forkMeasurePoolThreat(e, bk, opponentMonIndex, oppMetas, oppStamina, candidateMonIndex, salt),
    );

    const maxHp = Number(e.getMonValueForBattle(bk, CPU_PLAYER_INDEX, BigInt(candidateMonIndex), MonStateIndexName.Hp));
    const candCurrentHp = monCurrentHp(e, bk, CPU_PLAYER_INDEX, candidateMonIndex);

    // damage% (huge sentinel when maxHp is 0 so it never wins the min).
    const dmgPct = maxHp > 0 ? Math.floor((candWorst * 100) / maxHp) : Number.MAX_SAFE_INTEGER;
    const survives = candWorst < candCurrentHp;

    if (dmgPct < bestDamagePct) {
      // Track the candidate taking the least damage%.
      bestDamagePct = dmgPct;
      bestSwitchIdx = i;
      bestSurvives = survives;
    }
  }

  // Lethal staying in and a candidate survives => switch.
  if (lethalToUs && bestSurvives) return { shouldSwitch: true, switchIdx: bestSwitchIdx };
  // Staying-in damage% clears best by >= SWITCH_THRESHOLD => switch.
  if (damagePctToUs >= bestDamagePct + SWITCH_THRESHOLD) return { shouldSwitch: true, switchIdx: bestSwitchIdx };

  return { shouldSwitch: false, switchIdx: 0 };
}

/**
 * Forced/fallback switch under fair info: the best worst-case sponge — least max-affordable-pool
 * damage taken across the opp's whole move pool. Static only: this runs on forced-switch turns,
 * where the engine doesn't execute the opponent's move, so a fork has nothing to measure.
 */
export function selectBestSwitchFair(e: any, bk: Hex, opponentMonIndex: number, switches: RevealedMove[]): RevealedMove {
  const oppMetas = loadMonMetas(e, bk, OPP_PLAYER_INDEX, opponentMonIndex);
  const oppStamina = monCurrentStamina(e, bk, OPP_PLAYER_INDEX, opponentMonIndex);
  let bestIdx = 0;
  let leastWorst = Number.MAX_SAFE_INTEGER;
  for (let i = 0; i < switches.length; i++) {
    const candidateMonIndex = switches[i].extraData;
    const ctx = buildDamageCalcContext(e, bk, OPP_PLAYER_INDEX, opponentMonIndex, CPU_PLAYER_INDEX, candidateMonIndex);
    const candWorst = maxPoolDamage(ctx, oppMetas, oppStamina);
    if (candWorst < leastWorst) {
      leastWorst = candWorst;
      bestIdx = i;
    }
  }
  return switches[bestIdx];
}

/**
 * Is our KO move GUARANTEED to resolve — i.e. the opponent's revealed move cannot KO us first?
 * True when the reveal is a switch/rest/non-damaging move, when its damage leaves us standing, or
 * when we win the priority/speed race outright (ties play it safe and return false).
 */
export function koIsGuaranteed(
  e: any,
  bk: Hex,
  view: BattleView,
  metas: MoveMeta[],
  koMove: RevealedMove,
  playerMoveIndex: number,
): boolean {
  if (playerMoveIndex >= SWITCH_MOVE_INDEX) return true;

  let oppSlot: bigint;
  let oppClass: MoveClass;
  try {
    oppSlot = e.getMoveForMonForBattle(bk, OPP_PLAYER_INDEX, BigInt(view.oppActive), BigInt(playerMoveIndex));
    oppClass = moveSlotLib.moveClass(oppSlot, e, bk) as MoveClass;
  } catch {
    return true; // unreadable reveal can't be a damage threat
  }
  if (oppClass !== MoveClass.Physical && oppClass !== MoveClass.Special) return true;

  const ctxToUs = e.getDamageCalcContext(bk, OPP_PLAYER_INDEX, CPU_PLAYER_INDEX);
  const damageToUs = estimateDamage(e, bk, ctxToUs, oppSlot, oppClass);
  if (damageToUs < monCurrentHp(e, bk, CPU_PLAYER_INDEX, view.cpuActive)) return true;

  // They could KO us back — only guaranteed if we act first.
  const ourPriority = Number(metas[koMove.moveIndex].priority);
  const oppPriority = Number(moveSlotLib.priority(oppSlot, e, bk, OPP_PLAYER_INDEX));
  if (ourPriority !== oppPriority) return ourPriority > oppPriority;
  return monCurrentSpeed(e, bk, CPU_PLAYER_INDEX, view.cpuActive) > monCurrentSpeed(e, bk, OPP_PLAYER_INDEX, view.oppActive);
}

/**
 * Measure OUR moves' damage by actually stepping the local sim forward, instead of trusting the
 * static damage model. Differential measurement: fork the turn with (reveal, rest) as the baseline,
 * then (reveal, move_i) per candidate — the defender's HP gap is move_i's REAL damage, with the
 * engine adjudicating everything the static estimator can't see (variable-power moves, ability
 * procs like Adaptor, the post-switch defender, speed races). Effects that tick in both forks
 * cancel out of the differential.
 *
 * `revealIdx`/`revealExtra` is the opponent's (possibly voided) revealed action; NO_OP measures
 * against the current defender at rest. One fixed `salt` drives every fork, so a sub-100-accuracy
 * roll can miss and read 0 — callers should take max(static, measured) for offense and never use
 * this for threat assessment (threats need the always-hit worst case).
 */
export function forkMeasureMoveDamages(
  e: any,
  bk: Hex,
  revealIdx: number,
  revealExtra: number,
  moves: RevealedMove[],
  salt: bigint,
): { damages: number[]; scores: number[]; defenderMonIndex: number } {
  const p0: HypotheticalMove =
    revealIdx === NO_OP_INDEX
      ? { moveIndex: NO_OP_INDEX, salt, extraData: 0 }
      : { moveIndex: revealIdx, salt, extraData: revealExtra };

  const base = applyHypotheticalMove(e, bk, p0, { moveIndex: NO_OP_INDEX, salt, extraData: 0 });
  const defenderMonIndex = base.oppActive;
  const baseHp = base.mons.p0[defenderMonIndex].hp;
  disposeFork(e, base.bk);

  // Each move's fork yields its damage AND the resulting position's score — the same forks feed both
  // the damage table and the eval-veto, so the veto is nearly free.
  const scores: number[] = new Array(moves.length);
  const damages = moves.map((m, i) => {
    const child = applyHypotheticalMove(e, bk, p0, { moveIndex: m.moveIndex, salt, extraData: m.extraData });
    const dealt = baseHp - child.mons.p0[defenderMonIndex].hp;
    scores[i] = scoreState(child);
    disposeFork(e, child.bk);
    return dealt > 0 ? dealt : 0;
  });
  return { damages, scores, defenderMonIndex };
}

// The tree's pick must be beaten by at least this much (scoreState units; > one KO swing) before the
// eval-veto overrides it. The margin keeps the decision tree as the policy — with its long-horizon
// heuristics and persona — and only strips egregious single-turn blunders. Lower margins measurably
// underperform: frequent 1-ply overrides break the tree's cross-turn coherence even though each
// override scores better in isolation.
export const EVAL_OVERRIDE_MARGIN = 200;

/**
 * Eval-veto: fork-score every legal alternative against the same reveal and return one that beats the
 * tree's `chosen` by >= {@link EVAL_OVERRIDE_MARGIN}, else null. Move forks were already paid for by
 * {@link forkMeasureMoveDamages} (pass their `scores`); only switches and rest fork here.
 */
export function pickEvalOverride(
  e: any,
  bk: Hex,
  revealIdx: number,
  revealExtra: number,
  chosen: RevealedMove,
  moves: RevealedMove[],
  moveScores: number[],
  switches: RevealedMove[],
  noOp: RevealedMove[],
  salt: bigint,
): RevealedMove | null {
  const p0: HypotheticalMove =
    revealIdx === NO_OP_INDEX
      ? { moveIndex: NO_OP_INDEX, salt, extraData: 0 }
      : { moveIndex: revealIdx, salt, extraData: revealExtra };

  let chosenScore: number | undefined;
  let best: RevealedMove | null = null;
  let bestScore = -Infinity;

  const consider = (m: RevealedMove, score: number) => {
    if (m.moveIndex === chosen.moveIndex && m.extraData === chosen.extraData) {
      chosenScore = score;
      return;
    }
    if (score > bestScore) {
      bestScore = score;
      best = m;
    }
  };

  for (let i = 0; i < moves.length; i++) consider(moves[i], moveScores[i]);
  for (const m of [...switches, ...noOp]) {
    const child = applyHypotheticalMove(e, bk, p0, { moveIndex: m.moveIndex, salt, extraData: m.extraData });
    const s = scoreState(child);
    disposeFork(e, child.bk);
    consider(m, s);
  }

  if (chosenScore === undefined) {
    // Chosen wasn't among the enumerated candidates (rng-drawn extraData target) — score it directly.
    const child = applyHypotheticalMove(e, bk, p0, { moveIndex: chosen.moveIndex, salt, extraData: chosen.extraData });
    chosenScore = scoreState(child);
    disposeFork(e, child.bk);
  }

  return best !== null && bestScore >= chosenScore + EVAL_OVERRIDE_MARGIN ? best : null;
}

/**
 * EV-scale damages by each move's accuracy: a 120-power 85%-accuracy move is worth 102 expected
 * damage, and an "85% guaranteed KO" correctly stops reading as guaranteed. Inline attacks always
 * run DEFAULT_ACCURACY (100); external moves expose `accuracy(battleKey)` (unreadable => 100).
 */
export function evScaleDamages(
  e: any,
  bk: Hex,
  monIndex: number,
  moves: RevealedMove[],
  damages: number[],
): number[] {
  return damages.map((d, i) => {
    if (d === 0) return 0;
    const slot = e.getMoveForMonForBattle(bk, CPU_PLAYER_INDEX, BigInt(monIndex), BigInt(moves[i].moveIndex));
    if (slot === undefined || slot === null || moveSlotLib.isInline(slot)) return d;
    try {
      const move = moveSlotLib.toIMoveSet(slot) as any;
      if (typeof move.accuracy !== 'function') return d;
      const acc = Number(move.accuracy(bk));
      return acc >= 100 || acc <= 0 ? d : Math.floor((d * acc) / 100);
    } catch {
      return d;
    }
  });
}

/**
 * Measured worst-case incoming damage from the opponent's AFFORDABLE pool, by stepping the sim:
 * for each affordable opponent move, fork (oppMove, ourAction) against the (rest, ourAction)
 * baseline and read OUR mon's HP gap. `switchTarget` is null to measure the current active staying
 * in, or a bench index to measure a switch-in's entry damage. Catches threats the static model
 * can't price (variable-power moves, damaging Self/Other utility moves, ability interactions).
 *
 * Deliberately NOT EV-scaled and meant to be combined as max(static, measured): threats assume the
 * hit lands, and a fork's fixed-salt miss must never understate one. Useless on a forced-switch
 * turn (the engine doesn't execute the opponent's move there — nothing to measure).
 */
export function forkMeasurePoolThreat(
  e: any,
  bk: Hex,
  oppMonIndex: number,
  oppMetas: MoveMeta[],
  oppStamina: number,
  switchTarget: number | null,
  salt: bigint,
): number {
  const ourAction: HypotheticalMove =
    switchTarget === null
      ? { moveIndex: NO_OP_INDEX, salt, extraData: 0 }
      : { moveIndex: SWITCH_MOVE_INDEX, salt, extraData: switchTarget };

  const baseline = applyHypotheticalMove(e, bk, { moveIndex: NO_OP_INDEX, salt, extraData: 0 }, ourAction);
  const ourMon = switchTarget ?? baseline.cpuActive;
  const baseHp = baseline.mons.p1[ourMon].hp;
  disposeFork(e, baseline.bk);

  let worst = 0;
  for (let j = 0; j < oppMetas.length; j++) {
    if (Number(oppMetas[j].stamina) > oppStamina) continue;
    const slot = e.getMoveForMonForBattle(bk, OPP_PLAYER_INDEX, BigInt(oppMonIndex), BigInt(j));
    if (slot === undefined || slot === null) continue; // padded slot past the mon's real move count
    const child = applyHypotheticalMove(e, bk, { moveIndex: j, salt, extraData: 0 }, ourAction);
    const dealt = baseHp - child.mons.p1[ourMon].hp;
    disposeFork(e, child.bk);
    if (dealt > worst) worst = dealt;
  }
  return worst;
}

/**
 * Measure ONE opponent move's damage to our side by stepping the sim: differential between the
 * (rest, ourAction) baseline and (oppMove, ourAction). `switchTarget` null measures the current
 * active staying in; a bench index measures that candidate's entry damage. The peek-side single-move
 * sibling of {@link forkMeasurePoolThreat}: it sees what the static model can't (variable-power
 * reveals, our own ability mitigation, switch-in procs). A fixed-salt fork can roll a miss, so
 * threat-side callers keep the static estimate as the floor/fallback.
 */
export function forkMeasureIncomingDamage(
  e: any,
  bk: Hex,
  oppMoveIndex: number,
  oppExtraData: number,
  switchTarget: number | null,
  salt: bigint,
): number {
  if (oppMoveIndex >= SWITCH_MOVE_INDEX) return 0; // a switch or rest deals nothing

  const ourAction: HypotheticalMove =
    switchTarget === null
      ? { moveIndex: NO_OP_INDEX, salt, extraData: 0 }
      : { moveIndex: SWITCH_MOVE_INDEX, salt, extraData: switchTarget };

  const baseline = applyHypotheticalMove(e, bk, { moveIndex: NO_OP_INDEX, salt, extraData: 0 }, ourAction);
  const ourMon = switchTarget ?? baseline.cpuActive;
  const baseHp = baseline.mons.p1[ourMon].hp;
  disposeFork(e, baseline.bk);

  const child = applyHypotheticalMove(e, bk, { moveIndex: oppMoveIndex, salt, extraData: oppExtraData }, ourAction);
  const dealt = baseHp - child.mons.p1[ourMon].hp;
  disposeFork(e, child.bk);
  return dealt > 0 ? dealt : 0;
}

/** Fork one candidate action against the reveal and return the resulting position's score. */
export function forkScoreAction(
  e: any,
  bk: Hex,
  revealIdx: number,
  revealExtra: number,
  action: RevealedMove,
  salt: bigint,
): number {
  const p0: HypotheticalMove =
    revealIdx === NO_OP_INDEX
      ? { moveIndex: NO_OP_INDEX, salt, extraData: 0 }
      : { moveIndex: revealIdx, salt, extraData: revealExtra };
  const child = applyHypotheticalMove(e, bk, p0, { moveIndex: action.moveIndex, salt, extraData: action.extraData });
  const s = scoreState(child);
  disposeFork(e, child.bk);
  return s;
}

// ---------------------------------------------------------------------------------------------
// Risk-sensitive sampling: every fork is ONE RNG realization (crits, accuracy, branch moves), so an
// eval-driven root can sample several salts per candidate and choose by expected score — and tilt:
// ahead, prefer certainty (lock the win in); behind, prefer variance (the gamble is free).
// ---------------------------------------------------------------------------------------------

// Distinct salt streams per turn — offsets just need to be co-prime-ish so the engine's per-salt
// RNG derivations don't correlate.
export const RISK_SALT_OFFSETS = [1n, 1009n, 2017n] as const;

// Posture flips outside ±RISK_THRESHOLD (≈ a KO swing); λ scales how hard the tilt leans on spread.
const RISK_THRESHOLD = 120;
const RISK_LAMBDA = 0.5;

/** +1 = ahead (prefer low variance), -1 = behind (prefer high variance), 0 = play the mean. */
export function riskPosture(currentScore: number): -1 | 0 | 1 {
  if (currentScore >= RISK_THRESHOLD) return 1;
  if (currentScore <= -RISK_THRESHOLD) return -1;
  return 0;
}

/** Mean of the sampled fork scores, tilted by ±λ·σ per the posture. */
export function riskAdjustedScore(samples: number[], posture: -1 | 0 | 1): number {
  let mean = 0;
  for (const s of samples) mean += s;
  mean /= samples.length;
  if (posture === 0 || samples.length < 2) return mean;
  let variance = 0;
  for (const s of samples) variance += (s - mean) * (s - mean);
  const sd = Math.sqrt(variance / samples.length);
  return mean + (posture > 0 ? -RISK_LAMBDA * sd : RISK_LAMBDA * sd);
}
