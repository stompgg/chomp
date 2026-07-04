// Arena engine lockstep: play the SAME games (same seed, same strategies,
// same teams) on the TS engine and the Rust engine and require them to be
// MOVE-FOR-MOVE identical. Both engines derive rng from keccak(p0Salt,
// p1Salt) (memoized oracle on TS, inline zero-oracle path on Rust — byte-
// identical values), and strategies are deterministic given the seeded JS
// rng — so any divergence is an engine or adapter bug, localized to the
// first differing turn.
//
//   cargo build --release -p chomp-ffi   (in transpiler/rs-output)
//   bun transpiler/scripts/arena_rust_lockstep.ts
//
// Also prints games/sec for both drives (the number mon-prototyping
// iteration speed actually depends on).

import { playGame, type EngineKind } from '../../sims/src/arena/game';
import { getCpuStrategy } from '../../sims/src/cpu/registry';
import { TEAM_SIZE } from '../../sims/src/cpu/constants';
import type { DraftedMon } from '../../sims/src/arena/team';

interface TurnLog { p0: string; p1: string }

function playLogged(kind: EngineKind, stratKeys: [string, string], teams: [DraftedMon[], DraftedMon[]], seed: number) {
  const s1 = getCpuStrategy(stratKeys[0])!;
  const s0 = getCpuStrategy(stratKeys[1])!;
  const log: TurnLog[] = [];
  const outcome = playGame(s1, s0, teams, seed, 120, ({ p0Move, p1Move }) => {
    log.push({
      p0: p0Move ? `${p0Move.moveIndex}/${p0Move.extraData}` : '-',
      p1: p1Move ? `${p1Move.moveIndex}/${p1Move.extraData}` : '-',
    });
  }, kind);
  return { outcome, log };
}

const team = (ids: number[]): DraftedMon[] => ids.map((id) => ({ id, equip: undefined as any }));

const MATCHUPS: { name: string; teams: [DraftedMon[], DraftedMon[]] }[] = [
  { name: 'A', teams: [team([0, 1, 2, 3]), team([4, 5, 6, 7])] },
  { name: 'B', teams: [team([8, 9, 10, 11]), team([12, 0, 5, 9])] },
  { name: 'C', teams: [team([2, 6, 12, 4]), team([1, 10, 3, 8])] },
];
const STRATS: [string, string][] = [['hard', 'greedy'], ['greedy', 'hard'], ['hard', 'hard']];
const SEEDS = [11, 42, 1337];

if (MATCHUPS[0].teams[0].length !== TEAM_SIZE) throw new Error('team size mismatch');

let games = 0;
let turnsCompared = 0;
for (const m of MATCHUPS) {
  for (const strats of STRATS) {
    for (const seed of SEEDS) {
      const label = `${m.name} ${strats.join('v')} seed=${seed}`;
      const ts = playLogged('ts', strats, m.teams, seed);
      const rs = playLogged('rust', strats, m.teams, seed);
      if ('error' in ts.outcome) throw new Error(`${label}: TS errored: ${ts.outcome.error}`);
      if ('error' in rs.outcome) throw new Error(`${label}: RUST errored: ${rs.outcome.error}`);
      const n = Math.max(ts.log.length, rs.log.length);
      for (let t = 0; t < n; t++) {
        const a = ts.log[t]; const b = rs.log[t];
        if (!a || !b || a.p0 !== b.p0 || a.p1 !== b.p1) {
          throw new Error(`${label}: DIVERGED at turn ${t}: ts=${JSON.stringify(a)} rust=${JSON.stringify(b)}`);
        }
      }
      if (ts.outcome.winnerSeat !== rs.outcome.winnerSeat || ts.outcome.turns !== rs.outcome.turns) {
        throw new Error(`${label}: outcome mismatch ts=${JSON.stringify(ts.outcome)} rust=${JSON.stringify(rs.outcome)}`);
      }
      games++;
      turnsCompared += ts.log.length;
    }
  }
}
console.log(`arena lockstep: ${games} games, ${turnsCompared} turns move-for-move identical (TS vs Rust)`);

// ---------------------------------------------------------------------------
// Throughput: same workload on each engine.
// ---------------------------------------------------------------------------
function bench(kind: EngineKind, rounds: number): { games: number; ms: number } {
  const t0 = performance.now();
  let n = 0;
  for (let r = 0; r < rounds; r++) {
    for (const m of MATCHUPS) {
      const out = playGame(getCpuStrategy('hard')!, getCpuStrategy('greedy')!, m.teams, 1000 + r, 120, undefined, kind);
      if ('error' in out) throw new Error(`bench ${kind}: ${out.error}`);
      n++;
    }
  }
  return { games: n, ms: performance.now() - t0 };
}

const rsB = bench('rust', 10);
const tsB = bench('ts', 10);
const rsRate = rsB.games / (rsB.ms / 1000);
const tsRate = tsB.games / (tsB.ms / 1000);
console.log(`bench: rust ${rsRate.toFixed(1)} games/sec vs ts ${tsRate.toFixed(1)} games/sec — ${(rsRate / tsRate).toFixed(1)}x`);
