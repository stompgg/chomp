/**
 * Win-rate sanity for the ported SearchCpu vs greedy — direction should match the Rust arena
 * (d2 no-peek ≈ 65%, d2 peek ≈ 86% vs greedy over matched drafts).
 *
 *   bun arena/winrate-search.ts [games-per-config]
 */
import { playGame } from '../src/arena/game';
import { CPU_STRATEGIES } from '../src/cpu/registry';
import { makeRng } from '../src/arena/rng';
import { loadRoster } from '../src/util/csv-load';
import { monCatalog } from '../src/arena/team';
import type { DraftedMon } from '../src/arena/team';

const games = Number(process.argv[2] ?? 30);
const roster = loadRoster();
const allIds = roster.mons.map((m) => m.id);

function draftTeams(seed: number): [DraftedMon[], DraftedMon[]] {
  const rng = makeRng(seed);
  const pool = [...allIds];
  const draw = (): number => pool.splice(Math.floor(rng() * pool.length), 1)[0];
  const draft = (ids: number[]): DraftedMon[] =>
    ids.map((id) => {
      const mon = roster.mons.find((m) => m.id === id)!;
      const n = Math.min(4, monCatalog(roster, mon).length);
      return { id, equip: Array.from({ length: n }, (_, i) => i) };
    });
  return [draft([draw(), draw(), draw(), draw()]), draft([draw(), draw(), draw(), draw()])];
}

const greedy = CPU_STRATEGIES.get('greedy')!;
for (const key of ['search-peek', 'search']) {
  const strat = CPU_STRATEGIES.get(key)!;
  let wins = 0, losses = 0, errs = 0;
  const t0 = performance.now();
  for (let g = 0; g < games; g++) {
    const out = playGame(strat, greedy, draftTeams(5000 + g), 9000 + g, 200);
    if ('error' in out) errs++;
    else if (out.winnerSeat === 1) wins++;
    else if (out.winnerSeat === 0) losses++;
  }
  const secs = (performance.now() - t0) / 1000;
  const wr = (wins / Math.max(1, wins + losses)) * 100;
  console.log(
    `${key.padEnd(12)} vs greedy: ${wins}W-${losses}L (${errs} err) → ${wr.toFixed(1)}%  ·  ${games} games in ${secs.toFixed(1)}s (${(secs / games * 1000).toFixed(0)} ms/game)`,
  );
}
