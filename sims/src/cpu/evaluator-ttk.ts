import { Hex } from './hex';
import { MoveClass } from '../../../transpiler/ts-output/Enums';
import { MoveMeta } from '../../../transpiler/ts-output/Structs';
import { BattleView } from './battle-view';
import { monCurrentSpeed } from './engine-view';
import {
  buildDamageCalcContext,
  estimateDamageMeta,
  loadMonMetas,
  popcount8,
} from './heuristic-shared';

/**
 * RACE-MATRIX EVALUATOR — first-principles alternative to `scoreState`'s linear feature weights.
 *
 * The win condition is KOing the whole opposing roster, so a position's value is the state of every
 * pairwise RACE: for each (my mon i, their mon j), the turns i needs to KO j (TTK) under the real
 * damage formula — per-pair contexts include stat deltas, so boosts/burns reprice races natively.
 * Stats, types, and HP carry no intrinsic weight; each matters exactly as far as it changes a race.
 *
 * Aggregation: each side's threat against an enemy mon is its best ANSWER speed — the min adjusted
 * TTK over its living roster, where "adjusted" pays +1 turn for deploying from the bench and +1 for
 * losing the head-to-head race (the answer can't simply stand and trade). Answer speeds sum as
 * 1/TTK (a wall ⇒ 1/∞ ⇒ 0 — the anti-wall signal is intrinsic, and removing the one mon that
 * answered a sweeper visibly rewrites a column). Banked KOs, the current active pair's race (tempo),
 * and a small stamina nudge complete the score. Three scale knobs replace six feature weights.
 *
 * Costlier than the pure-view scoreState (it decodes metas and builds contexts per pair) — fine for
 * root-level forks, noticeable but acceptable inside deep planner trees.
 */

const CPU_PLAYER_INDEX = 1n;
const OPP_PLAYER_INDEX = 0n;

const SCALE = 150; // one full answer-unit (a 1-turn answer) in scoreState-comparable units
const W_KO = 300; // a banked KO outranks the best living answer
const W_TEMPO = 75; // current-pair race edge — the one positional fact that matters
const W_STAMINA = 2;

interface SideData {
  metas: (MoveMeta[] | null)[];
  speed: number[];
}

function readSide(e: any, bk: Hex, playerIndex: bigint, mons: BattleView['mons']['p0']): SideData {
  const metas: (MoveMeta[] | null)[] = [];
  const speed: number[] = [];
  for (let i = 0; i < mons.length; i++) {
    metas.push(mons[i].ko ? null : loadMonMetas(e, bk, playerIndex, i));
    speed.push(mons[i].ko ? 0 : monCurrentSpeed(e, bk, playerIndex, i));
  }
  return { metas, speed };
}

/** Best single-move damage from attacker (its decoded metas) into the prepared context. */
function bestDamage(ctx: any, metas: MoveMeta[]): number {
  let best = 0;
  for (const meta of metas) {
    if (meta.moveClass !== MoveClass.Physical && meta.moveClass !== MoveClass.Special) continue;
    const d = estimateDamageMeta(ctx, meta);
    if (d > best) best = d;
  }
  return best;
}

export function ttkEval(view: BattleView): number {
  const e = view.engine;
  const bk = view.bk as Hex;
  const mine = view.mons.p1;
  const theirs = view.mons.p0;

  const my = readSide(e, bk, CPU_PLAYER_INDEX, mine);
  const op = readSide(e, bk, OPP_PLAYER_INDEX, theirs);

  // Pairwise TTK in both directions (Infinity = walled). FRACTIONAL turns: the aggregation must be
  // smooth in damage (ceil'd TTK is piecewise-constant in exactly what a root decision varies, which
  // collapses most candidates into ties); race OUTCOMES compare ceil'd turns below, where turn
  // boundaries are real.
  const ttkMine: number[][] = mine.map(() => theirs.map(() => Infinity));
  const ttkTheirs: number[][] = theirs.map(() => mine.map(() => Infinity));
  for (let i = 0; i < mine.length; i++) {
    if (mine[i].ko) continue;
    for (let j = 0; j < theirs.length; j++) {
      if (theirs[j].ko) continue;
      // Floored at one turn: nothing dies faster, and without the floor overkill capacity against
      // weakened prey outranks the KO credit for actually finishing it.
      const ctxMine = buildDamageCalcContext(e, bk, CPU_PLAYER_INDEX, i, OPP_PLAYER_INDEX, j);
      const dMine = bestDamage(ctxMine, my.metas[i]!);
      if (dMine > 0) ttkMine[i][j] = Math.max(1, theirs[j].hp / dMine);
      const ctxTheirs = buildDamageCalcContext(e, bk, OPP_PLAYER_INDEX, j, CPU_PLAYER_INDEX, i);
      const dTheirs = bestDamage(ctxTheirs, op.metas[j]!);
      if (dTheirs > 0) ttkTheirs[j][i] = Math.max(1, mine[i].hp / dTheirs);
    }
  }

  // Answer speeds: min adjusted TTK per enemy mon; +1 for bench deployment, +1 for losing the
  // head-to-head race (equal TTK loses on slower-or-tied speed, matching weGoFirst's pessimism).
  let offense = 0;
  for (let j = 0; j < theirs.length; j++) {
    if (theirs[j].ko) continue;
    let bestAnswer = Infinity;
    for (let i = 0; i < mine.length; i++) {
      if (mine[i].ko || ttkMine[i][j] === Infinity) continue;
      const tMine = Math.ceil(ttkMine[i][j]);
      const tTheirs = Math.ceil(ttkTheirs[j][i]);
      const losesRace = tTheirs < tMine || (tTheirs === tMine && op.speed[j] >= my.speed[i]);
      const adj = ttkMine[i][j] + (i === view.cpuActive ? 0 : 1) + (losesRace ? 1 : 0);
      if (adj < bestAnswer) bestAnswer = adj;
    }
    if (bestAnswer !== Infinity) offense += 1 / bestAnswer;
  }
  let defense = 0;
  for (let i = 0; i < mine.length; i++) {
    if (mine[i].ko) continue;
    let bestAnswer = Infinity;
    for (let j = 0; j < theirs.length; j++) {
      if (theirs[j].ko || ttkTheirs[j][i] === Infinity) continue;
      const tMine = Math.ceil(ttkMine[i][j]);
      const tTheirs = Math.ceil(ttkTheirs[j][i]);
      const losesRace = tMine < tTheirs || (tMine === tTheirs && my.speed[i] >= op.speed[j]);
      const adj = ttkTheirs[j][i] + (j === view.oppActive ? 0 : 1) + (losesRace ? 1 : 0);
      if (adj < bestAnswer) bestAnswer = adj;
    }
    if (bestAnswer !== Infinity) defense += 1 / bestAnswer;
  }

  // Tempo: the race already in progress between the actives (a pending skip costs its side a turn).
  const a = view.cpuActive;
  const b = view.oppActive;
  let tempo = 0;
  let stamina = 0;
  if (!mine[a]?.ko && !theirs[b]?.ko) {
    const ta = ttkMine[a][b] + (mine[a].skipTurn ? 1 : 0);
    const tb = ttkTheirs[b][a] + (theirs[b].skipTurn ? 1 : 0);
    tempo = W_TEMPO * ((ta === Infinity ? 0 : 1 / ta) - (tb === Infinity ? 0 : 1 / tb));
    stamina = W_STAMINA * (mine[a].stamina - theirs[b].stamina);
  }

  const ko = W_KO * (popcount8(view.oppKO) - popcount8(view.cpuKO));
  return ko + SCALE * (offense - defense) + tempo + stamina;
}
