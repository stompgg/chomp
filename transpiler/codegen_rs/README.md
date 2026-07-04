# sol2rs — the Rust backend (`--target rust`)

Solidity → Rust transpilation for simulation performance (see `PLAN`:
Solidity → Rust transpiler backend). Shares the entire front-end with the
TypeScript target (lexer, parser, type discovery); emits a cargo workspace
instead of a TS module tree.

```bash
python3 -m transpiler src/ --target rust        # emit transpiler/rs-output
cd transpiler/rs-output && cargo test           # differential gate
```

## Layout

```
transpiler/
  codegen_rs/            this package — one emitter per concern, mirroring codegen/
    symbols.py           cross-file symbol table (full SolType signatures, const-eval)
    soltypes.py          SolType model + expression type inference (the piece TS never needed)
    rust_types.py        SolType -> Rust types / defaults / literals / casts / coercions
    expression.py        typed expression emission (checked vs wrapping intrinsics)
    statement.py         statements incl. unchecked blocks + for-loop desugar
    function.py          fn signatures, &mut param modes, named returns
    definition.py        enums (explicit discriminants + checked from_u8), structs, constants
    contract.py          library -> module fns, interface -> trait, contract -> struct+impl
    generator.py         per-file orchestration + `use` collection
  sol2rs.py              driver: parse-all discovery, allowlisted emission, workspace scaffold
  transpiler-config-rust.json   includeFiles allowlist + dynInterfaces
  runtime-rs/            hand-written chomp-rt crate (source of truth; synced to rs-output/runtime)
  differential-rs/       differential gate crate + fixtures/ (synced to rs-output/differential)
  ffi-rs/                bun:ffi cdylib stub (batch API lands in Phase 5)
  scripts/generate_rust_vectors.ts   TS-oracle fixture generator (bun)
  scripts/generate_spec_vectors.py   Solidity-semantics fixtures for trap/wrap paths
  scripts/gen_mock_engine.py         regenerates PanicEngine from the emitted IEngine trait
  rs-output/             GENERATED cargo workspace (gitignored, like ts-output)
```

## Semantic contract (each rule verified empirically before being relied on)

| Solidity | Rust emission |
|---|---|
| `uintN`/`intN`, N ≤ 128 | smallest native int; plain operators + workspace-wide `overflow-checks = true` (panic == revert) |
| `uint256`/`int256` | alloy `U256`/`I256`; ruint operators wrap silently in release, so checked arithmetic is **explicit** (`SolOps::sol_add`…), unchecked is **explicit** (`wrapping_*`) |
| `unchecked { }` | parser tags `Block.is_unchecked`; emitters switch to wrapping intrinsics |
| explicit int casts | Rust `as` (truncate / reinterpret / extend — bit-exact match); odd widths (uint96/104/168…) stored next-wider, masked on cast |
| shifts | `SolShift::sol_shl/sol_shr`: amount ≥ width ⇒ 0 (or −1 for negative asr) — EVM semantics, never a panic |
| `**` | `checked_pow` (checked ctx) / `pow` (U256, wraps like EVM) / `rt::pow_wrapping` (native) |
| enum casts | checked `from_u8` on the **full** source value (Panic 0x21 parity) |
| memory arrays/structs as params | `&mut T`; identifiers read through `(*p)`; whole-array `local = param` assignment records an intra-function **alias** so later reads match Solidity's reference semantics |
| interfaces | callable *parameter* positions in the `dynInterfaces` set → `&mut dyn Trait`; every other interface-typed value is its on-chain identity, an `Address`. Method calls on an address emit a loud `unimplemented!` until the Phase-3 dispatch enums |
| `keccak256`/`sha256`/`abi.encode(Packed)` | `chomp-rt` (alloy keccak, sha2, hand-rolled head/tail ABI encoding pinned by golden vectors) |
| runtime-computed constants (`sha256(abi.encode("…"))`) | `LazyLock` statics — derivation stays in code |
| mappings (struct fields) | `rt::Mapping` (HashMap with Solidity zero-default reads) |

## Correctness gates

