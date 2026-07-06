# sol2rs — the Rust backend (`--target rust`)

Solidity → Rust transpilation for simulation performance. Shares the
entire front-end with the TypeScript target (lexer, parser, type
discovery); emits a cargo workspace instead of a TS module tree.

```bash
python3 -m transpiler src/ --target rust        # emit transpiler/rs-output
cd transpiler/rs-output && cargo build --release   # engine + cdylib + strategies
cd transpiler/rs-output && cargo test           # chomp-rt + strategies unit tests
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
  transpiler-config-rust.json   includeFiles allowlist + world/dispatch config
  runtime-rs/            hand-written chomp-rt crate (source of truth; synced to rs-output/runtime)
  ffi-rs/                bun:ffi cdylib (handle battle API + chomp_run_games batch runner)
  strategies-rs/         native CPU strategies + game loop (hard, greedy, override)
  scripts/batch_benchmark.ts         whole-game batches on the native stack, games/s
  scripts/workload.ts                shared deterministic workload generation
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
| `keccak256`/`sha256`/`abi.encode(Packed)` | `chomp-rt` (alloy keccak, sha2, hand-rolled head/tail ABI encoding pinned by chomp-rt unit tests) |
| runtime-computed constants (`sha256(abi.encode("…"))`) | `LazyLock` statics — derivation stays in code |
| mappings (struct fields) | `rt::Mapping` (HashMap with Solidity zero-default reads) |

## Verification status

The Rust stack was brought up under strict verification — per-function
golden vectors, recorded battle-replay fixtures, a drive-mode adapter
(TS strategies playing on the Rust engine), and live lockstep gates
proving move-for-move equality on thousands of games — and then
DECOUPLED once trusted: all of that machinery is retired (git history
has it), and the Rust side may now diverge freely as the prototyping
substrate. What still runs:

- `bun transpiler/scripts/batch_benchmark.ts` — whole-game batches on
  the native stack, games/s + turns/s.
- `chomp-rt` / `chomp-strategies` unit tests pin ABI/keccak/shift/pow
  and the mulberry32 golden stream standalone (`cargo test`).
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
  ContractId dispatch tables — gated at the time by battle-replay
  lockstep fixtures (since retired) and the full-roster arena drive.
- **Phase 5 (done):** `chomp-ffi` cdylib + the arena `--engine rust`
  drive mode (TS strategies over the Rust engine), verified by a
  27-game move-for-move lockstep gate. The drive mode and its handle
  API were retired at decoupling; batch mode superseded them.
- **Phase 6 (batch mode, done):** native strategy port in
  `transpiler/strategies-rs` (crate `chomp-strategies`): hard, greedy
  and override CPUs, engine-view/battle-view readers, evaluator,
  forward-model probes, the game loop with `Seat` transposition, and a
  threaded `run_games` batch runner exposed as `chomp_run_games` — one
  FFI crossing per BATCH. Duck-typed `basePower`/`accuracy` probes ride
  the generated `try_*` dispatchers (`duckDispatchMethods` in
  `transpiler-config-rust.json`). Verified before decoupling: every
  turn's submissions identical to the TS strategies across hundreds of
  games, and 3,000 games outcome-identical. Measured on the 3,000-game
  workload (4-core box): TS arena ~0.7 games/s (long-run; ~5.5
  fresh-process), Rust batch ~230–330 (1 thread) / ~880–1,270
  (4 threads) after the perf pass — the shared VM's throughput swings
  ~40% between runs on identical code, so compare knobs within one
  session only (per-decision fork memo + FxHash storage maps kept;
  fat LTO tested neutral and -C target-cpu=native tested ~25% slower
  on the virtualized box — both deliberately not used).
- **Decoupling (current state):** the stacks are separate. bun feeds
  `chomp_run_games` a batch config (teams from the CSVs + the TS
  container's address book) — that is the only remaining seam. The Rust
  side may diverge from TS freely; port-backs to the game's CPU mode
  carry no bit-identicality requirement.
