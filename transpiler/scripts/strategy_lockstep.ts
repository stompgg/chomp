// Strategy-port lockstep gate: the NATIVE Rust strategies (chomp_run_games,
// batch mode) must re-derive, turn by turn, the exact moves the TS
// strategies pick on identical (seed, teams, pairing) — and land the same
// (winner, turns). This is the sync gate between the two strategy stacks.
//
//   bun transpiler/scripts/strategy_lockstep.ts [games]
//
// Also prints wall-clock for both legs; the Rust leg's games/s is the
// batch-mode headline (one FFI crossing for the WHOLE batch).

import { ptr } from 'bun:ffi';
import { playGame } from '../../sims/src/arena/game';
import { getCpuStrategy } from '../../sims/src/cpu/registry';
import { TEAM_SIZE } from '../../sims/src/cpu/constants';
import type { PlayerMove } from '../../sims/src/cpu/strategy';
import { makeSimContext } from '../../sims/src/harness';
import { loadRoster } from '../../sims/src/util/csv-load';
import { buildAddressBook, ffi, cstr, takeString } from '../../sims/src/arena/rust-engine';
import { buildBatchGames, buildWork } from './workload';

const GAMES = Number(process.argv[2] ?? 40);
const MAX_TURNS = 150;

// Own seed/seed-base (distinct games from the benchmark workload), same
// shared generator + pair rotation.
const work = buildWork(GAMES, 0x5eedf00d, 20_000);

type Turn = [PlayerMove | null, PlayerMove | null]; // [p0, p1]

// ---------------------------------------------------------------------------
// TS reference leg (TS engine + TS strategies), tracing per-turn moves.
// ---------------------------------------------------------------------------
console.log(`strategy lockstep: ${GAMES} games (all strategy pairs), maxTurns=${MAX_TURNS}`);
const tsTraces: Turn[][] = [];
const tsOutcomes: { winner: 0 | 1 | null; turns: number }[] = [];
const t0 = performance.now();
for (const w of work) {
  const trace: Turn[] = [];
  const out = playGame(
    getCpuStrategy(w.strats[0])!, getCpuStrategy(w.strats[1])!,
    w.teams, w.seed, MAX_TURNS,
    ({ p0Move, p1Move }) => { trace.push([p0Move, p1Move]); },
    'ts',
  );
  if ('error' in out) throw new Error(`ts game ${w.idx}: ${out.error}`);
  tsTraces.push(trace);
  tsOutcomes.push({ winner: out.winnerSeat, turns: out.turns });
}
const tsSec = (performance.now() - t0) / 1000;
console.log(`[ts]   ${GAMES} games in ${tsSec.toFixed(1)}s (${(GAMES / tsSec).toFixed(2)} games/s)`);

// ---------------------------------------------------------------------------
// Rust batch leg (native strategies + native engine, ONE ffi crossing).
// ---------------------------------------------------------------------------
const ctx = makeSimContext({ monsPerTeam: BigInt(TEAM_SIZE) });
const roster = loadRoster();
const cfg = {
  monsPerTeam: TEAM_SIZE,
  addressBook: buildAddressBook(ctx),
  threads: 1,
  trace: true,
  games: buildBatchGames(ctx, roster, work, MAX_TURNS),
};
// Payload built outside the timed window (several MB of JSON stringify).
const payload = cstr(JSON.stringify(cfg));
const t1 = performance.now();
const rawOut = ffi().symbols.chomp_run_games(ptr(payload));
const rsSec = (performance.now() - t1) / 1000;
const parsed = JSON.parse(takeString(rawOut, 'chomp_run_games')) as {
  results: { winnerSeat: 0 | 1 | null; turns: number; moves?: ([number, number] | null)[][]; error?: string }[];
};
console.log(`[rust] ${GAMES} games in ${rsSec.toFixed(1)}s (${(GAMES / rsSec).toFixed(2)} games/s, batch, 1 thread)`);

// ---------------------------------------------------------------------------
// Compare: outcomes + per-turn move equality.
// ---------------------------------------------------------------------------
let mismatches = 0;
const complain = (msg: string) => {
  mismatches++;
  if (mismatches <= 10) console.log(`MISMATCH ${msg}`);
};

for (let i = 0; i < GAMES; i++) {
  const r = parsed.results[i];
  const label = `game ${i} (p1=${work[i].strats[0]} p0=${work[i].strats[1]} seed=${work[i].seed})`;
  if (r.error) { complain(`${label}: rust error: ${r.error}`); continue; }
  const ts = tsOutcomes[i];
  if (r.winnerSeat !== ts.winner || r.turns !== ts.turns) {
    complain(`${label}: outcome rust=${r.winnerSeat}/${r.turns}t ts=${ts.winner}/${ts.turns}t`);
  }
  const tsTrace = tsTraces[i];
  const rsTrace = r.moves ?? [];
  const n = Math.min(tsTrace.length, rsTrace.length);
  for (let t = 0; t < n; t++) {
    for (const side of [0, 1] as const) {
      const tm = tsTrace[t][side];
      const rm = rsTrace[t][side];
      const tEnc = tm === null ? null : [tm.moveIndex, tm.extraData];
      const same =
        (tEnc === null && rm === null) ||
        (tEnc !== null && rm !== null && tEnc[0] === rm[0] && tEnc[1] === rm[1]);
      if (!same) {
        complain(`${label} turn ${t} p${side}: ts=${JSON.stringify(tEnc)} rust=${JSON.stringify(rm)}`);
        t = n; // first divergent turn is the signal; later turns cascade
        break;
      }
    }
  }
  if (tsTrace.length !== rsTrace.length && r.winnerSeat === ts.winner && r.turns === ts.turns) {
    complain(`${label}: trace length ts=${tsTrace.length} rust=${rsTrace.length}`);
  }
}

if (mismatches > 0) {
  console.log(`\nFAIL: ${mismatches} mismatch(es) across ${GAMES} games`);
  process.exit(1);
}
console.log(`\nOK: ${GAMES} games move-for-move identical (outcomes + every turn's submissions)`);
console.log(`batch-mode speedup vs TS arena on this workload: ${(tsSec / rsSec).toFixed(1)}x (single-thread)`);
