/**
 * Per-mon win rate + per-move usage over random 4v4s, seat-swapped to cancel the p1 peek, same strategy
 * on both sides.
 *
 *   bun arena/mon-data.ts --strategies hard,greedy --games 300
 *
 * Win rate = wins / (wins + losses) for every game a mon was on the team (deduped per team so a
 * repeated draft counts once). Move usage = share of that mon's move-turns spent on each of its four
 * equipped slots (moveIndex 0-3); ✗ marks a slot never chosen across the whole run.
 */
import { buildRandomTeam } from './team-builder';
import { getCpuStrategy } from '../cpu';
import { MonMetadata } from '../cpu/mon-meta';
import { activeMonIndices } from '../cpu/engine-view';
import { makeRng } from './rng';
import { playGame } from './game';

const args = process.argv.slice(2);
const argVal = (flag: string, def: string) => {
  const i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
};
const strategies = argVal('--strategies', 'hard,greedy').split(',');
const games = Number(argVal('--games', '300'));
const maxTurns = Number(argVal('--turns', '150'));
const baseSeed = Number(argVal('--seed', '1'));

const ids: number[] = Object.keys(MonMetadata).map(Number);
type Rec = { wins: number; losses: number; draws: number; moveCounts: number[]; moveTurns: number };
const rec: Record<number, Rec> = {};
for (const id of ids) rec[id] = { wins: 0, losses: 0, draws: 0, moveCounts: [0, 0, 0, 0], moveTurns: 0 };

let errors = 0;
let totalGames = 0;

for (const strat of strategies) {
  const s = getCpuStrategy(strat);
  if (!s) throw new Error(`unknown strategy "${strat}"`);
  const pairs = Math.max(1, Math.floor(games / 2));
  for (let i = 0; i < pairs; i++) {
    const seed = baseSeed + i;
    const teamRng = makeRng(seed * 7919 + 17);
    const baseTeams: [number[], number[]] = [
      buildRandomTeam(teamRng).monIndices.map(Number),
      buildRandomTeam(teamRng).monIndices.map(Number),
    ];
    for (const swap of [false, true]) {
      const t: [number[], number[]] = swap ? [baseTeams[1], baseTeams[0]] : [baseTeams[0], baseTeams[1]];
      const hook = (info: any) => {
        const [a0, a1] = activeMonIndices(info.engine, info.battleKey);
        if (info.p0Move && info.p0Move.moveIndex < 4) {
          const id = t[0][a0];
          rec[id].moveCounts[info.p0Move.moveIndex]++;
          rec[id].moveTurns++;
        }
        if (info.p1Move && info.p1Move.moveIndex < 4) {
          const id = t[1][a1];
          rec[id].moveCounts[info.p1Move.moveIndex]++;
          rec[id].moveTurns++;
        }
      };
      const out = playGame(s, s, t, seed, maxTurns, hook);
      totalGames++;
      if ('error' in out) { errors++; continue; }
      const drew = out.winnerSeat === null;
      const tally = (id: number, seatWon: boolean) => {
        if (drew) rec[id].draws++;
        else if (seatWon) rec[id].wins++;
        else rec[id].losses++;
      };
      for (const id of new Set(t[0])) tally(id, out.winnerSeat === 0);
      for (const id of new Set(t[1])) tally(id, out.winnerSeat === 1);
    }
  }
}

const rows = ids.map((id) => {
  const r = rec[id];
  const decided = r.wins + r.losses;
  return { id, name: (MonMetadata as any)[id].name as string, wr: decided ? (100 * r.wins) / decided : 0, r };
}).sort((a, b) => b.wr - a.wr);

console.log(`\nGames: ${totalGames} (errors ${errors})  strategies: ${strategies.join('+')}  turns<=${maxTurns}\n`);
console.log('WIN RATE  wins/(wins+losses), seat-swapped:');
for (const row of rows) {
  const r = row.r;
  console.log(`  ${row.name.padEnd(10)} ${row.wr.toFixed(1).padStart(5)}%   (W${r.wins}/L${r.losses}/D${r.draws})`);
}
console.log('\nMOVE USAGE  share of the mon\'s move-turns; ✗ = never chosen:');
for (const row of rows) {
  const r = row.r;
  const moves = (MonMetadata as any)[row.id].moves.slice(0, 4);
  const parts = moves.map((m: any, idx: number) => {
    if (r.moveCounts[idx] === 0) return `${m.name} ✗`;
    return `${m.name} ${((100 * r.moveCounts[idx]) / r.moveTurns).toFixed(0)}%`;
  });
  console.log(`  ${row.name.padEnd(10)} | ${parts.join('  ·  ')}`);
}
