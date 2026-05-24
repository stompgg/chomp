# CHANGELOG — `claude/decouple-engine-move-tracking-ZMINV`

Engine API and gas optimization work since `c588dbf` (last commit on `main`).

## Overview

This branch decouples per-turn move submission from execution, ships off-chain CPU as a buffered batched mode, trims the engine's external surface, and lands a series of internal optimizations. **All hot paths end up net negative gas versus baseline** despite adding two new external entrypoints, because removing dead getters + repacking storage more than offsets the additions.

53 commits, 5 reverts (failed experiments worth documenting in §7 below).

---

## 1. Engine API surface changes

### Added to `IEngine`
| Function | Purpose |
|---|---|
| `addEffectIfNotPresent(targetIndex, monIndex, effect, extraData) → bool added` | Coalesces the "iterate `getEffects` to dedup, then `addEffect`" idiom that 17 abilities used. Internal storage-side scan. Returns `true` if newly added; `false` if a live slot already held this effect. |
| `executeBatchedTurns(battleKey, entries) → (uint64 executed, address winner)` | Drains N buffered turns in a single tx. Used by `SignedCommitManager` (PvP buffered) and `BatchedCPUMoveManager` (CPU). Amortizes per-turn cold-storage access. |
| `getStorageKey(battleKey) → bytes32` | Resolves a `battleKey` to the storage key used by `BattleConfig` slot allocation. Managers key their own buffers by storageKey so slot reuse across battles via `MappingAllocator` benefits from warm-SSTORE costs. Returns `battleKey` itself if no allocation recorded. |
| `getSubmitContext(battleKey) → (address p0, address p1, uint64 turnId, uint8 winnerIndex, bytes32 storageKey)` | Minimal context for async-submit-then-batch-execute flow. 1 STATICCALL + 3 SLOADs instead of the `getCommitContext` + `getStorageKey` pair (2 calls + 5 SLOADs). |

### Added to concrete `Engine` only (not in `IEngine`)
| Function | Purpose |
|---|---|
| `executeWithDualSignedMovesDirect(...)` | Opt-in direct-execute path for battles started with `moveManager == address(0)`. Verifies the EIP-712 revealer signature inline + executes, bypassing the `SignedCommitManager` STATICCALL. Saves ~3k/turn versus the manager-routed flow. Domain: `("Engine","1")`, distinct from manager domain. |

### Removed from `IEngine` (and `Engine`)
| Function | Reason |
|---|---|
| `getMoveManager(bytes32)` | Zero callers anywhere in `src/`. Pure dead weight. |
| `getBattleValidator(bytes32)` | Zero callers anywhere. Validator already surfaced in `BattleContext` / `ValidationContext` / `CPUContext`. |
| `getMonStateForStorageKey(storageKey, …)` | Test-only. All 4 callsites passed `battleKey` and were equivalent to `getMonStateForBattle`. Tests migrated. |
| `getPrevPlayerSwitchForTurnFlagForBattleState(battleKey)` | Test-only (1 callsite). Replaced with `getBattle()` destructure pulling `prevPlayerSwitchForTurnFlag` off `BattleData`. |

### Net surface delta
- **+4 functions** added, **-4 functions** removed.
- Dispatch table is the same size as baseline, but the kept surface is more focused.

### Tried and reverted
| Function | Reason for removal |
|---|---|
| `getMoveContext(battleKey, atkP, atkM, defP, defM) → MoveContext` | Fat batched getter that returned both sides' stats + state + effect arrays. Pays for SLOADs + memory allocation + ABI encoding of unused fields. Only SneakAttack used ≥10 of the returned fields (net win ~13k/call); every other tested candidate (HoneyBribe, NightTerrors, HardReset) regressed by 4-97k. Maintaining a one-consumer API didn't pencil out — reverted SneakAttack to individual getters too. |
| `getAndInitGlobalKV(key, valueIfZero) → uint192 previous` | "Atomic read + init-if-zero" combined call. Audit of the 9 `globalKV` consumer sites found only 1 migratable site (RiseFromTheGrave) — others are read-modify-write counters or conditional-set-after-work that don't fold into eager-init semantics. |

---

## 2. Storage layout changes

### `BattleData` repacked (slot 0 / slot 1 split)
Goal: every per-turn mutation lands in a single slot.

