// Batch-mode benchmark + mass outcome cross-check.
//
// Re-derives the EXACT arena_benchmark workload (shared generator in
// workload.ts, same seed constants), keeps the games whose strategies are
// all natively ported (currently every pair), and runs them via
// chomp_run_games — whole games in Rust, one FFI crossing per thread count.
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
import { makeSimContext } from '../../sims/src/harness';
import { loadRoster } from '../../sims/src/util/csv-load';
import { buildAddressBook, ffi, cstr, takeString } from '../../sims/src/arena/rust-engine';
import { buildBatchGames, buildWork } from './workload';

const GAMES = Number(process.argv[2] ?? 3000);
const THREAD_COUNTS = (process.argv[3] ?? '1,4').split(',').map(Number);
const MAX_TURNS = 150;
const JSONL = `/tmp/arena_bench_${GAMES}.jsonl`;

// Filter for pairs runnable natively — keeps the script correct if a
// TS-only experimental strategy ever joins the rotation.
const PORTED = new Set(['hard', 'greedy', 'override']);

const work = buildWork(GAMES, 0xbeefcafe, 10_000);
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
const games = buildBatchGames(ctx, roster, ported, MAX_TURNS);

for (const threads of THREAD_COUNTS) {
  // Payload built OUTSIDE the timed window: several MB of JSON stringify
  // would otherwise skew games/s (and grow as the engine gets faster).
  const payload = cstr(JSON.stringify({ monsPerTeam: TEAM_SIZE, addressBook, threads, trace: false, games }));
  const t0 = performance.now();
  const raw = ffi().symbols.chomp_run_games(ptr(payload));
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
