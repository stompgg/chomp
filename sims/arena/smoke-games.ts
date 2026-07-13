/**
 * Smoke: full TS games after the staleness fixes — greedy & hard on both seats
 * (exercises the transpose proxy, forward model, and both strategies end-to-end).
 *
 *   bun arena/smoke-games.ts
 */
import { playGame } from '../src/arena/game';
import { CPU_STRATEGIES } from '../src/cpu/registry';
import { loadRoster } from '../src/util/csv-load';
import { monCatalog } from '../src/arena/team';
import type { DraftedMon } from '../src/arena/team';

const roster = loadRoster();
const draft = (ids: number[]): DraftedMon[] =>
  ids.map((id) => {
    const mon = roster.mons.find((m) => m.id === id)!;
    const n = Math.min(4, monCatalog(roster, mon).length);
    return { id, equip: Array.from({ length: n }, (_, i) => i) };
  });

const greedy = CPU_STRATEGIES.get('greedy')!;
const hard = CPU_STRATEGIES.get('hard')!;
const pairs: Array<[string, any, any]> = [
  ['greedy vs greedy', greedy, greedy],
  ['hard   vs greedy', hard, greedy],
  ['greedy vs hard  ', greedy, hard],
];

let ok = 0, err = 0;
for (const [label, p1, p0] of pairs) {
  for (let g = 0; g < 4; g++) {
    const ids = [...roster.mons.map((m) => m.id)].sort(() => 0.5 - Math.abs(Math.sin(g * 13 + ok))); // deterministic-ish shuffle
    const teams: [DraftedMon[], DraftedMon[]] = [draft(ids.slice(0, 4)), draft(ids.slice(4, 8))];
    const out = playGame(p1, p0, teams, 1000 + g, 200);
    if ('error' in out) {
      err++;
      console.log(`${label} game ${g}: ERROR ${out.error}`);
    } else {
      ok++;
      console.log(`${label} game ${g}: winner seat ${out.winnerSeat} in ${out.turns} turns`);
    }
  }
}
console.log(`\n${ok} games completed, ${err} errors`);
