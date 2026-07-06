// Pure batch-mode benchmark: whole games on the native Rust stack via
// chomp_run_games, one FFI crossing per thread count. Reports games/s and
// turns/s — no TS cross-check (the stacks are decoupled).
//
//   bun transpiler/scripts/batch_benchmark.ts [games] [threadsCsv]
//   (defaults: 3000, "1,4")

import { ptr } from 'bun:ffi';
import { TEAM_SIZE } from '../../sims/src/cpu/constants';
import { makeSimContext } from '../../sims/src/harness';
import { loadRoster } from '../../sims/src/util/csv-load';
import { buildAddressBook, ffi, cstr, takeString } from '../../sims/src/arena/rust-ffi';
import { buildBatchGames, buildWork } from './workload';

const GAMES = Number(process.argv[2] ?? 3000);
const THREAD_COUNTS = (process.argv[3] ?? '1,4').split(',').map(Number);
const MAX_TURNS = 150;

const work = buildWork(GAMES, 0xbeefcafe, 10_000);
const ctx = makeSimContext({ monsPerTeam: BigInt(TEAM_SIZE) });
const roster = loadRoster();
const addressBook = buildAddressBook(ctx);
const games = buildBatchGames(ctx, roster, work, MAX_TURNS);
console.log(`workload: ${GAMES} games, ${THREAD_COUNTS.join('/')} thread configs, maxTurns=${MAX_TURNS}`);

for (const threads of THREAD_COUNTS) {
  // Payload built OUTSIDE the timed window: several MB of JSON stringify
  // would otherwise skew games/s.
  const payload = cstr(JSON.stringify({ monsPerTeam: TEAM_SIZE, addressBook, threads, trace: false, games }));
  const t0 = performance.now();
  const raw = ffi().symbols.chomp_run_games(ptr(payload));
  const sec = (performance.now() - t0) / 1000;
  const out = JSON.parse(takeString(raw, 'chomp_run_games')) as {
    results: { winnerSeat: number | null; turns: number; error?: string }[];
  };

  let errors = 0;
  let totalTurns = 0;
  for (const r of out.results) {
    if (r.error) {
      errors++;
      if (errors <= 5) console.log(`ERROR: ${r.error}`);
      continue;
    }
    totalTurns += r.turns;
  }
  console.log(
    `[batch t=${threads}] ${GAMES} games in ${sec.toFixed(1)}s ` +
    `(${(GAMES / sec).toFixed(1)} games/s, ${(totalTurns / sec).toFixed(0)} turns/s), errors: ${errors}`,
  );
}
