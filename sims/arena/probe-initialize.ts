/**
 * Probe: how many of greedy's Inutia Initialize casts are silent no-ops (cast while the
 * once-per-send-out lock is set)? Gap-list instrument for design-pass v4's Inutia section;
 * the pre-registered prediction there is ">= 40% of casts are locked".
 *
 * Lock proxy: Inutia's ATK delta > 0 at selection time — Initialize is the only source of a
 * positive ATK delta on Inutia, the boost is Temp (shed on switch-out), and the lock also
 * clears on switch-out, so boost-live and lock-set coincide.
 *
 *   bun arena/probe-initialize.ts [--games N]
 */
import { playGame } from '../src/arena/game';
import { GreedyEvalCpu } from '../src/cpu/strategies/greedy-eval';
import { activeMonIndices, monMaxHp } from '../src/cpu/engine-view';
import { MonStateIndexName } from '../../transpiler/ts-output/Enums';
import { SWITCH_MOVE_INDEX } from '../src/cpu/constants';

const args = process.argv.slice(2);
const gi = args.indexOf('--games');
const GAMES = gi >= 0 ? Number(args[gi + 1]) : 300;

const INUTIA_ID = 1;
const INUTIA_HP = 351;
const INITIALIZE_SLOT = 1; // default equip order: CE 0, Initialize 1, Big Bite 2, Hit And Dip 3

let moveTurns = 0;
let initCasts = 0;
let lockedCasts = 0;
let switches = 0;
let errors = 0;

function mulberry(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function draftTeam(rng: () => number, forceInutia: boolean): { id: number }[] {
  const pool = Array.from({ length: 13 }, (_, i) => i);
  const picked: number[] = forceInutia ? [INUTIA_ID] : [];
  while (picked.length < 4) {
    const c = pool[Math.floor(rng() * pool.length)];
    if (!picked.includes(c)) picked.push(c);
  }
  return picked.map((id) => ({ id }));
}

for (let g = 0; g < GAMES; g++) {
  const rng = mulberry(g + 1);
  const teams: [{ id: number }[], { id: number }[]] = [draftTeam(rng, g % 2 === 0), draftTeam(rng, g % 2 === 1)];
  const outcome = playGame(new GreedyEvalCpu(), new GreedyEvalCpu(), teams as any, g + 1, 150, ({ engine, battleKey, p0Move, p1Move }) => {
    const [p0Active, p1Active] = activeMonIndices(engine, battleKey);
    const sides: Array<[bigint, number, { moveIndex: number } | null]> = [
      [0n, p0Active, p0Move],
      [1n, p1Active, p1Move],
    ];
    for (const [player, idx, mv] of sides) {
      if (!mv) continue;
      if (monMaxHp(engine, battleKey, player, idx) !== INUTIA_HP) continue;
      if (mv.moveIndex === Number(SWITCH_MOVE_INDEX)) { switches++; continue; }
      if (mv.moveIndex > 3) continue; // rest / other non-move actions
      moveTurns++;
      if (mv.moveIndex === INITIALIZE_SLOT) {
        initCasts++;
        const atkDelta = Number(engine.getMonStateForBattle(battleKey, player, BigInt(idx), MonStateIndexName.Attack));
        if (atkDelta > 0) lockedCasts++;
      }
    }
  });
  if ('error' in outcome) errors++;
}

const pct = (n: number, d: number) => (d === 0 ? '0' : ((100 * n) / d).toFixed(1));
console.log(`games ${GAMES} (errors ${errors})  greedy-vs-greedy, Inutia forced onto one seat per game`);
console.log(`Inutia move-turns: ${moveTurns}   switches: ${switches}`);
console.log(`Initialize casts: ${initCasts} (${pct(initCasts, moveTurns)}% of move-turns)`);
console.log(`  cast while locked (ATK delta > 0): ${lockedCasts} (${pct(lockedCasts, initCasts)}% of casts)`);
