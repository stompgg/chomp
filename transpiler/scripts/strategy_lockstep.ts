// Strategy-port lockstep gate: the NATIVE Rust strategies (chomp_run_games,
// batch mode) must re-derive, turn by turn, the exact moves the TS
// strategies pick on identical (seed, teams, pairing) — and land the same
// (winner, turns). This is the phase gate for the hard/greedy port.
//
//   bun transpiler/scripts/strategy_lockstep.ts [games]
//
// Also prints wall-clock for both legs; the Rust leg's games/s is the
// batch-mode headline (one FFI crossing for the WHOLE batch).

import { ptr } from 'bun:ffi';
import { playGame } from '../../sims/src/arena/game';
import { getCpuStrategy } from '../../sims/src/cpu/registry';
import { TEAM_SIZE } from '../../sims/src/cpu/constants';
import type { DraftedMon } from '../../sims/src/arena/team';
import type { PlayerMove } from '../../sims/src/cpu/strategy';
import { makeSimContext } from '../../sims/src/harness';
import { loadRoster } from '../../sims/src/util/csv-load';
import { buildTeamMon } from '../../sims/src/arena/team';
import { contractAddresses } from '../ts-output/runtime';
import { ffi, cstr, takeString, monToJson } from '../../sims/src/arena/rust-engine';

const GAMES = Number(process.argv[2] ?? 40);
const MAX_TURNS = 150;
const NUM_MONS = 13;

// Deterministic workload (xorshift32) — hard/greedy pairs only (the two
// ported strategies).
let wseed = 0x5eedf00d >>> 0;
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

// [p1Strategy, p0Strategy] — matching playGame(stratP1, stratP0, ...).
const PAIRS: [string, string][] = [
  ['hard', 'hard'],
  ['hard', 'greedy'],
  ['greedy', 'hard'],
  ['greedy', 'greedy'],
  ['override', 'greedy'],
  ['override', 'hard'],
];

interface WorkItem {
  idx: number;
  p1Strategy: string;
  p0Strategy: string;
  teams: [DraftedMon[], DraftedMon[]];
  seed: number;
}
const work: WorkItem[] = [];
for (let i = 0; i < GAMES; i++) {
  const [p1s, p0s] = PAIRS[i % PAIRS.length];
  work.push({ idx: i, p1Strategy: p1s, p0Strategy: p0s, teams: [drawTeam(), drawTeam()], seed: 20_000 + i });
}

type Turn = [PlayerMove | null, PlayerMove | null]; // [p0, p1]

// ---------------------------------------------------------------------------
// TS reference leg (TS engine + TS strategies), tracing per-turn moves.
// ---------------------------------------------------------------------------
console.log(`strategy lockstep: ${GAMES} games (hard/greedy/override pairs), maxTurns=${MAX_TURNS}`);
const tsTraces: Turn[][] = [];
const tsOutcomes: { winner: 0 | 1 | null; turns: number }[] = [];
const t0 = performance.now();
for (const w of work) {
  const trace: Turn[] = [];
  const out = playGame(
    getCpuStrategy(w.p1Strategy)!, getCpuStrategy(w.p0Strategy)!,
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
const addressBook: Record<string, string> = {};
for (const name of (ctx.container as any).getRegisteredNames()) {
  addressBook[name] = contractAddresses.getAddress(name);
}
const cfg = {
  monsPerTeam: TEAM_SIZE,
  addressBook,
  threads: 1,
  trace: true,
  games: work.map((w) => ({
    seed: w.seed,
    maxTurns: MAX_TURNS,
    p0Strategy: w.p0Strategy,
    p1Strategy: w.p1Strategy,
    p0Team: w.teams[0].map((dm) => monToJson(buildTeamMon(ctx, roster, dm.id, dm.equip))),
    p1Team: w.teams[1].map((dm) => monToJson(buildTeamMon(ctx, roster, dm.id, dm.equip))),
  })),
};
const t1 = performance.now();
const rawOut = ffi().symbols.chomp_run_games(ptr(cstr(JSON.stringify(cfg))));
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
  const label = `game ${i} (p1=${work[i].p1Strategy} p0=${work[i].p0Strategy} seed=${work[i].seed})`;
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
