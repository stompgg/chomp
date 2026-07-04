// Batch-mode benchmark + mass outcome cross-check.
//
// Regenerates the EXACT arena_benchmark workload (same xorshift seed →
// same teams/seeds), keeps the games whose strategy pair is fully ported
// (hard/greedy on both seats), and runs them natively via chomp_run_games
// — whole games in Rust, one FFI crossing per batch per thread count.
//
// Every game's (winner, turns) is cross-checked against the TS-engine
// results in /tmp/arena_bench_<N>.jsonl (written by arena_benchmark.ts),
// so the batch numbers double as a mass lockstep gate on top of the
// per-turn strategy_lockstep gate.
//
//   bun transpiler/scripts/batch_benchmark.ts [gamesPerEngine] [threadsCsv]
//   (defaults: 3000, "1,4" — must match the arena_benchmark run's N)

import { readFileSync } from 'node:fs';
import { ptr } from 'bun:ffi';
import { TEAM_SIZE } from '../../sims/src/cpu/constants';
import type { DraftedMon } from '../../sims/src/arena/team';
import { makeSimContext } from '../../sims/src/harness';
import { loadRoster } from '../../sims/src/util/csv-load';
import { buildTeamMon } from '../../sims/src/arena/team';
import { buildAddressBook, ffi, cstr, takeString, monToJson } from '../../sims/src/arena/rust-engine';

const GAMES = Number(process.argv[2] ?? 3000);
const THREAD_COUNTS = (process.argv[3] ?? '1,4').split(',').map(Number);
const MAX_TURNS = 150;
const NUM_MONS = 13;
const JSONL = `/tmp/arena_bench_${GAMES}.jsonl`;

// Identical workload generation to arena_benchmark.ts (same seed).
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
const PORTED = new Set(['hard', 'greedy', 'override']);

interface WorkItem {
  idx: number;
  strats: [string, string]; // [p1Strategy, p0Strategy] — arena_benchmark seating
  teams: [DraftedMon[], DraftedMon[]];
  seed: number;
}
const work: WorkItem[] = [];
for (let i = 0; i < GAMES; i++) {
  work.push({
    idx: i,
    strats: STRAT_PAIRS[i % STRAT_PAIRS.length],
    teams: [drawTeam(), drawTeam()], // MUST draw for every game to keep the stream aligned
    seed: 10_000 + i,
  });
}
const ported = work.filter((w) => PORTED.has(w.strats[0]) && PORTED.has(w.strats[1]));
console.log(`workload: ${ported.length}/${GAMES} games have fully-ported pairs`);

// Reference outcomes from the arena_benchmark TS-engine leg.
const tsRef = new Map<number, { winner: number | null; turns: number }>();
for (const line of readFileSync(JSONL, 'utf8').split('\n')) {
  if (!line) continue;
  const r = JSON.parse(line);
  if (r.engine === 'ts') tsRef.set(r.idx, { winner: r.winner, turns: r.turns });
}
if (tsRef.size < GAMES) {
  throw new Error(`only ${tsRef.size}/${GAMES} ts results in ${JSONL} — run arena_benchmark first`);
}

// Serialize teams once (addresses are deterministic across contexts).
const ctx = makeSimContext({ monsPerTeam: BigInt(TEAM_SIZE) });
const roster = loadRoster();
const addressBook = buildAddressBook(ctx);
const games = ported.map((w) => ({
  seed: w.seed,
  maxTurns: MAX_TURNS,
  p0Strategy: w.strats[1],
  p1Strategy: w.strats[0],
  p0Team: w.teams[0].map((dm) => monToJson(buildTeamMon(ctx, roster, dm.id, dm.equip))),
  p1Team: w.teams[1].map((dm) => monToJson(buildTeamMon(ctx, roster, dm.id, dm.equip))),
}));

for (const threads of THREAD_COUNTS) {
  const cfg = { monsPerTeam: TEAM_SIZE, addressBook, threads, trace: false, games };
  const t0 = performance.now();
  const raw = ffi().symbols.chomp_run_games(ptr(cstr(JSON.stringify(cfg))));
  const sec = (performance.now() - t0) / 1000;
  const out = JSON.parse(takeString(raw, 'chomp_run_games')) as {
    results: { winnerSeat: number | null; turns: number; error?: string }[];
  };

  let mismatches = 0;
  let errors = 0;
  let totalTurns = 0;
  for (let i = 0; i < ported.length; i++) {
    const r = out.results[i];
    if (r.error) {
      errors++;
      if (errors <= 5) console.log(`ERROR game ${ported[i].idx}: ${r.error}`);
      continue;
    }
    totalTurns += r.turns;
    const ref = tsRef.get(ported[i].idx)!;
    if (r.winnerSeat !== ref.winner || r.turns !== ref.turns) {
      mismatches++;
      if (mismatches <= 5) {
        console.log(
          `OUTCOME MISMATCH game ${ported[i].idx} (${ported[i].strats.join('v')}): ` +
          `batch=${r.winnerSeat}/${r.turns}t ts=${ref.winner}/${ref.turns}t`,
        );
      }
    }
  }
  console.log(
    `[batch t=${threads}] ${ported.length} games in ${sec.toFixed(1)}s ` +
    `(${(ported.length / sec).toFixed(1)} games/s, ${(totalTurns / sec).toFixed(0)} turns/s), ` +
    `outcome mismatches vs ts: ${mismatches}, errors: ${errors}`,
  );
}
