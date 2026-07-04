// Large-scale arena benchmark: the SAME varied workload (strategy pairings x
// randomized rosters x seeds) on the TS engine and the Rust engine.
//
//   bun transpiler/scripts/arena_benchmark.ts [gamesPerEngine]
//
// Because the engines are move-for-move identical, this doubles as a mass
// outcome-equality check: every game's (winner, turns) must MATCH across
// engines — thousands of full games worth of lockstep on top of the gates.
//
// Results stream to /tmp as JSONL (crash-safe); the summary table prints at
// the end.

import { appendFileSync, writeFileSync } from 'node:fs';
import { playGame, type EngineKind } from '../../sims/src/arena/game';
import { getCpuStrategy } from '../../sims/src/cpu/registry';
import { TEAM_SIZE } from '../../sims/src/cpu/constants';
import type { DraftedMon } from '../../sims/src/arena/team';

const GAMES = Number(process.argv[2] ?? 3000);
const MAX_TURNS = 150;
const OUT = `/tmp/arena_bench_${GAMES}.jsonl`;
const NUM_MONS = 13;

// Deterministic workload generation (xorshift32) — identical for both engines.
let wseed = 0xbeefcafe >>> 0;
function wrand(): number {
  wseed ^= wseed << 13; wseed >>>= 0;
  wseed ^= wseed >> 17;
  wseed ^= wseed << 5; wseed >>>= 0;
  return wseed / 0x100000000;
}

function drawTeam(): DraftedMon[] {
  const pool = Array.from({ length: NUM_MONS }, (_, i) => i);
  const ids: number[] = [];
  for (let k = 0; k < TEAM_SIZE; k++) {
    ids.push(pool.splice(Math.floor(wrand() * pool.length), 1)[0]);
  }
  return ids.map((id) => ({ id, equip: undefined as any }));
}

const STRAT_PAIRS: [string, string][] = [
  ['hard', 'hard'],
  ['hard', 'greedy'],
  ['greedy', 'hard'],
  ['greedy', 'greedy'],
  ['override', 'greedy'],
  ['override', 'hard'],
];

interface WorkItem {
  idx: number;
  strats: [string, string];
  teams: [DraftedMon[], DraftedMon[]];
  seed: number;
}

const work: WorkItem[] = [];
for (let i = 0; i < GAMES; i++) {
  work.push({
    idx: i,
    strats: STRAT_PAIRS[i % STRAT_PAIRS.length],
    teams: [drawTeam(), drawTeam()],
    seed: 10_000 + i,
  });
}

interface GameResult {
  engine: EngineKind;
  idx: number;
  pair: string;
  winner: 0 | 1 | null;
  turns: number;
  ms: number;
}

function runEngine(kind: EngineKind): GameResult[] {
  const results: GameResult[] = [];
  const t0 = performance.now();
  for (const w of work) {
    const s1 = getCpuStrategy(w.strats[0])!;
    const s0 = getCpuStrategy(w.strats[1])!;
    const g0 = performance.now();
    const out = playGame(s1, s0, w.teams, w.seed, MAX_TURNS, undefined, kind);
    const ms = performance.now() - g0;
    if ('error' in out) throw new Error(`${kind} game ${w.idx} (${w.strats.join('v')}): ${out.error}`);
    const r: GameResult = {
      engine: kind, idx: w.idx, pair: w.strats.join('v'),
      winner: out.winnerSeat, turns: out.turns, ms,
    };
    results.push(r);
    appendFileSync(OUT, JSON.stringify(r) + '\n');
    if ((w.idx + 1) % 200 === 0) {
      const el = (performance.now() - t0) / 1000;
      console.log(`[${kind}] ${w.idx + 1}/${GAMES} games, ${el.toFixed(0)}s elapsed (${((w.idx + 1) / el).toFixed(1)} games/s)`);
    }
  }
  return results;
}

function pct(sorted: number[], p: number): number {
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
}

function summarize(rs: GameResult[]) {
  const ms = rs.map((r) => r.ms).sort((a, b) => a - b);
  const totalMs = rs.reduce((s, r) => s + r.ms, 0);
  const totalTurns = rs.reduce((s, r) => s + r.turns, 0);
  return {
    games: rs.length,
    totalSec: totalMs / 1000,
    gamesPerSec: rs.length / (totalMs / 1000),
    turnsPerSec: totalTurns / (totalMs / 1000),
    meanMs: totalMs / rs.length,
    p50: pct(ms, 0.5),
    p95: pct(ms, 0.95),
    totalTurns,
  };
}

writeFileSync(OUT, '');
console.log(`workload: ${GAMES} games x 2 engines, ${STRAT_PAIRS.length} strategy pairs, randomized 4v4 rosters, maxTurns=${MAX_TURNS}`);

const rust = runEngine('rust');
const ts = runEngine('ts');

// Outcome agreement (the engines must be play-identical).
let mismatches = 0;
for (let i = 0; i < GAMES; i++) {
  if (rust[i].winner !== ts[i].winner || rust[i].turns !== ts[i].turns) {
    mismatches++;
    if (mismatches <= 5) {
      console.log(`OUTCOME MISMATCH game ${i} (${work[i].strats.join('v')}): rust=${rust[i].winner}/${rust[i].turns}t ts=${ts[i].winner}/${ts[i].turns}t`);
    }
  }
}

const byPair = new Map<string, { rust: GameResult[]; ts: GameResult[] }>();
for (const r of rust) {
  const b = byPair.get(r.pair) ?? { rust: [], ts: [] };
  b.rust.push(r); byPair.set(r.pair, b);
}
for (const r of ts) byPair.get(r.pair)!.ts.push(r);

const R = summarize(rust);
const T = summarize(ts);
console.log('\n===== SUMMARY =====');
console.log(JSON.stringify({
  games: GAMES,
  outcomeMismatches: mismatches,
  rust: R,
  ts: T,
  speedup: { gamesPerSec: R.gamesPerSec / T.gamesPerSec, meanMs: T.meanMs / R.meanMs },
  byPair: [...byPair.entries()].map(([pair, b]) => {
    const r = summarize(b.rust); const t = summarize(b.ts);
    return { pair, games: b.rust.length, rustGps: r.gamesPerSec, tsGps: t.gamesPerSec, speedup: r.gamesPerSec / t.gamesPerSec, meanTurns: r.totalTurns / b.rust.length };
  }),
}, null, 1));
console.log(`\nresults: ${OUT}`);
