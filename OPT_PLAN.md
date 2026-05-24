# OPT_PLAN — Results Summary

Retrospective for the gas-optimization arc on this branch. The original plan was
"amortize per-turn cold storage in `Engine.execute` by batching submission then draining
under transient shadow storage." This document records what shipped, what was tried and
rejected, what was deferred, and the measured savings.

For per-commit detail see `CHANGELOG.md`. For surviving public API see `IEngine.sol`.

---

## What shipped

### Core mechanism
- **PvP buffered submission.** `SignedCommitManager.submitTurnMoves` writes per-turn moves
  to a manager-owned buffer; `executeBuffered` drains via the new
  `Engine.executeBatchedTurns`. Switch turns reuse the same shape (non-acting player signs
  `NO_OP`).
- **Off-chain CPU batched mode** (`BatchedCPUMoveManager`). Player computes the CPU's move
  off-chain via the transpiled engine and submits `(playerMove, cpuMove)` tuples to an
  on-chain buffer. Trust model: no counterparty to cheat — bad CPU moves just hurt the
  player. Eliminates per-submit `ICPU.calculateMove` STATICCALL, salt derivation, and the
  per-turn event.
- **Engine-direct dual-signed entry** (`Engine.executeWithDualSignedMovesDirect`). Opt-in
  via `moveManager == address(0)`. Inlines EIP-712 reveal-sig verification + auth,
  skipping the manager STATICCALL.

### Transient shadow layer (batched path only)
- BD slot 1 (turnId, winner, switchFlag, activeMonIndex, lastExecuteTimestamp) — single
  SSTORE per batch instead of per turn.
- MonState for both sides' active mons. Flush skipped on game-end (next `startBattle`
  resets the slot anyway).
- `koBitmaps` narrowed shadow — just the 16-bit field, not all of BC slot 2, so reads of
  immutable BC slot 2 fields stay direct.

### Storage layout repacks
- `BattleData` split into slot 0 (immutable during play: p1, team indices) + slot 1
  (every per-turn mutation packed into 256 bits). `turnId` uint64→uint16,
  `lastExecuteTimestamp` uint48→uint40.
- `BattleConfig` slot 2 fully packed (256 bits exact, `koBitmaps` for both players folded
  into one 16-bit field).
- `MoveDecision` reduced to one 24-bit packed slot (`packedMoveIndex` 8b + extraData 16b).

### Single-tx engine wins (apply to both flows)
- Per-turn move/salt transients merged from 4 slots to 1 (saves 3 TSTOREs/call).
- Per-turn event emission dropped from `_executeInternal` (~1.5k/turn).
- Constant `BattleConfig` fields hoisted out of the per-turn loop.
- `BD-slot-1` reads coalesced into a single stack-cached `packed` value, decoded per field
  on demand.
- `_handleEffectsTriple` fused dispatch for RoundStart + RoundEnd lifecycle steps.
- `battleKeyForWrite` cached per frame; `_getActiveMonIndex` reads coalesced within
  function frames.
- Single-sig dual-signed flows (committer identified by `msg.sender`, not a separate
  signature).

### Move-facing API additions
- `addEffectIfNotPresent` — coalesces the canonical "iterate `getEffects` to dedup, then
  `addEffect`" pattern. **12 mons migrated** in `src/mons/`.
