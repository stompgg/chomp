/**
 * Benchmark: what would the new search CPUs cost per decision in TypeScript?
 *
 * Measures the primitive the search is built from — a hypothetical fork (clone battle
 * + run one silent turn + capture view) — plus the existing 1-ply strategies for
 * context, on a real mid-game 4v4 position. Projects per-decision latency for the
 * search configs from the Rust-measured forks-per-decision bands.
 *
 *   bun arena/bench-search.ts
 */
import { makeSimContext, startBattle, executeTurn } from '../src/harness';
import { loadRoster } from '../src/util/csv-load';
import { buildTeamMon } from '../src/arena/team';
import { MemoizedInlineRngOracle } from '../src/arena/rng-oracle';
import { makeRng } from '../src/arena/rng';
import { captureBattleView } from '../src/cpu/battle-view';
import { applyHypotheticalMove } from '../src/cpu/forward-model';
import { CPU_STRATEGIES } from '../src/cpu/registry';
import * as Constants from '../../transpiler/ts-output/Constants';

const roster = loadRoster();
const SWITCH = Number(Constants.SWITCH_MOVE_INDEX);

// ── Stand up a 4v4 battle and walk it to a mid-game position ────────────────
const ctx = makeSimContext({ monsPerTeam: 4n });
const ids = roster.mons.map((m: any) => m.id);
const p0Team = ids.slice(0, 4).map((id: number) => buildTeamMon(ctx, roster, id));
const p1Team = ids.slice(4, 8).map((id: number) => buildTeamMon(ctx, roster, id));
const { battleKey } = startBattle(ctx, p0Team, p1Team);
const engine = ctx.engine as any;
engine.battleConfig[engine._getStorageKey(battleKey)].rngOracle = new MemoizedInlineRngOracle();

// Leads, then a few attack turns; resolve forced switches mid-walk (first legal bench) so the
// bench lands on a genuine both-act (flag == 2) position — the search's real per-turn workload.
executeTurn(ctx, battleKey, { p0MoveIndex: SWITCH, p1MoveIndex: SWITCH, p0ExtraData: 0n, p1ExtraData: 0n, p0Salt: 1n, p1Salt: 2n });
const NO_OP = Number(Constants.NO_OP_MOVE_INDEX);
const firstBench = (side: 0 | 1): bigint => {
  const ko = Number(engine.getKOBitmap(battleKey, BigInt(side)));
  const active = Number(engine.getActiveMonIndexForBattleState(battleKey)[side]);
  for (let i = 0; i < 4; i++) if (i !== active && (ko & (1 << i)) === 0) return BigInt(i);
  return 0n;
};
for (let t = 0; t < 6; t++) {
  const flag = Number(engine.getBattleContext(battleKey).playerSwitchForTurnFlag);
  if (flag === 2) {
    executeTurn(ctx, battleKey, {
      p0MoveIndex: 0, p1MoveIndex: 0, p0ExtraData: 0n, p1ExtraData: 0n,
      p0Salt: BigInt(100 + t), p1Salt: BigInt(200 + t),
    });
  } else {
    // Forced-switch turn: only the flagged side acts.
    executeTurn(ctx, battleKey, {
      p0MoveIndex: flag === 0 ? SWITCH : NO_OP, p1MoveIndex: flag === 1 ? SWITCH : NO_OP,
      p0ExtraData: flag === 0 ? firstBench(0) : 0n, p1ExtraData: flag === 1 ? firstBench(1) : 0n,
      p0Salt: BigInt(300 + t), p1Salt: BigInt(400 + t),
    });
  }
}
const finalFlag = Number(engine.getBattleContext(battleKey).playerSwitchForTurnFlag);
console.log(`mid-game position ready (turn ${engine.getTurnIdForBattleState(battleKey)}, flag ${finalFlag})`);

function bench(label: string, iters: number, warmup: number, f: () => void): number {
  for (let i = 0; i < warmup; i++) f();
  const t0 = performance.now();
  for (let i = 0; i < iters; i++) f();
  const ms = (performance.now() - t0) / iters;
  console.log(`${label.padEnd(34)} ${ms.toFixed(3)} ms/op  (${iters} iters)`);
  return ms;
}

// ── 1. The search primitive: hypothetical fork (fork + silent turn + view) ──
const msFork = bench('applyHypotheticalMove (1 fork)', 200, 20, () => {
  applyHypotheticalMove(engine, battleKey, { moveIndex: 0, salt: 0n, extraData: 0 }, { moveIndex: 0, salt: 0n, extraData: 0 });
});

// ── 2. Existing 1-ply strategies for context ─────────────────────────────────
const rng = makeRng(42);
const view = () => captureBattleView(engine, battleKey);
const greedy = CPU_STRATEGIES.get('greedy')!;
const hard = CPU_STRATEGIES.get('hard')!;
const msGreedy = bench('greedy.decide (1-ply)', 50, 5, () => {
  greedy.decide(view(), { moveIndex: 0, extraData: 0 }, rng, greedy.createState());
});
let msHard = Number.NaN;
try {
  msHard = bench('hard.decide (heuristic)', 50, 5, () => {
    hard.decide(view(), { moveIndex: 0, extraData: 0 }, rng, hard.createState());
  });
} catch (e) {
  console.log(`hard.decide: SKIPPED (stale vs current engine surface: ${(e as Error).message})`);
}

// ── 3. REAL search decisions (the ported SearchCpu) ─────────────────────────
import { SearchCpu } from '../src/cpu/strategies/search-cpu';
for (const [label, depth, peek, iters] of [
  ['search d1 no-peek', 1, false, 20],
  ['search d2 PEEK', 2, true, 10],
  ['search d2 no-peek', 2, false, 5],
] as Array<[string, number, boolean, number]>) {
  const s = new SearchCpu(label, depth, peek);
  bench(`${label}.decide`, iters, 2, () => {
    s.decide(view(), { moveIndex: 0, extraData: 0 }, rng, s.createState());
  });
}
console.log(`\nms/fork: TS=${msFork.toFixed(3)}  (greedy decision=${msGreedy.toFixed(1)}ms, hard=${msHard.toFixed(1)}ms)`);
