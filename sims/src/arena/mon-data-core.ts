/**
 * Reusable core for the per-mon win-rate + move-usage arena (`mon-data.ts`), factored out so the same
 * tally logic runs inline (sequential) or inside a Worker (parallel shard). A work unit is one
 * (strategy, seed) pair, which expands to the two seat-swapped games. Records merge by summation, so
 * the aggregate is independent of how work units are sharded across workers — parallel output is
 * byte-identical to sequential.
 */
import { buildRandomTeam } from './team-builder';
import { getCpuStrategy } from '../cpu';
import { MonMetadata } from '../cpu/mon-meta';
import { activeMonIndices } from '../cpu/engine-view';
import { makeRng } from './rng';
import { playGame } from './game';

export interface MonRec {
  wins: number;
  losses: number;
  draws: number;
  moveCounts: number[];
  moveTurns: number;
}

export interface ShardResult {
  rec: Record<number, MonRec>;
  totalGames: number;
  errors: number;
}

export interface WorkItem {
  strat: string;
  seed: number;
}

export const MON_IDS: number[] = Object.keys(MonMetadata).map(Number);

export function newShardResult(): ShardResult {
  const rec: Record<number, MonRec> = {};
  for (const id of MON_IDS) rec[id] = { wins: 0, losses: 0, draws: 0, moveCounts: [0, 0, 0, 0], moveTurns: 0 };
  return { rec, totalGames: 0, errors: 0 };
}

/** Run one (strategy, seed) unit — the two seat-swapped games — tallying into `res`. */
export function runPair(stratKey: string, seed: number, maxTurns: number, res: ShardResult): void {
  const s = getCpuStrategy(stratKey);
  if (!s) throw new Error(`unknown strategy "${stratKey}"`);
  const rec = res.rec;
  const teamRng = makeRng(seed * 7919 + 17);
  const baseTeams: [number[], number[]] = [
    buildRandomTeam(teamRng).monIndices.map(Number),
    buildRandomTeam(teamRng).monIndices.map(Number),
  ];
  for (const swap of [false, true]) {
    const t: [number[], number[]] = swap ? [baseTeams[1], baseTeams[0]] : [baseTeams[0], baseTeams[1]];
    const hook = (info: any) => {
      const [a0, a1] = activeMonIndices(info.engine, info.battleKey);
      if (info.p0Move && info.p0Move.moveIndex < 4) {
        const id = t[0][a0];
        rec[id].moveCounts[info.p0Move.moveIndex]++;
        rec[id].moveTurns++;
      }
      if (info.p1Move && info.p1Move.moveIndex < 4) {
        const id = t[1][a1];
        rec[id].moveCounts[info.p1Move.moveIndex]++;
        rec[id].moveTurns++;
      }
    };
    const out = playGame(s, s, t, seed, maxTurns, hook);
    res.totalGames++;
    if ('error' in out) { res.errors++; continue; }
    const drew = out.winnerSeat === null;
    const tally = (id: number, seatWon: boolean) => {
      if (drew) rec[id].draws++;
      else if (seatWon) rec[id].wins++;
      else rec[id].losses++;
    };
    for (const id of new Set(t[0])) tally(id, out.winnerSeat === 0);
    for (const id of new Set(t[1])) tally(id, out.winnerSeat === 1);
  }
}

/** Run a list of work units into a fresh result (the unit of work a worker processes). */
export function runItems(items: WorkItem[], maxTurns: number): ShardResult {
  const res = newShardResult();
  for (const it of items) runPair(it.strat, it.seed, maxTurns, res);
  return res;
}

/** Fold `src` into `dst` (summation — commutative, so shard order is irrelevant). */
export function mergeInto(dst: ShardResult, src: ShardResult): void {
  dst.totalGames += src.totalGames;
  dst.errors += src.errors;
  for (const id of MON_IDS) {
    const a = dst.rec[id];
    const b = src.rec[id];
    if (!b) continue;
    a.wins += b.wins;
    a.losses += b.losses;
    a.draws += b.draws;
    a.moveTurns += b.moveTurns;
    for (let k = 0; k < 4; k++) a.moveCounts[k] += b.moveCounts[k];
  }
}
