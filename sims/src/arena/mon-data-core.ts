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
import { playGame, type EngineKind } from './game';
import { draftMoveSelection, type DraftedMon } from './team';

export interface MonRec {
  wins: number;
  losses: number;
  draws: number;
  moveUsed: number[];     // per catalog lane: move-turns this mon chose that move
  moveEquipped: number[]; // per catalog lane: drafts that fielded that move
  moveTurns: number;      // total move-turns for this mon (denominator for used%)
  drafts: number;         // team-slots this mon was drafted into (denominator for equip%)
}

export interface ShardResult {
  rec: Record<number, MonRec>;
  /** Flat matchup tally: pairWins[a * PAIR_STRIDE + b] = decided games where a mon `a` stood on the
   *  winning side and a mon `b` on the losing side. Win rate of a vs b = wins[a,b]/(wins[a,b]+wins[b,a]). */
  pairWins: number[];
  totalGames: number;
  errors: number;
}

export interface WorkItem {
  strat: string;
  seed: number;
}

export const MON_IDS: number[] = Object.keys(MonMetadata).map(Number);
export const PAIR_STRIDE = Math.max(...MON_IDS) + 1;

// Catalog length per mon = the number of moves it could field (MonMetadata.moves is the full catalog).
const catalogLen = (id: number): number => (MonMetadata as any)[id].moves.length;

export function newShardResult(): ShardResult {
  const rec: Record<number, MonRec> = {};
  for (const id of MON_IDS) {
    const n = catalogLen(id);
    rec[id] = { wins: 0, losses: 0, draws: 0, moveUsed: new Array(n).fill(0), moveEquipped: new Array(n).fill(0), moveTurns: 0, drafts: 0 };
  }
  return { rec, pairWins: new Array(PAIR_STRIDE * PAIR_STRIDE).fill(0), totalGames: 0, errors: 0 };
}

/** Run one (strategy, seed) unit — the two seat-swapped games — tallying into `res`. */
export function runPair(stratKey: string, seed: number, maxTurns: number, res: ShardResult, engine: EngineKind = 'ts'): void {
  const s = getCpuStrategy(stratKey);
  if (!s) throw new Error(`unknown strategy "${stratKey}"`);
  const rec = res.rec;
  const teamRng = makeRng(seed * 7919 + 17);
  const baseIds: [number[], number[]] = [
    buildRandomTeam(teamRng).monIndices.map(Number),
    buildRandomTeam(teamRng).monIndices.map(Number),
  ];
  // Max-level loadouts come off a SEPARATE stream so the team-draw rng above stays byte-locked to munch.
  const moveRng = makeRng(seed * 6151 + 23);
  const draft = (ids: number[]): DraftedMon[] => ids.map((id) => ({ id, equip: draftMoveSelection(catalogLen(id), moveRng) }));
  const baseTeams: [DraftedMon[], DraftedMon[]] = [draft(baseIds[0]), draft(baseIds[1])];
  // Equip is fixed per drafted slot (unchanged across the seat swap), so count equip stats once here.
  for (const side of baseTeams) {
    for (const dm of side) {
      rec[dm.id].drafts++;
      for (const lane of dm.equip) rec[dm.id].moveEquipped[lane]++;
    }
  }
  for (const swap of [false, true]) {
    const t: [DraftedMon[], DraftedMon[]] = swap ? [baseTeams[1], baseTeams[0]] : [baseTeams[0], baseTeams[1]];
    const hook = (info: any) => {
      const [a0, a1] = activeMonIndices(info.engine, info.battleKey);
      const tally = (dm: DraftedMon, moveIndex: number) => {
        // Map the played battle slot back to its catalog lane via this draft's equip.
        const lane = dm.equip[Math.min(moveIndex, dm.equip.length - 1)];
        rec[dm.id].moveUsed[lane]++;
        rec[dm.id].moveTurns++;
      };
      if (info.p0Move && info.p0Move.moveIndex < 4) tally(t[0][a0], info.p0Move.moveIndex);
      if (info.p1Move && info.p1Move.moveIndex < 4) tally(t[1][a1], info.p1Move.moveIndex);
    };
    const out = playGame(s, s, t, seed, maxTurns, hook, engine);
    res.totalGames++;
    if ('error' in out) { res.errors++; continue; }
    const drew = out.winnerSeat === null;
    const tally = (id: number, seatWon: boolean) => {
      if (drew) rec[id].draws++;
      else if (seatWon) rec[id].wins++;
      else rec[id].losses++;
    };
    for (const id of new Set(t[0].map((d) => d.id))) tally(id, out.winnerSeat === 0);
    for (const id of new Set(t[1].map((d) => d.id))) tally(id, out.winnerSeat === 1);
    if (!drew) {
      const winners = new Set(t[out.winnerSeat === 0 ? 0 : 1].map((d) => d.id));
      const losers = new Set(t[out.winnerSeat === 0 ? 1 : 0].map((d) => d.id));
      for (const w of winners) for (const l of losers) res.pairWins[w * PAIR_STRIDE + l]++;
    }
  }
}

/** Run a list of work units into a fresh result (the unit of work a worker processes). */
export function runItems(items: WorkItem[], maxTurns: number, engine: EngineKind = 'ts'): ShardResult {
  const res = newShardResult();
  for (const it of items) runPair(it.strat, it.seed, maxTurns, res, engine);
  return res;
}

/** Fold `src` into `dst` (summation — commutative, so shard order is irrelevant). */
export function mergeInto(dst: ShardResult, src: ShardResult): void {
  dst.totalGames += src.totalGames;
  dst.errors += src.errors;
  if (src.pairWins) for (let i = 0; i < dst.pairWins.length; i++) dst.pairWins[i] += src.pairWins[i];
  for (const id of MON_IDS) {
    const a = dst.rec[id];
    const b = src.rec[id];
    if (!b) continue;
    a.wins += b.wins;
    a.losses += b.losses;
    a.draws += b.draws;
    a.moveTurns += b.moveTurns;
    a.drafts += b.drafts;
    for (let k = 0; k < a.moveUsed.length; k++) {
      a.moveUsed[k] += b.moveUsed[k];
      a.moveEquipped[k] += b.moveEquipped[k];
    }
  }
}