- `getSubmitContext` — minimal context for async submission (1 call + 3 SLOADs vs
  `getCommitContext` + `getStorageKey`'s 2 calls + 5 SLOADs).
- `getStorageKey` — managers key their own buffers by storageKey to share
  `MappingAllocator`'s slot reuse.

### Engine surface trims (net dispatch reduction)
- Removed: `getMoveManager`, `getBattleValidator`, `getMonStateForStorageKey`,
  `getPrevPlayerSwitchForTurnFlagForBattleState` (zero callers in `src/`, test-only or
  fully dead).

---

## What was skipped

### Deferred (defer-not-reject)
| Phase | Reason |
|---|---|
| **0.5 — full helper extraction** (route every BD/MonState/effect read through helpers, then add shadow at one boundary) | Scoped down once the batched-path warm-slot semantics turned out to deliver the headline win without a single-turn shadow. Helpers added piecemeal only where the batched path needed them. |
| **1 — single-turn `executeShadowed`** | The motivating savings come from cold-SLOAD amortization across turns; the EVM already gives this for free via warm-slot semantics inside `executeBatch`'s single tx. Single-turn shadow's only remaining win was SSTORE dedup across a single `_executeInternal` frame, which is too small to justify the rework. Queued for v2 if a profile shows per-turn write churn worth chasing. |
| **3 — Transpiler parity** | Local TS engine still runs single-turn `execute` against hydrated state. Batched parity desired eventually; not v1. |
| **4 — anything past Phase 3** | Out of scope. |

### Rejected after measurement
| Experiment | Result | Why |
|---|---|---|
| **Tiered `EffectInstance` storage** (inline data in slot 0 when ≤ 96 bits) | Saved ~3k/game on execute but added ~14k runtime compute overhead; Engine bytecode shrunk 174 bytes but IR-optimizer global re-balancing ate the savings | Most production effects are StatBoosts (external path, no inline benefit) and most effect slots are written 1-2× per batch, not 5+ |
| **Yul switch dispatch for tiered storage** | Cleaner generated code but still net negative once dispatch table is paid | Same root cause as tiered storage itself |
| **Effect-data no-op write guard** | Misestimated savings (~46k expected, actually ~2.1k) — no-op SSTOREs cost 100g warm, not 2900g | Re-read EIP-2200; pattern not worth the complexity |
| **BC.slot0 / BC.slot1 shadow** (effect counts) | 7 writes/game vs 197 reads/game; TLOAD-check tax on reads (~22k) exceeded write savings (~14k) | Shadows of slots with high read:write ratios are net negative |
| **Per-lane effect-data slot shadow** | Moved 292 SLOADs into transient (~31k saved) but per-iteration TLOAD-check tax added ~190k of overhead | Same shape as BC.slot0/1 rejection; profile doesn't write effects often enough |
| **Salt size reduction** (104 → 96 bits + epoch tag) | Broke EIP-712 sig format for marginal gain | Don't change wire formats for small wins |
| **`_handleEffectsTriple` cross-branch hoist** | Reordered effect dispatch and broke `HardReset`'s data-bit conditional dedup | Effect lifecycle ordering is more constrained than it looks |
| **First transient shadow attempt** (raw slot-1 shadow without read coalescing) | Net zero or negative — slot-1 was still read field-by-field, so shadowing cost more than it saved | Optimizations have ordering dependencies; cache only helps when cached values would be reloaded. Re-landed later after read-coalescing prerequisite. |
| **`getMoveContext` fat batched getter** | Saved ~13-16k per `SneakAttack` call (uses ~10 fields) but regressed every other tested site by 4-97k (`HoneyBribe`, `NightTerrors`, `HardReset` use 3-4 fields) | Fat getters only pay when callers use **most** returned fields; ABI encoding + effect-array iteration of unused data dominates |
| **`getAndInitGlobalKV`** | Audit found 1 migratable site (`RiseFromTheGrave`); other 8 KV consumers are read-modify-write counters or conditional-set-after-work | One adoption candidate doesn't justify the API surface |

---

## Measured savings

### CPU batched mode (B=14, 2-mon teams)
| | Legacy (`OkayCPU`) | Batched |
|---|---|---|
| In-harness gas | 2,637,557 | **2,030,352** (-607k, -23%) |
| Per-turn cost | ~188k | ~145k (~75k submit + ~70k execute share) |
| Per-tx cold first-touches (production) | 279 (~20/tx) | 92 (~4/submit + 36 in execute) |
| Production estimate | ~3.49M | ~2.53M (**-960k, ~-28%**) |

### PvP legacy dual-signed (B=14)
- ~3.2k/turn from engine-direct entry (skipping manager STATICCALL).
- ~3.7k/turn from single-sig (~52k/game).
- Shadow + slot-1 coalescing + dropped event: ~4-5k/turn additional.
- Production batched-vs-legacy gap (after single-sig): ~426k/game (~15.5%).

### Realistic 14-turn steady-state (production access pattern)
- **Batched − legacy = -35 SSTOREs / -936 SLOADs/game.**
  Approximately 100k saved on SSTOREs + 94k saved on SLOADs = ~200k batched advantage
  per game vs legacy baseline.
- Per-slot proof of shadow batching:
  - BD.slot1: 14 writes → 1 (single flush)
  - BC.slot2 `koBitmaps`: ~5 writes → 0 (folded into one already-needed slot write)
  - MonStates: ~6 writes → 0 (game-over flush skip)

### Harness caveat
The single-tx foundry harness measures all 14 turns under one EVM tx; per EIP-2929, slots
accessed in turn 1 become warm for turns 2-14. Production legacy runs each turn as its
own tx, paying cold-access penalties. The SSTORE/SLOAD count delta is the authoritative
production measure — single-tx `gasleft()` numbers are not.

### Engine surface (final state)
Hot paths run **net negative gas vs the pre-branch baseline** despite adding two new
external entrypoints — the 4 dead-getter removals + storage repacks more than offset:

| Path | Baseline | Final | Δ |
|---|---|---|---|
| `EngineGas B1_Execute` | 982,297 | ~981k | **-400** |
| `EngineGas Battle1_Execute` | 482,375 | ~482k | **-150** |
| `EngineGas FirstBattle` | 3,213,874 | ~3,211k | **-2,300** |
| `EngineGas SecondBattle` | 3,275,764 | ~3,272k | **-3,100** |

---

## Lessons (worth applying to v2)

1. **Warm-slot semantics deliver most of the cold-storage amortization for free.** Inside
   a single tx, the second-and-later iterations of `executeBuffered`'s sub-turn loop see
   slots from earlier turns as warm. Shadow layers are only useful when they coalesce
   *writes* across sub-turns, not when they cache reads.

2. **Shadows pay only when read:write ratio is low.** Every shadowed read pays a
   TLOAD-check; if reads dominate writes, that check tax exceeds the dedup savings. This
   killed three separate shadow experiments (BC.slot0/1, per-lane effect data, full
   effect-data slot shadow).

3. **Fat batched getters need ≥5 used fields to net positive.** `getMoveContext` saved
   ~13k for `SneakAttack` (uses ~10 fields) but regressed every other tested site by
   4-97k (use 3-4 fields). Hidden costs: SLOADs for unused state, effect-array iteration
   + allocation, struct ABI encoding (~1.1kb).

4. **Optimizations have ordering dependencies.** The first shadow attempt landed net-zero
   because slot-1 was still read field-by-field. Read-coalescing had to land first; then
   the shadow re-landed with measurable savings.

5. **API additions cost dispatch even with no callers.** Each new external function
   inflates the selector table; +1,200g per-execute regression from the 3 coalesced APIs
   I added was offset by removing 5 dead getters elsewhere. Audit candidate adoption
   sites against the actual API semantics *before* adding the API — `getAndInitGlobalKV`
   was built expecting ~5 adopters and found 1, then removed cleanly.

6. **Tiered storage trades storage cost for compute, and on this profile compute
   already dominates.** ~73% of `_executeInternal` is in external `IMoveSet` / `IEffect`
   calls. Engine-side wrapping is already minimal; further wins require either reducing
   round-trips (the `addEffectIfNotPresent` pattern) or changing the game shape itself.
