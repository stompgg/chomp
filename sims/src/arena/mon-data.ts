/**
 * Per-mon win rate + per-move usage over random 4v4s, seat-swapped to cancel the p1 peek, same strategy
 * on both sides.
 *
 *   bun arena/mon-data.ts --strategies hard,greedy --games 300
 *   bun arena/mon-data.ts --strategies hard,greedy --games 1000 --workers 8
 *
 * Win rate = wins / (wins + losses) for every game a mon was on the team (deduped per team so a
 * repeated draft counts once). Move usage = share of that mon's move-turns spent on each of its four
 * equipped slots (moveIndex 0-3); ✗ marks a slot never chosen across the whole run.
 *
 * Games are independent and deterministic per (strategy, seed), so the run is sharded across a Worker
 * pool (default = CPU count; `--workers 1` forces sequential). Records merge by summation, so parallel
 * output is byte-identical to sequential — only wall-time changes.
 */
import { MonMetadata } from '../cpu/mon-meta';
import { getCpuStrategy } from '../cpu';
import { newShardResult, mergeInto, runItems, type ShardResult, type WorkItem } from './mon-data-core';

const args = process.argv.slice(2);
const argVal = (flag: string, def: string) => {
  const i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
};
const strategies = argVal('--strategies', 'hard,greedy').split(',');
const games = Number(argVal('--games', '300'));
const maxTurns = Number(argVal('--turns', '150'));
const baseSeed = Number(argVal('--seed', '1'));
const defaultWorkers = Math.max(1, Number(navigator.hardwareConcurrency ?? 4));
const workers = Math.max(1, Number(argVal('--workers', String(defaultWorkers))));

// Validate strategies up front so a bad key fails fast (not inside a worker).
for (const strat of strategies) {
  if (!getCpuStrategy(strat)) throw new Error(`unknown strategy "${strat}"`);
}

// Work units: one (strategy, seed) pair = the two seat-swapped games. Flatten across all strategies.
const items: WorkItem[] = [];
const pairs = Math.max(1, Math.floor(games / 2));
for (const strat of strategies) {
  for (let i = 0; i < pairs; i++) items.push({ strat, seed: baseSeed + i });
}

function shard<T>(arr: T[], n: number): T[][] {
  const out: T[][] = Array.from({ length: n }, () => []);
  arr.forEach((v, i) => out[i % n].push(v));
  return out;
}

async function runParallel(nw: number): Promise<ShardResult> {
  const shards = shard(items, nw).filter((s) => s.length > 0);
  const partials = await Promise.all(shards.map((sd) => new Promise<ShardResult>((resolve, reject) => {
    const w = new Worker(new URL('./mon-data-worker.ts', import.meta.url).href, { type: 'module' });
    w.onmessage = (e: MessageEvent) => { resolve(e.data as ShardResult); w.terminate(); };
    w.onerror = (err) => { w.terminate(); reject(err); };
    w.postMessage({ items: sd, maxTurns });
  })));
  const agg = newShardResult();
  for (const p of partials) mergeInto(agg, p);
  return agg;
}

const nw = Math.min(workers, items.length);
const res = nw <= 1 ? runItems(items, maxTurns) : await runParallel(nw);
const { rec, totalGames, errors } = res;

const ids: number[] = Object.keys(MonMetadata).map(Number);
const rows = ids.map((id) => {
  const r = rec[id];
  const decided = r.wins + r.losses;
  return { id, name: (MonMetadata as any)[id].name as string, wr: decided ? (100 * r.wins) / decided : 0, r };
}).sort((a, b) => b.wr - a.wr);

const parallelNote = nw > 1 ? `  workers: ${nw}` : '';
console.log(`\nGames: ${totalGames} (errors ${errors})  strategies: ${strategies.join('+')}  turns<=${maxTurns}${parallelNote}\n`);
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
