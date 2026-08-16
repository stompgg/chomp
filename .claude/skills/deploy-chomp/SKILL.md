---
name: deploy-chomp
description: Build and deploy pipeline for chomp — processing scripts, the Solidity-to-TS/Rust transpiler, deployment order, and CI/CD reference. Use when running codegen/validation scripts, transpiling, or deploying to testnet/mainnet.
---

### Processing Scripts (Python 3.11+)

```bash
python processing/validateMoves.py          # Validate contracts vs CSV
python processing/validateEffectBitmaps.py  # Validate ALWAYS_APPLIES_BIT usage on IEffect contracts
python processing/generateSolidity.py       # Generate script/mons/Setup<Mon>.s.sol (one per mon)
python processing/generateSetupCPU.py       # Generate SetupCPU.s.sol from cpu-teams.json
python processing/editData.py               # Visual editor: mon stats / move rows / CPU teams (saves + reruns the above)
python processing/deploy.py --testnet       # Full deployment (forge scripts + codegen)
python processing/deploy.py --mainnet       # Production deployment
```

Python dependencies: `numpy`, `pexpect`, `pillow` (managed via `uv`, see `pyproject.toml`)

### Transpiler (Solidity to TypeScript / Rust)

Converts Solidity contracts to TypeScript for local battle simulation:

```bash
# Transpile all contracts
python3 -m transpiler src/ -o transpiler/ts-output -d src --emit-metadata

# Run transpiler unit tests (the TS runtime/integration tests moved to munch with the codegen sync)
python3 transpiler/test_transpiler.py
```

**Rust target (sim performance).** The same front-end also drives a Rust
backend (`codegen_rs/`, native ints instead of bigint — see
`transpiler/codegen_rs/README.md`):

```bash
python3 -m transpiler src/ --target rust                 # emit transpiler/rs-output (cargo workspace)
cd transpiler/rs-output && cargo build --release          # engine + runtime + strategies (+ its bins)
CHOMP_ROOT=$(pwd)/../.. ./target/release/arena --games 6000        # whole-game batches, win-rate table
CHOMP_ROOT=$(pwd)/../.. ./target/release/trace --games 6000 --narrate 0   # trace analysis + greedy counterfactual
```

The full engine, all mons/effects, and the three CPU strategies (hard,
greedy, override) are transpiled/ported. The arena is now a **standalone,
pure-Rust binary** (`chomp-strategies`' `arena`/`trace` bins): it loads the
roster from `drool/*.csv` + `src/mons/*.json` at runtime and runs whole games
natively (~2,000 games/s at 8 threads, deterministic across thread counts).
The stacks are DECOUPLED — the Rust side was ported move-for-move against TS
and then cut loose; it may diverge freely (including its rng stream and CPU
decisions) as the prototyping substrate, and port-backs to the TS game carry
no bit-identicality requirement. Emission is allowlisted in
`transpiler-config-rust.json`. `rs-output/` is regenerated (gitignored);
hand-written crates live in `transpiler/{runtime-rs,strategies-rs}`. The
former bun↔Rust FFI seam (`chomp_run_games`, the `ffi` crate, and
`scripts/batch_benchmark.ts`) was removed once the pure-Rust arena replaced
it; the verification-era machinery (golden-vector suites, replay fixtures,
the drive-mode adapter, lockstep gates) lives in git history if parity ever
needs re-proving. The TS arena was deleted once the pure-Rust one replaced
it; strategies that ship are hand-ported into munch and gated there against
`sim-tests/arena/cpu-reference.json`.

**Known limitation — TODO when a second codebase needs it.** The transpiler hardcodes three TS namespace names (`Enums`, `Structs`, `Constants`) for type-only Solidity files. File-type detection is content-based (a file with only enums maps to the `Enums` namespace regardless of filename), but the *namespace name itself* is fixed, and only structs are tracked per source path. A codebase that splits types across multiple files (e.g. `PoolStructs.sol` + `OrderStructs.sol`, or `Errors.sol`) would produce colliding imports. To generalize: add `enum_paths` / `constant_paths` to `transpiler/type_system/registry.py` mirroring `struct_paths`, derive the namespace name from each source file's basename, and have `imports.py:_generate_module_imports` emit one `import * as <Basename>` per actually-referenced source module instead of three blanket imports.

### Deployment Order

1. `EngineAndPeriphery.s.sol` - Engine, type calculator, `SignedCommitManager`, `GachaTeamRegistry`, `SignedMatchmaker`, CPU host, `SimplePM`, shared effects
2. `script/mons/Setup<Mon>.s.sol` - one script per mon (moves, abilities, `createMon`), broadcast in
   ascending mon-id order because `createMon` rejects non-sequential ids. `deploy.py` derives the
   list from `mons.csv`, so a failed deploy resumes by rerunning from the mon that failed rather
   than redeploying the whole roster.
3. `SetupCPU.s.sol` - CPU players

### CI/CD

GitHub Actions runs on pull requests (`.github/workflows/main.yml`):
- `forge build`
- `forge test -vvv`
