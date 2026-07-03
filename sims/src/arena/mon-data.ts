/**
 * Per-mon win rate + per-move usage over random 4v4s, seat-swapped to cancel the p1 peek, same strategy
 * on both sides.
 *
 *   bun arena/mon-data.ts --strategies hard,greedy --games 300
 *   bun arena/mon-data.ts --strategies hard,greedy --games 1000 --workers 8
 *
 * Win rate = wins / (wins + losses) for every game a mon was on the team (deduped per team so a
 * repeated draft counts once). Move usage = share of that mon's move-turns spent on each catalog move;
 * ✗ marks a move equipped but never chosen. Mons treated as max level, so mons with a >4-move catalog
 * (the level-6 unlockers) field a random 4-of-N per draft — for those, `[equip N%]` shows how often each
 * move made the loadout.
 *
 * Games are independent and deterministic per (strategy, seed), so the run is sharded across a Worker
 * pool (default = CPU count; `--workers 1` forces sequential). Records merge by summation, so parallel
 * output is byte-identical to sequential — only wall-time changes.
 */
import { createHash } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';
import { MonMetadata } from '../cpu/mon-meta';
import { getCpuStrategy } from '../cpu';
import { newShardResult, mergeInto, runItems, PAIR_STRIDE, type ShardResult, type WorkItem } from './mon-data-core';

const args = process.argv.slice(2);
const argVal = (flag: string, def: string) => {
  const i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
};
const strategies = argVal('--strategies', 'hard,greedy').split(',');
const showMatrix = args.includes('--matrix');
const games = Number(argVal('--games', '300'));
const maxTurns = Number(argVal('--turns', '150'));
const baseSeed = Number(argVal('--seed', '1'));
const defaultWorkers = Math.max(1, Number(navigator.hardwareConcurrency ?? 4));
const workers = Math.max(1, Number(argVal('--workers', String(defaultWorkers))));

// Override runs measure a scripted hypothesis, so the hypothesis must exist before the run: write
// the prediction into the design doc, then pass it here. Plain screens stay ungated.
const prediction = argVal('--prediction', '');
if (strategies.includes('override') && !prediction) {
  console.error('error: override runs require --prediction "<expected outcome, with numbers>".');
  console.error('Register the prediction in the design doc first (prompting/design-pass-prompt.md).');
  process.exit(1);
}

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
console.log('\nMOVE USAGE  used% = share of the mon\'s move-turns; ✗ = equipped but never chosen; [equip N%] = draft rate (rotating catalogs only):');
for (const row of rows) {
  const r = row.r;
  const catalog = (MonMetadata as any)[row.id].moves; // full catalog names (may exceed 4 battle slots)
  const rotating = catalog.length > 4; // only these vary their loadout per draft
  const parts = catalog.map((m: any, lane: number) => {
    const equipNote = rotating && r.drafts ? ` [equip ${((100 * r.moveEquipped[lane]) / r.drafts).toFixed(0)}%]` : '';
    if (r.moveUsed[lane] === 0) return `${m.name} ✗${equipNote}`;
    return `${m.name} ${r.moveTurns ? ((100 * r.moveUsed[lane]) / r.moveTurns).toFixed(0) : '0'}%${equipNote}`;
  });
  console.log(`  ${row.name.padEnd(10)} | ${parts.join('  ·  ')}`);
}

// Matchup matrix (--matrix): win rate of the row mon's side over decided games where the row and
// column mons stood on opposite sides. This is the instrument behind a design pass's "good at" /
// "checked by" profile claims — prey and walls read straight off the row.
if (showMatrix) {
  const wrAB = (a: number, b: number) => {
    const w = res.pairWins[a * PAIR_STRIDE + b];
    const l = res.pairWins[b * PAIR_STRIDE + a];
    return { pct: w + l > 0 ? (100 * w) / (w + l) : NaN, n: w + l };
  };
  const nSample = wrAB(rows[0].id, rows[rows.length - 1].id).n;
  console.log(`\nMATCHUP MATRIX  row mon's win% when row and column mons are on opposite sides (~n=${nSample} per cell; blank diagonal):`);
  const header = '            ' + rows.map((r) => r.name.slice(0, 4).padStart(5)).join('');
  console.log(header);
  for (const a of rows) {
    const cells = rows.map((b) => {
      if (a.id === b.id) return '    ·';
      const { pct } = wrAB(a.id, b.id);
      return (Number.isNaN(pct) ? '?' : pct.toFixed(0)).padStart(5);
    });
    console.log(`  ${a.name.padEnd(10)}${cells.join('')}`);
  }
}

// Journal the run so every number a design doc cites traces to a recorded invocation, and so the
// prediction ledger can be rebuilt by joining predictions to results. The override-script hash makes
// a script edit between two runs visible in the record.
const overrideSrc = readFileSync(new URL('../cpu/strategies/override-cpu.ts', import.meta.url), 'utf8');
const journalEntry = {
  ts: new Date().toISOString(),
  args,
  strategies,
  games: totalGames,
  seed: baseSeed,
  workers: nw,
  prediction: prediction || null,
  overrideScriptsSha256: createHash('sha256').update(overrideSrc).digest('hex').slice(0, 16),
  results: Object.fromEntries(
    rows.map((row) => [row.name, { wr: Number(row.wr.toFixed(1)), wins: row.r.wins, losses: row.r.losses, draws: row.r.draws }]),
  ),
  pairWins: res.pairWins,
};
appendFileSync(new URL('../../runs.jsonl', import.meta.url), JSON.stringify(journalEntry) + '\n');
console.log(`\nrun journaled -> sims/runs.jsonl (${journalEntry.ts})`);