```
Slot 0 — IMMUTABLE during play (written only at startBattle):
  p1 (160) + p0TeamIndex (16) + p1TeamIndex (16) = 192 bits used, 64 free.

Slot 1 — EVERY per-turn mutation:
  p0 (160) + winnerIndex (8) + prevPlayerSwitchForTurnFlag (8) +
  playerSwitchForTurnFlag (8) + activeMonIndex (16) +
  lastExecuteTimestamp (40) + turnId (16) = 256 bits exactly.
```

Width tradeoffs:
- `turnId` shrunk `uint64` → `uint16` (65,535 turns per battle; realistic games end in 5-30).
- `lastExecuteTimestamp` shrunk `uint48` → `uint40` (year 36800 cap).

### `MoveDecision` packed
```
struct MoveDecision {
    uint8 packedMoveIndex;  // lower 7 bits = moveIndex (0-127), bit 7 = isRealTurn
    uint16 extraData;
}
```
Stored in one 24-bit packed slot.

### `BattleConfig` slot 2 fully packed (256 bits exactly)
```
moveManager (160) + globalEffectsLength (8) + teamSizes (8) +
engineHooksLength (8) + koBitmaps (16) + startTimestamp (40) +
hasInlineStaminaRegen (8) + globalKVCount (8) = 256 bits.
```
KO bitmaps for both players folded into one 16-bit field. `globalKVCount` added to track the live keybuffer length.

### New struct: `TurnSubmission`
Per-turn payload for `SignedCommitManager.submitTurnMoves`. Holds committer preimage (`msg.sender` proves identity) + revealer preimage + revealer EIP-712 signature. Single-sig flow: committer signature implicit in `msg.sender == committer` check at submission time.

---

## 3. New managers / execution modes

### `BatchedCPUMoveManager` (`src/cpu/BatchedCPUMoveManager.sol`) — NEW
Single-player CPU batched mode. The player computes the CPU's move off-chain (via the Solidity-to-TypeScript transpiler), submits `(playerMove, cpuMove)` tuples to an on-chain buffer, and drains the buffer with one `executeBatchedTurns` call.

**Why this works:** there's no counterparty to cheat. Misrepresenting the CPU's response just gives the player a worse experience. Eliminates per-submit `ICPU.calculateMove` STATICCALL, `CPUContext` calldata, salt derivation, and per-turn event.

Per-submit cost: roughly **1 × SLOAD + 2 × SSTORE**.

Storage layout — all keyed by `storageKey` (benefits from `MappingAllocator` reuse):
- `moveBuffer[storageKey][turnId]` — packed (p0Move, p1Move) tuple per turn, interchangeable with `SignedCommitManager.moveBuffer`.
- `bufferState[storageKey]` — combined slot: `numExecuted` (31b) | `gameOverFlag` (1b) | `numBuffered` (32b) | `lastSubmitTs` (32b) | `p0` (160b).
- `storageKeyOf[battleKey]` — cache to avoid `getStorageKey` STATICCALL on subsequent submits.

Cache hits after first submit: single SLOAD of `bufferState` gives p0, gameOver, counters — no engine STATICCALL needed.

### `SignedCommitManager` — buffered submission added
New entrypoint: `submitTurnMoves(battleKey, TurnSubmission entry)` writes to the buffer; `executeBuffered(battleKey)` drains via `executeBatchedTurns`.

Trust model: committer's identity is `msg.sender` (no committer sig needed). Revealer signs `DualSignedReveal{committerMoveHash, revealerMoveIndex, revealerSalt, revealerExtraData, battleKey, turnId}` off-chain; committer carries the sig into their submission.

Switch turns use the same shape — non-acting player signs a `NO_OP` (move 126); engine ignores their half at batch time using the live `playerSwitchForTurnFlag`.

Per-batch execute: `executeBuffered` reads all currently buffered entries, runs them sequentially with engine state held in **transient shadow storage** (see §4), flushes once at the end.

### Direct dual-signed entry on `Engine`
`executeWithDualSignedMovesDirect(...)`: opt-in via `moveManager == address(0)` at battle start. Does its own EIP-712 sig verification + auth + executes. Saves the `SignedCommitManager` STATICCALL on the per-turn legacy path.

Measured: B=14 turns via manager 1,741,827 vs via engine direct 1,696,946 (-44,881 total, ~3.2k/turn).

**Caveat:** stall-timeout via `Engine.end()` for `moveManager==0` battles requires a validator or hitting `MAX_BATTLE_DURATION`. No manager-mediated timeout path.

---

## 4. Engine internals — optimizations landed