- `cargo test` in `rs-output` runs ~3,900 golden vectors:
  - **TS-oracle suites** (`scripts/generate_rust_vectors.ts`): the TS
    transpiled libs are bit-exact *within game domains*; sweeps stay inside
    them (full 15×15 type matrix, fuzzed damage cores, pack/unpack
    round-trips, the merge-aliasing probe, keccak/abi paths, constants).
  - **Spec suites** (`scripts/generate_spec_vectors.py`): JS bigints neither
    trap nor wrap, so checked-arith reverts, enum-range panics, and
    mod-2²⁵⁶ wrap paths are encoded directly in Python (arbitrary precision
    + masking = exact EVM arithmetic). When forge is available, these become
    Foundry-derived vectors per the plan's oracle hierarchy.
- `chomp-rt` unit tests pin ABI/keccak/shift/pow semantics standalone.
- `python3 -m unittest transpiler.test_transpiler` — TS target unaffected.

## Known, deliberate divergences (watched by the gates)

- **Caller-side memory aliasing.** Passing a memory array to an internal
  function then mutating it through a *returned* alias mutates the caller's
  array in Solidity; the Rust value model copies at the return boundary.
  Intra-function aliasing is handled (alias map); the cross-call case does
  not occur in the current engine code and the lockstep gate would surface
  it as a state diff if introduced.
- **Odd-width checked bounds.** Arithmetic **on** uint96/uint104/… values
  bound-checks at the stored width (u128), not the declared width. No
  phase-1 code does arithmetic at odd widths (packing only); the emitter
  warns when it appears.
- **Events** are skipped (comment emitted) until the Phase-3 event stream.

## Phase status

- **Phase 0 (done):** pipeline fork, workspace, differential skeleton,
  bun:ffi round-trip proven (`chomp_type_effectiveness` matches the TS
  oracle across the full matrix through the release cdylib).
- **Phase 1 (done):** value layer (Enums/Constants/Structs) + pure libs
  (TypeCalcLib, TypeCalculator, RNGLib, StatBoostLib, StaminaRegenLogic,
  SwitchTargetLib, MoveSlotLib, AttackCalculator) + IEngine/ITypeCalculator/
  IMoveSet traits, all bit-identical over the fixture corpus.
- **Phases 2–4 (done):** Engine core (world/storage model, turn loop, Yul
  hand-ports), inheritance flattening, effects + full 13-mon roster,
  ContractId dispatch tables — gated by battle-replay lockstep fixtures
  (158 recorded turns) and the full-roster arena drive.
- **Phase 5 (done):** `chomp-ffi` cdylib (handle-based battle API, rich
  getter-backed state, native forward-model forks) + the arena
  `--engine rust` drive mode; 27-game move-for-move lockstep gate.
- **Phase 6 (batch mode):** native strategy port in
  `transpiler/strategies-rs` (crate `chomp-strategies`): hard + greedy
  CPUs, engine-view/battle-view readers, evaluator, forward-model probes,
  the game loop with `Seat` transposition (the Rust equivalent of the TS
  `transposeEngine` proxy), and a threaded `run_games` batch runner
  exposed as `chomp_run_games` — one FFI crossing per BATCH. Duck-typed
  `basePower`/`accuracy` probes ride the generated `try_*` dispatchers
  (`duckDispatchMethods` in `transpiler-config-rust.json`). Gates (green):
  `bun transpiler/scripts/strategy_lockstep.ts` — the native strategies
  re-derive the TS strategies' moves turn-for-turn on identical seeds
  (200 games, every submission identical) — and
  `bun transpiler/scripts/batch_benchmark.ts` — 2,000 games
  outcome-identical to the TS engine + TS strategies reference.
  Measured on the shared 3,000-game workload (4-core box): TS arena
  ~0.7 games/s (long-run; ~5.5 fresh-process), Rust drive mode ~13,
  Rust batch 274 (1 thread) / 1,062 (4 threads) after the perf pass
  (per-decision fork memo + FxHash storage maps; fat LTO tested neutral
  and -C target-cpu=native tested ~25% slower on the virtualized box —
  both deliberately not used).
