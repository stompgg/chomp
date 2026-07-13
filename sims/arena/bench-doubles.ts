/**
 * Doubles TS benchmark + win-rate: the ported joint maximin search (side 1) vs the greedy "Hard"
 * pilot (side 0). Rust reference: search d1 ≈ 57.5% vs Hard; d1 decision ≈ sub-ms native.
 *
 *   bun arena/bench-doubles.ts [games]
 */
import { makeSimContext, startBattle, executeSlotTurn } from '../src/harness';
import { loadRoster } from '../src/util/csv-load';
import { buildTeamMon } from '../src/arena/team';
import { MemoizedInlineRngOracle } from '../src/arena/rng-oracle';
import { makeRng } from '../src/arena/rng';
import { packSide } from '../src/cpu/forward-model';
import { searchSideMoves, greedySideMoves, type SlotMove } from '../src/cpu/doubles-search';

const games = Number(process.argv[2] ?? 20);
const roster = loadRoster();
const allIds = roster.mons.map((m) => m.id);

type Ctx = ReturnType<typeof makeSimContext>;

function newDoublesBattle(seed: number): { ctx: Ctx; bk: `0x${string}` } {
  const rng = makeRng(seed);
  const pool = [...allIds];
  const draw = (): number => pool.splice(Math.floor(rng() * pool.length), 1)[0];
  const ctx = makeSimContext({ monsPerTeam: 4n });
  const p0 = [draw(), draw(), draw(), draw()].map((id) => buildTeamMon(ctx, roster, id));
  const p1 = [draw(), draw(), draw(), draw()].map((id) => buildTeamMon(ctx, roster, id));
  const { battleKey } = startBattle(ctx, p0, p1, 1); // BATTLE_MODE_DOUBLES
  const engine = ctx.engine as any;
  engine.battleConfig[engine._getStorageKey(battleKey)].rngOracle = new MemoizedInlineRngOracle();
  return { ctx, bk: battleKey };
}

type Pilot = (e: any, bk: `0x${string}`, side: 0 | 1) => [SlotMove, SlotMove];

function playDoubles(seed: number, p1Pilot: Pilot, p0Pilot: Pilot, maxTurns = 200): 0 | 1 | null {
  const { ctx, bk } = newDoublesBattle(seed);
  const engine = ctx.engine as any;
  const salt = makeRng(seed ^ 0xabcdef);
  for (let t = 0; t < maxTurns; t++) {
    const w = Number(engine.battleData[bk].winnerIndex);
    if (w !== 2) return w as 0 | 1;
    const m0 = p0Pilot(engine, bk, 0);
    const m1 = p1Pilot(engine, bk, 1);
    const s0 = packSide(m0[0].moveIndex, m0[0].extraData, m0[1].moveIndex, m0[1].extraData, BigInt(Math.floor(salt() * 2 ** 30)));
    const s1 = packSide(m1[0].moveIndex, m1[0].extraData, m1[1].moveIndex, m1[1].extraData, BigInt(Math.floor(salt() * 2 ** 30)));
    executeSlotTurn(ctx, bk, s0, s1);
  }
  const w = Number(engine.battleData[bk].winnerIndex);
  return w !== 2 ? (w as 0 | 1) : null;
}

const greedy: Pilot = (e, bk, side) => greedySideMoves(e, bk, side);
const searchD1: Pilot = (e, bk, side) => searchSideMoves(e, bk, side, 1);

// ── 1. Decision timing at a mid-game both-act position ──────────────────────
{
  const { ctx, bk } = newDoublesBattle(777);
  const engine = ctx.engine as any;
  const salt = makeRng(3);
  for (let t = 0; t < 6; t++) {
    if (Number(engine.battleData[bk].winnerIndex) !== 2) break;
    const m0 = greedySideMoves(engine, bk, 0);
    const m1 = greedySideMoves(engine, bk, 1);
    executeSlotTurn(
      ctx, bk,
      packSide(m0[0].moveIndex, m0[0].extraData, m0[1].moveIndex, m0[1].extraData, BigInt(Math.floor(salt() * 2 ** 30))),
      packSide(m1[0].moveIndex, m1[0].extraData, m1[1].moveIndex, m1[1].extraData, BigInt(Math.floor(salt() * 2 ** 30))),
    );
  }
  const flag = Number(engine.getBattleContext(bk).playerSwitchForTurnFlag);
  console.log(`doubles mid-game ready (turn ${engine.getTurnIdForBattleState(bk)}, flag ${flag})`);
  for (const [label, f, iters] of [
    ['greedy side-decision', () => greedySideMoves(engine, bk, 1), 50],
    ['search d1 side-decision', () => searchSideMoves(engine, bk, 1, 1), 5],
  ] as Array<[string, () => unknown, number]>) {
    for (let i = 0; i < 2; i++) f();
    const t0 = performance.now();
    for (let i = 0; i < iters; i++) f();
    console.log(`${label.padEnd(28)} ${((performance.now() - t0) / iters).toFixed(1)} ms/op (${iters} iters)`);
  }
}

// ── 2. Win rate: search d1 (side 1) vs greedy Hard (side 0) ─────────────────
let wins = 0, losses = 0, draws = 0;
const t0 = performance.now();
for (let g = 0; g < games; g++) {
  const w = playDoubles(4000 + g, searchD1, greedy);
  if (w === 1) wins++;
  else if (w === 0) losses++;
  else draws++;
}
const secs = (performance.now() - t0) / 1000;
console.log(
  `\nsearch d1 vs greedy-hard: ${wins}W-${losses}L-${draws}D → ${((wins / Math.max(1, wins + losses)) * 100).toFixed(1)}%  ·  ${games} games in ${secs.toFixed(1)}s (${((secs / games) * 1000).toFixed(0)} ms/game)`,
);
