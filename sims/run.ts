/**
 * CLI entry for chomp/sims.
 *
 *   bun chomp/sims/run.ts                         # Pass 1 only (static metrics)
 *   bun chomp/sims/run.ts --engine                # Pass 1 + Pass 2 (engine, default 100 seeds)
 *   bun chomp/sims/run.ts --engine --seeds 1000   # Pass 2 with custom seed count
 *   bun chomp/sims/run.ts --no-static --engine    # engine pass only (rare)
 *
 * Output: reports/index.html (open in a browser) and reports/data.json (diff-friendly).
 */

import { loadRoster } from './src/util/csv-load';
import { computeStaticMetrics } from './src/metrics/static';
import { runEngineDamageHistogram } from './src/metrics/engine/damage-hist';
import { evaluateFlags } from './src/report/rules';
import { writeReport } from './src/report/render';
import type { Report } from './src/report/types';

function arg(name: string): string | null {
  const i = process.argv.indexOf(name);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : null;
}

function flag(name: string): boolean {
  return process.argv.includes(name);
}

function main() {
  const seedsRaw = arg('--seeds');
  const seedCount = seedsRaw === null ? 500 : Number(seedsRaw);
  const runEngine = flag('--engine') || seedsRaw !== null;

  console.log('[sims] loading roster…');
  const roster = loadRoster();

  console.log('[sims] computing static metrics…');
  const staticMetrics = computeStaticMetrics(roster);

  let engine = null;
  if (runEngine) {
    console.log(`[sims] running engine damage histogram (${seedCount} seeds/cell)…`);
    const t0 = performance.now();
    engine = runEngineDamageHistogram(roster, seedCount);
    const t1 = performance.now();
    console.log(`[sims]   ${engine.cells.length} cells, ${engine.cells.length * seedCount} battles in ${((t1 - t0) / 1000).toFixed(1)}s`);
    if (engine.unbuildableMons.length > 0) {
      console.log(`[sims]   skipped ${engine.unbuildableMons.length} mons: ${engine.unbuildableMons.map((u) => u.mon).join(', ')}`);
    }
  } else {
    console.log('[sims] skipping engine pass (use --engine or --seeds N to enable)');
  }

  const flags = evaluateFlags(staticMetrics, roster, engine);

  const report: Report = {
    meta: {
      generatedAt: new Date().toISOString(),
      rosterSize: roster.mons.length,
      movesCount: roster.moves.length,
      seedCount: runEngine ? seedCount : null,
      notes: [],
    },
    flags,
    static: staticMetrics,
    engine,
  };

  const counts = flags.reduce<Record<string, number>>((acc, f) => ({ ...acc, [f.severity]: (acc[f.severity] ?? 0) + 1 }), {});
  console.log(`[sims] ${flags.length} flags raised (${Object.entries(counts).map(([k, v]) => `${v} ${k}`).join(', ') || 'none'})`);

  const { htmlPath, jsonPath } = writeReport(report, roster);
  console.log(`[sims] wrote ${htmlPath}`);
  console.log(`[sims] wrote ${jsonPath}`);
}

main();
