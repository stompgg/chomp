# chomp/sims

runs simulations and sanity checks for balance in stomp metagame

## Run

```bash
cd chomp/sims
bun install                      # one-time
bun run.ts                       # Pass 1 only — static CSV metrics, ~instant
bun run.ts --engine              # Pass 1 + Pass 2 — full-engine sims (default 100 seeds/cell)
bun run.ts --engine --seeds 1000 # Pass 2 with custom seed count
open reports/index.html          # review the report
```

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