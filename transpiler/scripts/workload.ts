// Shared deterministic workload generation for the arena gate/benchmark
// scripts. batch_benchmark cross-checks per-game against a previously
// recorded arena_benchmark run, so the xorshift stream, draw order, pair
// rotation, and seed base MUST stay bit-identical across scripts — hence
// ONE copy of all of it.

import { TEAM_SIZE } from '../../sims/src/cpu/constants';
import { buildTeamMon, type DraftedMon } from '../../sims/src/arena/team';
import { monToJson } from '../../sims/src/arena/rust-engine';

export const NUM_MONS = 13;

/** [p1Strategy, p0Strategy] — matching playGame(stratP1, stratP0, ...).
 * A contract with StrategyKind::parse in strategies-rs and the TS registry. */
export const STRAT_PAIRS: [string, string][] = [
  ['hard', 'hard'],
  ['hard', 'greedy'],
  ['greedy', 'hard'],
  ['greedy', 'greedy'],
  ['override', 'greedy'],
  ['override', 'hard'],
];

export interface WorkItem {
  idx: number;
  strats: [string, string];
  teams: [DraftedMon[], DraftedMon[]];
  seed: number;
}

/** xorshift32 in [0,1) — operator sequence is load-bearing (ToInt32
 * coercion on the `>> 17` step included); do not "clean it up". */
export function makeWrand(seed: number): () => number {
  let wseed = seed >>> 0;
  return () => {
    wseed ^= wseed << 13; wseed >>>= 0;
    wseed ^= wseed >> 17;
    wseed ^= wseed << 5; wseed >>>= 0;
    return wseed / 0x100000000;
  };
}

export function drawTeam(wrand: () => number): DraftedMon[] {
  const pool = Array.from({ length: NUM_MONS }, (_, i) => i);
  const ids: number[] = [];
  for (let k = 0; k < TEAM_SIZE; k++) {
    ids.push(pool.splice(Math.floor(wrand() * pool.length), 1)[0]);
  }
  return ids.map((id) => ({ id, equip: undefined as any }));
}

/** The full game list for one run: pair rotation + two team draws per game
 * (drawn for EVERY game so streams stay aligned across filtered consumers). */
export function buildWork(games: number, wseed: number, seedBase: number): WorkItem[] {
  const wrand = makeWrand(wseed);
  const work: WorkItem[] = [];
  for (let i = 0; i < games; i++) {
    work.push({
      idx: i,
      strats: STRAT_PAIRS[i % STRAT_PAIRS.length],
      teams: [drawTeam(wrand), drawTeam(wrand)],
      seed: seedBase + i,
    });
  }
  return work;
}

/** chomp_run_games `games` entries for `work` — the [p1, p0] seat mapping
 * lives here, once. */
export function buildBatchGames(ctx: any, roster: any, work: WorkItem[], maxTurns: number) {
  return work.map((w) => ({
    seed: w.seed,
    maxTurns,
    p0Strategy: w.strats[1],
    p1Strategy: w.strats[0],
    p0Team: w.teams[0].map((dm) => monToJson(buildTeamMon(ctx, roster, dm.id, dm.equip))),
    p1Team: w.teams[1].map((dm) => monToJson(buildTeamMon(ctx, roster, dm.id, dm.equip))),
  }));
}
