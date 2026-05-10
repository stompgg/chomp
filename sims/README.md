# chomp/sims

Balance-metrics harness for Stomp. Two passes feed one HTML report.

## Run

```bash
cd chomp/sims
bun install                      # one-time
bun run.ts                       # Pass 1 only — static CSV metrics, ~instant
bun run.ts --engine              # Pass 1 + Pass 2 — full-engine sims (default 100 seeds/cell)
bun run.ts --engine --seeds 1000 # Pass 2 with custom seed count
open reports/index.html          # review the report
```

`reports/index.html` is the human review surface. `reports/data.json` is the
diff-friendly raw record (only `generatedAt` changes between identical
seed-count runs — metrics are fully reproducible).

## What's in the report

The report is organized to put each mon's full balance picture in one
place, with two roster-wide views at the top.

- **Flags panel** — auto-generated alerts ranked by severity. Each rule
  lives in `src/report/rules.ts` (tune as design intent evolves).
- **Best-move damage matrix** — pairwise static damage, color-scaled.
  Row labels link to the per-mon card below.
- **Per-mon cards** — one card per mon (sprite from `chomp/drool/imgs/`,
  type, flavor) containing:
  - **Stats** — value, rank (#N/total), percentile, top/bot badges.
  - **Moves** — class, type, power, stamina, accuracy, priority, PPS
    (with z-score; outliers highlighted).
  - **Speed & coverage** — outspeed %, type coverage list, priority
    bypass utility.
  - **Offense** — best move per opponent (static %HP / hits-to-KO) plus
    engine mean %HP and OHKO probability for the same matchup. When the
    engine had to use a different move (because the static-best isn't
    implemented yet), the engine row shows `(via OtherMoveName)`.
  - **Defense** — same shape but flipped: each opponent's best move
    against this mon, both static and engine.

## Architecture

```
src/
  util/
    csv-load.ts        # Parses chomp/drool/{mons,moves,abilities,types}.csv
    mon-builder.ts     # CSV row → engine MonConfig (resolves move contracts via
                       #   transpiler/ts-output/factories.ts; pads moves to 4)
  metrics/
    static/            # Pass 1: pure-CSV metrics (no engine)
    engine/
      damage-hist.ts   # Pass 2: per-pair damage distribution via 1v1 full engine
  harness.ts           # Mock TeamRegistry + Matchmaker, startBattle / executeTurn
                       #   wrappers around the transpiled Engine
  report/
    rules.ts           # Anomaly-flag rules (per-mon, per-move, per-pair)
    render.ts          # Emits reports/index.html + reports/data.json
```

## Notes on coverage

Pass 2 only runs for mons whose moves *and* ability are all implemented as
TypeScript-transpiled contracts (in `chomp/transpiler/ts-output/`). When the
CSV contains a move that doesn't have a matching contract yet, the mon is
either built with the implemented subset (padded with duplicates of the last
implemented move) or fully skipped if zero moves are implemented. Skipped
mons are listed at the top of the engine section.

## Limits

- Engine pass currently runs **1v1**, not 4v4. Sufficient for damage
  histograms; extending to team play is a Pass-3 concern.
- Mons are built with default stamina = 5 and no facets. Adding facet sweeps
  is the next obvious extension.
- Crit/miss detection is derived from damage values relative to the static
  formula (≥1.2× = crit, =0 with non-zero base = miss). The Engine doesn't
  emit these as captured events for inline standard attacks, so we infer.