### Transient shadow layer for batched execute
Per-batch transient mirrors for the hot read/write paths:
- `BattleData` slot 1 (turnId, winner, switchFlag, activeMonIndex, lastExecuteTimestamp)
- `MonState` for both sides' active mons
- `koBitmaps` (narrowed shadow — only the batched `executeBatchedTurns` path)
- `effectsDirtyBitmap` for selective effect-slot flushes

Per-turn writes go to transient; persistent SSTOREs happen once at batch end. End-of-game special case: `MonState` flush is skipped entirely since the slot will never be read again before reuse.

### Per-turn transients packed into one slot
4 separate transient slots (p0 packedMove, p0 extraData/salt, p1 packedMove, p1 extraData/salt) merged into one 256-bit transient:
```
[0..7]    p0 packedMoveIndex (storedMoveIndex | IS_REAL_TURN_BIT)
[8..23]   p0 extraData
[24..127] p0 salt
[128..135] p1 packedMoveIndex
[136..151] p1 extraData
[152..255] p1 salt
```
Replaces 4 TSTOREs with 1 per call.

### Other in-engine wins
- **Drop per-turn event emission** from `_executeInternal` (was costing ~1.5k/turn for an event no one consumed).
- **Hoist constant `BattleConfig` fields** out of the per-turn loop (validator, hook list, team sizes).
- **Coalesce `BD-slot-1` reads** — single SLOAD into a stack-cached `packed` value, decode per field on demand.
- **Cache `battleKeyForWrite` per frame** — avoid the transient load at every helper site.
- **Cache `_getActiveMonIndex` reads** within function frames.
- **`_handleEffectsTriple` fused dispatch** for RoundStart + RoundEnd lifecycle steps (one external call per effect instead of two).
- **`getCommitAuthForDualSigned`** — lightweight specialized getter for the dual-signed flow that validates state + returns only `(committer, revealer, turnId)`.

---

## 5. Mon contract migrations

12 mon contracts in `src/mons/` migrated from the canonical `getEffects` → loop-to-dedup → `addEffect` pattern to a single `addEffectIfNotPresent` call. Drops ~7 lines per site + saves one `STATICCALL` for `getEffects` + the in-move iteration loop:

```diff
- (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, playerIndex, monIndex);
- for (uint256 i = 0; i < effects.length; i++) {
-     if (address(effects[i].effect) == address(this)) return;
- }
- engine.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
+ engine.addEffectIfNotPresent(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
```

Sites migrated:
| Contract | Notes |
|---|---|
| `aurox/IronWall` | Uses `if (!addEffectIfNotPresent(...)) return;` form because effect-presence guards the initial-heal block |
| `aurox/UpOnly` | Standard |
| `ekineki/SneakAttack` | Uses `if (!addEffectIfNotPresent(...)) return;` form — entire move body guarded |
| `embursa/Tinderclaws` | `activateOnSwitch` only; `_removeBurnIfPresent` kept (different pattern) |
| `gorillax/Angery` | Standard |
| `inutia/ChainExpansion` | Global effect with non-trivial extraData |
| `inutia/Interweaving` | Standard |
| `malalien/ActusReus` | Standard |
| `nirvamma/Adaptor` | Standard |
| `pengym/PostWorkout` | Standard |
| `sofabbi/CarrotHarvest` | Standard |
| `xmon/Dreamcatcher` | Standard |
| `xmon/Somniphobia` | Global effect with non-trivial extraData |

NOT migrated (different semantics — kept as-is):
- `ghouliath/RiseFromTheGrave` — uses `globalKV` flag, not `getEffects`
- `nirvamma/HardReset` — data-bit conditional dedup
- `xmon/NightTerrors` — find-or-update pattern, not add-only
- `embursa/Tinderclaws._removeBurnIfPresent` — remove pattern
- `aurox/GildedRecovery` — remove pattern
- `iblivion/Baselight` — `_findEffect` tuple-returning helper

---

## 6. Gas impact summary

Versus `bdc0505` baseline (pre-API-additions), measured on `EngineGasTest` / `BetterCPUInlineGasTest`:

| Path | Baseline | Current | Δ |
|---|---|---|---|
| `EngineGas B1_Execute` | 982,297 | 981,887 | **-410** |
| `EngineGas Battle1_Execute` | 482,375 | 482,199 | **-176** |
| `EngineGas External_Execute` | 490,865 | 490,689 | **-176** |
| `EngineGas FirstBattle` | 3,213,874 | 3,211,600 | **-2,274** |
| `EngineGas SecondBattle` | 3,275,764 | 3,272,632 | **-3,132** |
| `BetterCPU Turn1_BothAttack` | 273,893 | 273,761 | -132 |

Hot paths are **net negative gas** despite adding 2 new external entrypoints. Mon migrations contribute additional per-call savings (not visible in these snapshots since they use mock-attack mons).

### Concrete per-flow savings vs pre-branch baseline
| Flow | Cost / saving |
|---|---|
| **CPU batched (B=14)** | per-submit `1 × SLOAD + 2 × SSTORE`; saves 145k–634k vs per-turn `OkayCPU.selectMove × N` (B=4 / B=8 / B=14). |
| **PvP legacy dual-signed (B=14)** | ~3.2k/turn saved by engine-direct entry; ~4-5k/turn from shadow layer + slot-1 read coalescing + dropped event. |
| **SneakAttack (per move call)** | -13k from migration to `getMoveContext` ↗ reverted in `3fdc782` (didn't generalize). |
| **Ability "dedup-then-add" sites** | ~700g per ability switch-in saved (15+ sites) from `addEffectIfNotPresent`. |

---

## 7. Lessons worth keeping (things tried + reverted)

| Experiment | Result | Lesson |
|---|---|---|
| **Fat batched-getter `getMoveContext`** | Saved 13-16k per SneakAttack call (uses 10+ fields). Regressed every other tested site by 4-97k (use 3-4 fields). | Fat getters only pay when callers use **most** returned fields. Hidden costs: SLOADs for unused state, effect-array iteration + allocation, struct ABI encoding (~1.1kb). Lean point-getters or compact context structs (like `DamageCalcContext`) win for partial-use. |
| **Tiered `EffectInstance` storage (inline data when fits)** | Slot-0 inline data when `< 96 bits` to save the slot-1 SLOAD. Net loss after dispatch overhead. | Per-slot tiered branching often costs more than the SLOAD it tries to skip, especially when the hot side already amortizes. |
| **Yul switch for tiered effect dispatch** | Cleaner generated code but still net-negative once dispatch table is paid. | Confirmed the tiered-storage idea isn't worth it from a different angle. |
| **First transient shadow attempt (`3aa1026`)** | Did not save gas at the time — slot-1 still being read field-by-field, shadowing the whole struct cost more than it saved. Re-landed later (`e2616dd`, `55f2929`) after the slot-1 read-coalescing prerequisite was in. | Optimizations have ordering dependencies. Cache layers help only when the cached values would otherwise be reloaded. |
| **Salt size reduction (104 → 96 bits) + epoch tag** | Pulled — broke EIP-712 sig format and the savings were marginal. | Don't change wire formats for small wins. |
| **`_handleEffectsTriple` cross-branch hoist** | Pulled — broke `HardReset`'s conditional-dedup data check by reordering effect dispatch. | Effect lifecycle is more tightly ordered than it looks; speculative hoists need per-mon test coverage. |
| **`getAndInitGlobalKV`** | Built it expecting ~5 adoption sites; audit found 1. Removed cleanly. | Audit candidate sites against the actual API semantics before adding the API. Read-modify-write counters don't fit eager-init flag semantics. |

---

## 8. Migration guide for downstream consumers

If you have custom mon contracts following the canonical "dedup-then-add" ability pattern:

```diff
- (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, playerIndex, monIndex);
- for (uint256 i = 0; i < effects.length; i++) {
-     if (address(effects[i].effect) == address(this)) return;
- }
- engine.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
+ engine.addEffectIfNotPresent(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
```

If you call any of the removed getters, swap:
- `getMoveManager(battleKey)` → `getBattleContext(battleKey).moveManager`
- `getBattleValidator(battleKey)` → `getBattleContext(battleKey).validator`
- `getMonStateForStorageKey(battleKey, …)` → `getMonStateForBattle(battleKey, …)` (semantically identical for live battles)
- `getPrevPlayerSwitchForTurnFlagForBattleState(battleKey)` → `getBattle(battleKey)` and read `BattleData.prevPlayerSwitchForTurnFlag`

CPU integrations: see `src/cpu/BatchedCPUMoveManager.sol` for the new buffered single-player mode. The legacy `CPUMoveManager` flow continues to work unchanged.

PvP integrations: `SignedCommitManager.submitTurnMoves` + `executeBuffered` adds the async/batched path. Per-turn `executeWithDualSignedMoves` continues to work. New opt-in `executeWithDualSignedMovesDirect` skips the manager entirely (battles must be started with `moveManager == address(0)`).
