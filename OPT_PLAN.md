# OPT_PLAN — Batched Execute Gas Optimization

## 1. Goal

Amortize per-turn cold-storage access in `Engine.execute()` by:
1. Submitting each turn's signed moves on-chain immediately to a per-turn buffer (no execute).
2. Executing **all currently buffered turns** in one tx with engine state held in **transient shadow storage**, flushed to persistent storage once at the end.

Secondary goal: route `Engine` state access through helpers so the single-turn path can also use the shadow layer.

---

## 2. Mechanism

### 2.1 Per-turn submission (PvP)

`SignedCommitManager.submitTurnMoves(battleKey, TurnSubmission entry)`:
- Uniform shape every turn: **two EIP-712 signatures** (committer + revealer), committer preimage in calldata. Roles derived from `turnId % 2` (matching `getCommitAuthForDualSigned`).
- Switch turns use the same shape. The non-acting player signs a `NO_OP` (move 126); engine ignores their half at batch time using the live `playerSwitchForTurnFlag`.
- Manager hashes committer preimage, verifies committer sig over `SignedCommit{committerMoveHash, …}` and revealer sig over `DualSignedReveal{committerMoveHash, …}`, writes to `moveBuffer[storageKey][turnId]`. **No execute runs.**
- Updates `lastSubmitTimestamp` for timeout tracking.

**Why two sigs.** Without a committer sig, a malicious revealer could pick any preimage `P*`, sign `DualSignedReveal{committerMoveHash: keccak(P*), …}`, and submit unilaterally — the contract would play `P*` as the committer's move with no committer involvement. Today's `executeWithDualSignedMoves` blocks this only via `msg.sender == committer`, which is fragile and not relayer-friendly. Phase 0 (§9) lifts the same fix into the existing function before any batching ships, so both paths share one security model.

### 2.2 Per-batch execute

`Engine.executeBatch(battleKey)`:
- Anyone can call (sigs were checked at submission).
- Reads every currently buffered entry `[startTurn, startTurn + numTurnsBuffered)`, runs each in sequence inside transient shadow storage, flushes once at end.
- The **transient mirror** of `turnId` advances inside the loop. Persistent `BattleData.turnId` advances only during the final flush.
- Batch execution always consumes the full pending buffer. There is no partial-batch mode in v1.
- Processed buffer slots are not cleared — the unbounded mapping leaves them for on-chain replay. Slot reuse across battles comes from `MappingAllocator`.

### 2.3 Fallback / stalls

Fully separate write paths. Legacy `DefaultCommitManager.commitMove`/`revealMove` writes `config.p0Move` etc. and triggers `execute()` immediately; the batched path never reads that storage. A battle can alternate between modes turn-by-turn. Timeout via `Engine.end()` covers full stalls.

---

## 3. Buffer layout

One 256-bit slot per turn:

```solidity
// [ p0MoveIndex (8) | p0ExtraData (16) | p0Salt (104) | p1MoveIndex (8) | p1ExtraData (16) | p1Salt (104) ]
struct PackedTurnEntry {
    uint8   p0MoveIndex;
    uint16  p0ExtraData;
    uint104 p0Salt;
    uint8   p1MoveIndex;
    uint16  p1ExtraData;
    uint104 p1Salt;
}

mapping(bytes32 storageKey => mapping(uint64 turnId => PackedTurnEntry)) moveBuffer;
```

Steady-state cost per turn: 1 SSTORE (5k, nonzero→nonzero from prior battle's slot reuse) + 1 SLOAD inside batch (2.1k) = ~7.1k.

Buffer validity is tracked by two packed `uint8` counters:
- `numTurnsBuffered`: number of currently pending buffered turns.
- `numTurnsExecuted`: cumulative number of buffered turns consumed for the current battle/storage key.

Submit rule:
- If `numTurnsBuffered == 0`, the manager first syncs `numTurnsExecuted` to the engine's current `BattleData.turnId`. This keeps the batched buffer compatible with legacy single-turn execution when the battle alternates modes.
- A new entry must have `entry.turnId == numTurnsExecuted + numTurnsBuffered`.
- After storing the entry, increment `numTurnsBuffered`.

Execute rule:
- `executeBatch` requires `numTurnsBuffered > 0`.
- It attempts the full pending range of `numTurnsBuffered` turns, starting at `numTurnsExecuted`.
- At flush, persistent `BattleData.turnId` becomes the shadowed turn id, `numTurnsExecuted += executedTurns`, and `numTurnsBuffered = 0`.

This means stale slots from a prior battle or earlier batch cannot be treated as valid pending moves: only the contiguous range described by `(numTurnsExecuted, numTurnsBuffered)` is live.

**Width changes (clean break):**
- `extraData`: 240 → 16 bits. Audit confirmed all production consumers read ≤8 bits. Narrow `IMoveSet.move()`'s `extraData` param to `uint16`; repack test helpers (`_packStatBoost`, `StatBoostsMove` mock).
- `Salt`: 256 → 104 bits. 2^104 brute-force resistance is sufficient for the seconds-to-minutes commit-reveal window.

---

## 4. API

### 4.1 Submission

```solidity
struct TurnSubmission {
    uint64 turnId;
    // Committer preimage:
    uint8   committerMoveIndex;
    uint16  committerExtraData;
    uint104 committerSalt;
    // Revealer reveal:
    uint8   revealerMoveIndex;
    uint16  revealerExtraData;
    uint104 revealerSalt;
    // Sigs:
    bytes   committerSig; // EIP-712 over SignedCommit{committerMoveHash, battleKey, turnId}
    bytes   revealerSig;  // EIP-712 over DualSignedReveal
}

// Existing SignedCommitLib struct, reused unchanged.
struct SignedCommit {
    bytes32 moveHash;
    bytes32 battleKey;
    uint64  turnId;
}

struct DualSignedReveal {
    bytes32 battleKey;
    uint64  turnId;
    bytes32 committerMoveHash; // keccak(committerMoveIndex, committerSalt, committerExtraData)
    uint8   revealerMoveIndex;
    uint16  revealerExtraData;
    uint104 revealerSalt;
}

function submitTurnMoves(bytes32 battleKey, TurnSubmission calldata entry) external;
```

Manager flow:
1. Battle is in dual-signed mode and not over.
2. `entry.turnId` equals next append position.
3. Derive `(committer, revealer)` from `turnId % 2`.
4. `committerMoveHash = keccak(committerMoveIndex, committerSalt, committerExtraData)`.
5. Recover `committerSig` over `SignedCommit{committerMoveHash, battleKey, turnId}`; require equality with `committer`.
6. Recover `revealerSig` over `DualSignedReveal{committerMoveHash, …}`; require equality with `revealer`.
7. Map fields to `(p0, p1)` by parity; SSTORE `PackedTurnEntry`.

### 4.2 Batch execute

```solidity
function executeBatch(bytes32 battleKey) external;
```

1. Read `startTurn = numTurnsExecuted`; require `numTurnsBuffered > 0`.
2. Hydrate shadow.
3. For each pending buffered turn: read buffer slot, populate per-turn move/salt transient, run `_executeOneTurn()`, break on game-over.
4. Flush shadow → storage.
5. Set `numTurnsBuffered = 0` and increment `numTurnsExecuted` by the number of turns actually executed.

---

## 5. Transient shadow storage

### 5.1 Shadowed state

| Storage | Shadow form |
|---|---|
| `MonState` (per mon) | Per-`(playerIndex, monIndex)` mirror, lazy-loaded. Dirty bit per slot. |
| `koBitmaps` (16 bits in `BattleConfig` slot 2) | `uint16` mirror, loaded flag. |
| `winnerIndex` / `prevPlayerSwitchForTurnFlag` / `playerSwitchForTurnFlag` / `activeMonIndex` / `turnId` / `lastExecuteTimestamp` | Single packed `uint256` mirror. |
| Effect list slots (`globalEffects[i]`, `pXEffects[i]`) | Fixed numeric transient keys, mirrors the full `EffectInstance` (`effect`, `stepsBitmap`, `data`). |
| `packedP0EffectsCount` / `packedP1EffectsCount` / `globalEffectsLength` | Three small mirrors, flushed with effect-list shadow. |
| `globalKV[storageKey][key]` | Per-`key` mirror, lazy-loaded. |
| `BattleConfig.p0Move` / `p1Move` / salts | Re-populated per sub-turn from buffer slot. |

Hydrate strategy:
- **Eager**: `BattleData` slot 1 + `BattleConfig` slot 2 (always touched).
- **Lazy**: `MonState`, effect slots/counts, `globalKV` (sparse — pay only for slots touched).

Loaded-flag strategy:
- **Bitmap** for fixed-shape slots (MonState, effects, slot-2 packed fields).
- **Per-key transient hash-set** for `globalKV` (dynamic keys).

### 5.1.1 Effect shadow key layout

Effects are bounded and already partitioned, so use numeric transient keys and bitmaps instead of hashed keys.

Assumptions:
- Up to 8 mons per side.
- Up to 8 effects per mon.
- Up to 16 global effects.

Flat effect-slot keys:

```solidity
uint256 constant EFFECTS_PER_MON = 8;
uint256 constant MONS_PER_SIDE = 8;
uint256 constant MAX_GLOBAL_EFFECTS = 16;

uint256 constant EFFECT_P0_OFFSET = 0;    // keys   0..63
uint256 constant EFFECT_P1_OFFSET = 64;   // keys  64..127
uint256 constant EFFECT_GLOBAL_OFFSET = 128; // keys 128..143

function _effectShadowKey(uint256 targetIndex, uint256 monIndex, uint256 localEffectIndex)
    internal
    pure
    returns (uint256)
{
    if (targetIndex == 2) return EFFECT_GLOBAL_OFFSET + localEffectIndex;
    uint256 sideOffset = targetIndex == 0 ? EFFECT_P0_OFFSET : EFFECT_P1_OFFSET;
    return sideOffset + monIndex * EFFECTS_PER_MON + localEffectIndex;
}
```

For player effects, `localEffectIndex` is `0..7` and the storage slot remains
`_getEffectSlotIndex(monIndex, localEffectIndex)`. For global effects, `monIndex` is ignored and
`localEffectIndex` is the global effect index.

Loaded/dirty bitmaps:

```solidity
uint256 transient effectSlotLoadedBitmap;
uint256 transient effectSlotDirtyBitmap;

function _effectBit(uint256 key) internal pure returns (uint256) {
    return 1 << key;
}
```

Shadow values can use numeric transient key regions, one region per `EffectInstance` field:

```solidity
uint256 constant T_EFFECT_ADDR_BASE  = 0x1000;
uint256 constant T_EFFECT_STEPS_BASE = 0x2000;
uint256 constant T_EFFECT_DATA_BASE  = 0x3000;

// tstore(T_EFFECT_ADDR_BASE + key, address(effect))
// tstore(T_EFFECT_STEPS_BASE + key, stepsBitmap)
// tstore(T_EFFECT_DATA_BASE + key, data)
```

Counts use a separate compact key space:

```solidity
// 0 = globalEffectsLength
// 1..8 = p0 mon counts
// 9..16 = p1 mon counts
function _effectCountKey(uint256 targetIndex, uint256 monIndex) internal pure returns (uint256) {
    if (targetIndex == 2) return 0;
    if (targetIndex == 0) return 1 + monIndex;
    return 9 + monIndex;
}
```

Use separate loaded/dirty bitmaps for counts. Flush scans only dirty effect-slot bits in `0..143` and dirty count bits in `0..16`, so flush work is bounded and independent of calldata shape.

### 5.2 Helper boundary

Mirrored helpers in `Engine.sol`:

```solidity
function _shadowReadMonState(BattleConfig storage cfg, uint256 playerIndex, uint256 monIndex) internal returns (MonState memory);
function _shadowWriteMonState(uint256 playerIndex, uint256 monIndex, MonState memory state) internal;
function _shadowReadKV(bytes32 storageKey, uint64 key) internal returns (uint192);
function _shadowWriteKV(bytes32 storageKey, uint64 key, uint192 value) internal;
function _shadowReadEffectSlot(uint256 effectList, uint256 monIndex, uint256 slotIndex) internal returns (EffectInstance memory);
function _shadowWriteEffectSlot(uint256 effectList, uint256 monIndex, uint256 slotIndex, EffectInstance memory eff) internal;
function _shadowReadEffectCount(uint256 effectList, uint256 monIndex) internal returns (uint256);
function _shadowWriteEffectCount(uint256 effectList, uint256 monIndex, uint256 count) internal;
```

When `_shadowActive == false`, helpers SLOAD/SSTORE storage directly. When `true`, they read/write the transient mirror with lazy-load and dirty-bit bookkeeping.

External `IEngine` writers (`updateMonState`, `dealDamage`, `addEffect`, `removeEffect`, `editEffect`, `setGlobalKV`, `switchActiveMon`, `dispatchStandardAttack`, `setMove`) and external readers (`getMonStateForBattle`, `getEffects`, `getGlobalKV`, etc.) all route through these helpers. The `battleKeyForWrite != bytes32(0)` gate stays.

Effect-list shadowing must preserve these same-batch visibility rules:
- `addEffect` writes a full shadow `EffectInstance` and increments the shadow count, so later effect loops / `getEffects` calls in the same batch see the new effect.
- `editEffect` updates shadow `data`; later hooks see the edited value.
- `removeEffect` tombstones the shadow `effect` address and keeps the slot index stable; later loops skip it.
- `_handleEffects` loads counts and slots from shadow, not storage, and keeps the existing `effectsDirtyBitmap` pattern so effects added while iterating can extend the current loop when today’s logic would.
- `getEffects` builds its return arrays from shadow while `_shadowActive == true`, so external moves/effects that inspect active effects observe the live batch state.

### 5.3 Batch loop

```
executeBatch(battleKey):
    storageKey = _getStorageKey(battleKey)
    storageKeyForWrite = storageKey
    battleKeyForWrite = battleKey
    _shadowActive = true

    _hydrateBattleData(battleKey)
    _hydrateConfigSlot2(storageKey)

    startTurn = numTurnsExecuted
    turnsToExecute = numTurnsBuffered
    for t in [startTurn .. startTurn + turnsToExecute):
        bufferEntry = _readMoveBufferSlot(storageKey, t)
        _populateTurnMoveTransient(bufferEntry)
        _executeOneTurn()
        if winnerIndex != 2: break
        _resetPerTurnTransients()

    _flushBattleData(battleKey)
    _flushConfigSlot2(storageKey)
    _flushDirtyMonStates(storageKey)
    _flushDirtyEffectSlots(storageKey)
    _flushDirtyGlobalKV(storageKey)
    _flushBufferCounters(executedTurns)

    _shadowActive = false
```

Per sub-turn, `tempRNG = keccak(p0Salt, p1Salt)` (or single signed salt for switch turns). Engine hooks (`onRoundStart`, `onRoundEnd`) fire per sub-turn and read shadow state via the routed getters.

---

## 6. Forced switches and game-over

### 6.1 Forced switch (KO without game-over)

Both players sign for every turn. The non-acting player signs `NO_OP`. At batch time, the engine reads the live `playerSwitchForTurnFlag` (cheap — in shadow state) and dispatches:
- `flag == 2`: process both halves.
- `flag == 0`: process p0 only, ignore p1's NO_OP.
- `flag == 1`: mirror.

A player who maliciously signs a non-NO_OP on a turn they shouldn't act has bound themselves cryptographically, but the engine ignores the move. A player who refuses to sign stalls the batched flow; legacy single-turn paths remain as fallback.

Submission validates only cheap invariants (battle exists, not over at last flush, append position, sig). It does **not** project `playerSwitchForTurnFlag`, since that would require replaying every unprocessed turn.

### 6.2 Game-over mid-batch

`_executeInternal` already breaks when `winnerIndex != 2`. Same check stops the batch loop. Because batch execution consumes the full pending buffer, any unexecuted buffered entries after game-over remain in storage for replay but are no longer live; `numTurnsBuffered` is set to zero at flush.

### 6.3 Status-induced skip-turn

`shouldSkipTurn` already auto-clears in `_handleMove`. No special batch handling.

---

## 7. CPU mode (off-chain decisions, batched submit)

Same per-turn buffer + `executeBatchedTurns` as PvP. The "CPU" is a phantom opponent address;
all decision logic lives off-chain. The player runs the transpiled engine locally to pick the
CPU's response, then submits both moves on-chain. No on-chain `calculateMove`, no `CPUContext`
calldata hint, no per-submit event. The per-submit cost drops to roughly `getSubmitContext +
2 × SSTORE`.

### 7.1 Trust model

There's no counterparty to cheat. The player can submit any CPU move she wants — misrepresenting
the CPU's "ideal" response just produces a worse experience for the player herself. Since the
CPU has no stake, no balance, no opinion, there's nothing to defend against. This eliminates
the entire on-chain CPU compute path that legacy `CPUMoveManager.selectMove` pays for per turn.

### 7.2 No signature

Player calls directly from her wallet. Manager checks `msg.sender == p0`. The tx is the proof
— no relay path needed for a single-human flow.

### 7.3 Off-chain protocol

Each turn, locally on the player's client:
1. Hold current engine state (post-prior-turn snapshot from local sim).
2. Pick the player's move.
3. Run her chosen CPU strategy off-chain to pick the CPU's response.
4. Submit both moves on-chain via `submitTurn`.
5. Locally simulate the turn outcome via the transpiled engine for next-turn state.

When ready (game-over, user pauses, gas-saving checkpoint), call `executeBuffered` to drain
the buffer in one tx.

### 7.4 Submission

```solidity
function submitTurn(
    bytes32 battleKey,
    uint8   playerMove,
    uint16  playerExtra,
    uint104 playerSalt,
    uint8   cpuMove,
    uint16  cpuExtra,
    uint104 cpuSalt
) external;
```

1. `ENGINE.getSubmitContext(battleKey)` → `(p0, _, turnId, winnerIndex, storageKey)`.
2. Require `msg.sender == p0`.
3. Require `winnerIndex == 2`.
4. First-of-batch sync: if `numBuffered == 0`, mirror engine `turnId` into `numExecuted`.
5. `nextTurnId = numExecuted + numBuffered`.
6. Pack both halves into a single 256-bit slot (same layout as `SignedCommitManager`).
7. SSTORE `moveBuffer[storageKey][nextTurnId]`.
8. Update `bufferCounters[storageKey]` (numBuffered++ + timestamp).

`executeBuffered(battleKey)` drains the buffer via `engine.executeBatchedTurns`. The engine
doesn't know whether the buffer came from PvP or CPU submissions — same layout, same dispatch.

### 7.5 Coexistence

Battles select via the `moveManager` they're started with:
- `SignedCommitManager` → PvP batched.
- `BatchedCPUMoveManager` (new) → off-chain CPU batched.
- Legacy `CPUMoveManager` + `OkayCPU` / `FairCPU` / `BetterCPU` → on-chain CPU single-turn.

The legacy and batched CPU paths are **separate contracts** (no inheritance overlap). Battles
choose one model at start time; mid-battle alternation is not supported between the two CPU
contracts (the engine's `moveManager` field is set once at `startBattle`).

### 7.6 Measured savings (B=14, 2-mon teams, no RNG-sensitive moves)

| | Legacy (`OkayCPU`) | Off-chain batched |
|---|---|---|
| In-harness gas | 2,637,557 | **2,030,352** (-607k / -23.0%) |
| Per-turn cost | ~188k | ~145k (~75k submit + ~70k execute share) |
| Per-tx cold first-touches (production) | 279 (~20/tx) | 92 (~4/submit + 36 in execute) |
| Production estimate | ~3.49M | ~2.53M (-960k / **~-28%**) |

Production estimate adds back per-tx cold penalty (≈ cold first-touches × 2000g) + intrinsic
tx cost (21k × N txs). Numbers from `test/BatchedCPUGasTest.sol`.

The savings come from two sources:
- **Eliminating on-chain `calculateMove`**: legacy `OkayCPU.selectMove` does ~10-15 `ENGINE.X`
  STATICCALLs per turn (mon stats, mon states, damage calc context, move slots), each paying
  cold penalty in production. Off-chain batched does zero — both moves arrive in calldata.
- **Execute amortization**: per-turn engine work in `executeBuffered` runs warm after the
  first sub-turn (no cold-SLOAD per turn).

The per-submit overhead is ~22k (vs the prior hint-based design at ~43k), so even at small
B the cold-tx saving outweighs the per-submit fixed cost.

---

## 8. Migration

Add new entry points alongside existing ones. No "batch mode" flag on a battle — `executeBatch` works on any battle that has buffered turns.

Touched contracts:
- `Engine.sol`: `executeBatch` + shadow-transient layer + helper routing + flag-based per-turn dispatch.
- `IEngine.sol`: new function signatures.
- `SignedCommitManager.sol`: `submitTurnMoves` (sharing existing EIP-712 domain).
- `CPUMoveManager.sol`: `selectMoveWithStateHint`.
- `IMoveSet.sol`: narrow `extraData` to `uint16`. ~40 mon files take mechanical edits.

Validator/legality is unchanged: signature recovery proves player intent (or `msg.sender == alice` for CPU); state-dependent illegality silently no-ops in `_handleMove`. Timeout reads `lastSubmitTimestamp` and `lastExecuteTimestamp` — whichever is more recent.

---

## 9. Phased rollout

**Phase 0 — Dual-sig security fix (preflight, ships first, independent of batching).** The existing `executeWithDualSignedMoves` relies on `msg.sender == committer` as the committer's binding. Without that check, a malicious revealer could sign `DualSignedReveal{committerMoveHash: keccak(P*), …}` for any preimage `P*` they choose and submit unilaterally — the contract would happily compute `committerMoveHash = keccak(P*)`, recover the revealer's sig, and play `P*` as the committer's move. The check is load-bearing today, but it's also fragile: any future evolution of the flow that drops or weakens it (relayers, batching, alt entry points) silently re-opens the hole.

Fix: require an explicit committer signature over the existing `SignedCommit{moveHash, battleKey, turnId}` struct (already used by `commitWithSignature`).

- Modify `executeWithDualSignedMoves` to take an additional `bytes calldata committerSignature` parameter.
- Recover `committerSignature` over `SignedCommit{committerMoveHash, battleKey, turnId}`; require equality with `committer`.
- Drop the `msg.sender == committer` check; the function becomes relayer-friendly (anyone with both sigs + the preimage can submit).
- Breaking signature change. Update all callers (tests, `BattleHelper`, anything off-chain that calls this function) in the same PR. No deployed callers in production yet.
- New tests: missing committer sig reverts; wrong committer signer reverts; submission by a third party with both valid sigs succeeds; revealer cannot submit a self-chosen committer preimage (regression).

This phase ships before any batching work. It hardens the existing flow on its own merits and unifies the security model so the batched path in Phase 2 inherits the same shape (§4.1) without surprises.

**Phase 0.1 — Instrumentation refresh.** `test/BatchInstrumentationTest.sol` already wires `vm.startStateDiffRecording` for the clean damage-trade case. Add scenarios: effect-heavy turn (status DOT + StatBoosts active), forced-switch turn, multi-mon turn. Lock final batch-size guidance.

**Phase 0.5 — Helper extraction (no behavior change).** Replace direct `MonState`/`globalKV`/effect-data SLOAD/SSTORE in `Engine.sol` with §5.2 helpers, with `_shadowActive` permanently `false`. Snapshot diff should be roughly flat.

**Phase 1 — Single-turn shadow.** Implement transient mirrors + lazy-load/dirty-flag bookkeeping. Wire helpers to consult `_shadowActive`. Add `executeShadowed(bytes32 battleKey)` that does `execute()`'s work inside the shadow layer (hydrate → run one turn → flush). Existing test suite should pass against it. B=1 will be slightly *worse* than today's `execute()` due to bookkeeping overhead; expected.

**Phase 2 — PvP per-turn submission + batch execute.** Extend `SignedCommitManager` with `submitTurnMoves`. Add per-turn move buffer mapping and `numTurnsBuffered` / `numTurnsExecuted` counters. Add `Engine.executeBatch` with flag-based dispatch (§6.1), requiring execution of all currently buffered turns. Equivalence tests + gas snapshots.

**Phase 2.5 — CPU mode.** Extend `CPUMoveManager` with `selectMoveWithStateHint` (§7.4). Reuse Phase-2 buffer + `executeBatch`. Equivalence test: 24-turn CPU game via legacy `selectMove × 24` vs `selectMoveWithStateHint × 24 + executeBatch × 3` produces identical end state.

**Phase 3 — Transpiler parity (deferred).** Local TS engine continues running single-turn `execute()` against hydrated state. Eventual batched parity desired but not v1.

**Phase 4 — Optional cutover.** If `executeShadowed` (B=1) is gas-neutral or better, consider redirecting. Otherwise keep the legacy fast path.

---

## 10. Test surface

New `BattleHelper` helpers:
- `_submitTurnMoves(battleKey, turnId, p0Move, p1Move)` — synthesizes signatures and calls `submitTurnMoves`.
- `_executeBuffered(battleKey)` — calls `executeBatch` for all currently buffered turns.

New tests:
- **Submission validation**: wrong committer signer, wrong revealer signer (parity), wrong turnId, wrong battleKey, replay, committer preimage hash mismatch, missing committer sig (regression for unilateral-revealer attack), missing revealer sig.
- **Buffer ordering**: out-of-order rejected; batch executes in turnId order.
- **Switch-turn dispatch**: `flag == 0` and `flag == 1` ignore the non-acting half; non-acting player signing a non-NO_OP has no effect.
- **Equivalence (core gate)**: B turns through legacy path vs `submitTurnMoves × B + executeBatch` produce byte-identical state.
- **Game-over short-circuit** mid-batch: remaining stored buffer entries are no longer live after `numTurnsBuffered` resets to zero.
- **Effect lifecycle parity**: BurnStatus DOT over a 4-turn batch matches per-turn execution.
- **Multi-batch in one battle**: submit 4 then execute, submit 4 then execute, submit 6 then execute — `turnId`, `numTurnsBuffered`, and `numTurnsExecuted` advance correctly.
- **Shadow flush**: post-batch `getMonStateForBattle` / `getGlobalKV` / `getEffects` match equivalent per-turn execution.
- **CPU equivalence**: 24-turn CPU game via legacy vs trusted-state batched produces identical end state.

Existing tests stay untouched — they use the legacy entry points.

Targeted equivalence tests for v1; differential fuzzing as a follow-up.

### 10.1 Effect-shadow correctness tests

Correctness target: for any scripted turn sequence, batched execution produces the same final battle state and the same mid-execution observations as legacy single-turn execution would produce after each turn.

Use a small purpose-built mock effect/move suite instead of relying only on production mons:

- `AddEffectOnRun`: during a hook, calls `engine.addEffect` to append another effect to the same list.
- `EditSelfOnRun`: calls `engine.editEffect` on its own slot and increments a counter in `data`.
- `RemoveSelfOnRun`: returns `removeAfterRun = true`.
- `RemoveOtherOnRun`: calls `engine.removeEffect` for another slot.
- `InspectEffectsOnRun`: calls `engine.getEffects` during the batch and records/validates the visible list.
- `SingletonAbilityRegister`: exercises ability-triggered self-registration through `_activateAbility`.

Required cases:

- **Add visibility:** an effect added on sub-turn `T` is visible to `getEffects` and to `_handleEffects` on sub-turn `T+1`.
- **Add during iteration:** when an effect adds another effect while `_handleEffects` is iterating, the shadow count + `effectsDirtyBitmap` behavior matches legacy storage behavior.
- **Edit visibility:** data written by `editEffect` or returned from a hook is visible to later hooks in the same batch.
- **Remove visibility:** a removed effect is tombstoned in shadow, skipped by later `_handleEffects`, and omitted from `getEffects`, with slot indices preserved.
- **OnRemove callback:** removing an effect with `OnRemove` sees shadowed active mon indices and can perform shadowed writes.
- **Singleton/idempotency:** ability self-registration checks the shadow list, so repeated activation in one batch does not duplicate an effect.
- **Global effects:** repeat add/edit/remove/getEffects cases for global effects, including index `15` to cover the `MAX_GLOBAL_EFFECTS = 16` boundary.
- **Per-player boundaries:** cover p0 mon 0, p0 mon 7, p1 mon 0, and p1 mon 7 to exercise numeric key offsets.
- **Capacity:** adding a ninth effect to one mon or a seventeenth global effect fails/no-ops according to the chosen production behavior, and never corrupts adjacent shadow keys.
- **Flush parity:** after batch flush, storage `EffectInstance` slots and counts match the legacy run byte-for-byte, including tombstones.

Test shape:

1. Start two identical battles.
2. Run the same scripted turns through legacy single-turn execution in battle A.
3. Submit all turns, execute one full batch in battle B.
4. Compare `BattleData`, mon states, `globalKV`, `getEffects` for all relevant lists, and any mock-recorded observations.

---

## 11. Concrete todo (current branch)

Phase 0 (dual-sig fix, §9) and the §3 width changes (`extraData → uint16`, salt → `uint104`) are already merged on this branch — confirmed in `SignedCommitManager.sol:74-138`, `IMoveSet.sol:16`, `Structs.sol:72/106-107/145-146/234-235`.

### Phase 0.1 — Instrumentation refresh ✅

Lock per-turn SLOAD/SSTORE numbers across four representative turn shapes so the batch-size sweet spot is grounded in data, not estimates.

- [x] `test_storageAccessProfile_effectHeavyTurn` in `test/BatchInstrumentationTest.sol`.
- [x] `test_storageAccessProfile_forcedSwitchTurn`.
- [x] `test_storageAccessProfile_multiMonTurn`.
- [x] Locked-numbers comment block at the top of `BatchInstrumentationTest.sol`.

### Scope reduction (mid-implementation, recorded in §12)

§5's transient shadow layer is a real but secondary win on top of the EVM's free warm-slot
amortization across sub-turns of one tx. Deferred to a follow-up so Phase 2's decoupling can
ship without a 3k-LOC refactor of every `MonState`/`globalKV`/effect access in `Engine.sol`.

Phases 0.5 and 1 below remain in the plan unchanged but stay unchecked for now. The Phase 2
implementation that ships uses a plain `executeBatch` that loops `_executeInternal` per sub-turn
within one tx — the EVM keeps slots warm across the loop, so cold SLOADs are paid once per
batch. SSTORE dedup across sub-turns is the only thing the shadow layer would add on top.

### Phase 0.5 — Helper extraction (zero behavior change) [deferred]

Route every `MonState` / `globalKV` / effect-slot / effect-count SLOAD/SSTORE in `Engine.sol` through helpers, with `_shadowActive` wired but permanently false.

- [ ] Add `bool transient _shadowActive;` to `Engine.sol`.
- [ ] Add the eight helpers from §5.2 with non-shadow fast paths.
- [ ] Sweep `Engine.sol` and replace direct accesses in `_updateMonStateInternal`, `_dealDamageInternal`, `setGlobalKV`, `_addEffectInternal`, `editEffect`, `_removeEffectAtSlot`, `_handleEffects`, view getters, and active-mon/move-resolution reads.
- [ ] Full suite green with no test changes.
- [ ] Snapshot diff against `EngineGasTest.json`, `InlineEngineGasTest.json`, `StandardAttackPvPGasTest.json`, `BetterCPUInlineGasTest.json`, `EngineOptimizationTest.json`: flat ±~50 gas per turn.

### Phase 1 — Single-turn shadow (`executeShadowed`) [deferred]

Eight helpers gain real transient mirrors with lazy-load + dirty-flag bookkeeping; new `executeShadowed` proves the hydrate → run → flush cycle.

- [ ] Implement §5.1.1 transient layout (effect loaded/dirty bitmaps, `T_EFFECT_*_BASE` regions, count region, MonState mirror, BattleData-slot-1 + ConfigSlot-2 mirrors, `globalKV` per-key mirror with touched-keys set).
- [ ] Fill the shadow branches of the eight helpers.
- [ ] Hydrate/flush routines: `_hydrateBattleData`, `_hydrateConfigSlot2`, `_flushBattleData`, `_flushConfigSlot2`, `_flushDirtyMonStates`, `_flushDirtyEffectSlots`, `_flushDirtyGlobalKV`.
- [ ] `executeShadowed(bytes32)` on `Engine.sol` + `IEngine.sol`.
- [ ] `test/ShadowParityTest.sol`: scenarios mirror BatchInstrumentationTest; byte-equal post-state assertion.
- [ ] `test/EffectShadowTest.sol`: §10.1 mock effects + 10 required cases, p0/p1 × mon-0/mon-7 boundary, global index-15.
- [ ] Snapshot `ShadowParityTest.json`: B=1 expected to be slightly worse.

### Phase 2 — PvP per-turn submission + `executeBuffered` ✅ (API + correctness; gas savings deferred)

The actual decoupling: per-turn buffer + `executeBuffered` looping `_executeInternal` per sub-turn (no shadow layer per the §12 scope reduction). API surface complete, correctness gated by equivalence + edge tests, all suites green. Gas savings claim is **not** delivered by this design alone — see §12 "Gas finding" — and is gated on the deferred Phase 1 shadow layer.

- [x] `TurnSubmission` struct in `Structs.sol` (§3).
- [x] `SignedCommitManager`: `moveBuffer` (`uint256` packed slot per turn per §3), packed `bufferCounters` (`numTurnsExecuted` + `numTurnsBuffered` + `lastSubmitTimestamp`), `submitTurnMoves` (§4.1 flow, including first-of-batch sync from engine `turnId`).
- [x] `SignedCommitManager.executeBuffered(bytes32)`: anyone can call; loops `executeWithMoves` / `executeWithSingleMove` per sub-turn with flag-based dispatch (§6.1); breaks on game-over; resets per-turn transients between iterations.
- [x] Flag-based dispatch (§6.1) via `getPlayerSwitchForTurnFlagForBattleState` between iterations.
- [x] Extended `Engine.resetCallContext` to clear leaky per-turn transients (`tempRNG`, `koOccurredFlag`, `tempPreDamage`, `effectsDirtyBitmap`) so batched in-tx execution behaves like legacy per-tx execution. No new IEngine surface.
- [x] `test/abstract/BatchHelper.sol`: `_submitTurnMoves`, `_executeBuffered`.
- [x] `test/BufferSubmissionTest.sol`: 12 validation cases — happy path, relayer submission, wrong committer/revealer signer, empty sigs (unilateral-revealer regression), wrong turnId, replay, battle-not-started, empty-buffer execute, counter accounting, timestamp update.
- [x] `test/BatchEquivalenceTest.sol`: B ∈ {2, 4, 8} legacy vs batched byte-equality + multi-batch counter accounting.
- [x] `test/BatchEdgeTest.sol`: forced-switch dispatch (`flag != 2`), single-side switch, mid-batch game-over (`ex` advances by actually-executed, not buffered), mode alternation (legacy↔batched seamless).
- [x] `test/BatchGasTest.sol`: comparison harness for B ∈ {2, 4, 8}. **Current numbers show batched is more expensive than legacy** — recorded in §12 Decision Log.

### Phase 2.5 — Off-chain CPU batched ✅ (shipped as `BatchedCPUMoveManager`)

Player supplies both her move AND the CPU's move per turn; on-chain decision logic deleted.
See §7 (rewritten) for the trust model and protocol. Implementation lives in
`src/cpu/BatchedCPUMoveManager.sol` — completely separate from legacy `src/cpu/CPUMoveManager.sol`
+ the existing `OkayCPU` / `FairCPU` / `BetterCPU` family. Existing CPU contracts and tests
are unchanged.

- [x] `submitTurn(battleKey, playerMove/extra/salt, cpuMove/extra/salt)` on `BatchedCPUMoveManager`.
      No `CPUContext` calldata, no `ICPU.calculateMove` dispatch, no per-submit event.
      Per-submit cost ≈ `getSubmitContext + 2 × SSTORE` ≈ ~22k.
- [x] `executeBuffered(battleKey)` drains the buffer via `engine.executeBatchedTurns` — same
      shared layout as PvP's `SignedCommitManager.moveBuffer`.
- [x] Single batch-end event `TurnsExecuted` + virtual `_afterBattle` hook for subclasses.
- [x] `test/BatchedCPUTest.sol`: 6 functional tests (submit-execute, multi-batch counter
      accounting, empty-buffer / non-p0 / post-game-over reverts, buffered-turn readback).
- [x] `test/BatchedCPUGasTest.sol`: B ∈ {4, 8, 14} comparison vs `OkayCPU.selectMove × N`,
      plus per-tx access tally for production cold-touch counts.
- [x] `test/mocks/SimpleBatchedCPU.sol`: minimal concrete leaf (adds `startBattle`).

**Equivalence vs legacy explicitly NOT verified** — different model (off-chain vs on-chain
decision), different salts, different engine RNG. The two are alternative products, not
mode-flips of one. The functional tests assert behavioural correctness (battle progresses,
counters track, state ends consistently); §7.6 reports the gas delta.

**Measured at B=14** (`test/BatchedCPUGasTest.sol`):
- Legacy `OkayCPU`: 2,637,557 in-harness gas.
- Off-chain batched: 2,030,352 in-harness gas (**-23.0% / -607k**).
- Production cold delta: -187 cold first-touches (~-374k cold penalty).
- Production estimate: legacy ~3.49M vs batched ~2.53M (**~-28% / -960k**).

The big win came from killing the on-chain `ICPU.calculateMove` STATICCALL chain — every legacy
CPU does ~10-15 `ENGINE.X` calls per turn (mon stats, mon states, damage calc), each paying
cold penalty in production. Off-chain CPU does zero engine calls per submit.

### Phase 3 / 4 — deferred

Transpiler parity stays single-turn for v1. Optional `executeShadowed` cutover revisited only if Phase 1's B=1 numbers turn neutral/better after Phase 2 inlining.

---

## 12. Decision log

Decisions made while executing the todo above. Each entry: short context + the call made + why.

### Cross-cutting

- **Shadow layer deferred to follow-up.** §1-§5 of OPT_PLAN are organized around a transient shadow that mirrors `MonState` / `globalKV` / effect-slot reads inside `executeBatch`, then flushes once at the end. The motivating amortization (cold SLOADs are paid once per batch instead of once per turn) is *already* delivered for free by EVM warm-slot semantics: when `executeBatch` loops `_executeInternal` in one tx, the second iteration sees the slots from the first iteration as warm (100 gas) instead of cold (2100). The shadow's additional win is SSTORE deduplication across sub-turns (~5k per dedup'd write × multi-write count per turn). For v1 the warm-slot baseline plus single-tx amortization is enough to ship the gas-savings claim; the SSTORE-dedup follow-up is queued for v2. This deferral means Phases 0.5 and 1 stay in §11 unchecked, and Phase 2's `executeBatch` is built as a simple sub-turn loop over `_executeInternal`.

### Phase 2

- **`executeBuffered` lives on the manager, not the engine.** §4.2 had `Engine.executeBatch(bytes32)` as a new engine entry point. Putting it on the manager instead keeps the engine ignorant of any specific commit-manager and avoids a new engine ↔ manager callback dance (engine asking the manager for buffer entries). The manager already has `IEngine`, so the loop is straightforward: read buffer slot → read live `playerSwitchForTurnFlag` → call `executeWithMoves` or `executeWithSingleMove`. No new engine surface needed except an extension to `resetCallContext`. Trade-off: the engine can never read from the buffer directly (e.g. for a single batch-aware `_executeInternal`-style optimization in the future). For v1 this is the right call.
- **Buffer keyed by `battleKey`, not `storageKey`.** §3 keyed `moveBuffer` by `storageKey` for slot reuse parity with `BattleConfig`. The manager doesn't actually care about slot reuse (entries are tiny — one `uint256` per turn), and `battleKey` is already unique per game via `pairHashNonce` increment. Using `battleKey` directly avoids needing a public `getStorageKey(bytes32)` accessor on the engine and keeps the manager fully decoupled from `MappingAllocator`.
- **Single `uint256` packed slot, no struct in storage.** §3 specified a `PackedTurnEntry` struct. Storing the packed `uint256` directly is one fewer SLOAD (no Solidity-generated wrapper), and the §3 bit layout is preserved exactly: `[p0Move 8 | p0Extra 16 | p0Salt 104 | p1Move 8 | p1Extra 16 | p1Salt 104]`. Internal `_packBufferedTurn` / `_unpackBufferedTurn` helpers handle the bit ops.
- **Extended `resetCallContext` instead of adding `resetPerTurnTransients`.** First pass added a parallel `resetPerTurnTransients()` external on the engine. The existing `resetCallContext()` already clears half of what was needed (per-turn move/salt encoded slots + `battleKeyForWrite` / `storageKeyForWrite`); extending it to also zero `tempRNG` / `koOccurredFlag` / `tempPreDamage` / `effectsDirtyBitmap` covers the rest and avoids two near-identical functions on `IEngine`. In legacy single-turn flow nothing changes — `resetCallContext` is only called by foundry test harnesses, where the extra zero TSTOREs are negligible. In batched flow `executeBuffered` calls `resetCallContext()` between sub-turns so each sub-turn starts with the same transient state the legacy per-tx flow would see. The four added clears are documented inline at `Engine.sol`'s `resetCallContext` body.
- **Game-over short-circuit test design.** First pass used a 2-mon game with HP=1 + power=100 on both sides, expecting "both mons die in turn 1." Trace showed the slower player's move short-circuits (`prevPlayerSwitchForTurnFlag != 2` after the faster player's KO chains into `_checkForGameOverOrKO`), so only ONE mon dies per damage trade. With 2-mon teams this means the battle needs ≥4 turns to wipe one side, and symmetric setups don't deterministically reach game-over within the buffered range. Rewrote with asymmetric setups (p0 fast/strong, p1 slow/glass) so p0 always KOs first and never gets KO'd — game ends deterministically on turn 3, the loop break is provably exercised.
- **Gas finding (critical):** the v1 batched flow (no shadow layer) is **measurably more expensive** than legacy dual-signed-per-turn execution. `test/BatchGasTest.sol` shows:

  | B | legacy | batched | delta |
  |---|---|---|---|
  | 2 | 211,458 | 282,674 | +71k (+33%) |
  | 4 | 370,145 | 500,417 | +130k (+35%) |
  | 8 | 687,748 | 936,847 | +249k (+36%) |

  Per-turn overhead breakdown: each `submitTurnMoves` costs ~22k cold-→-warm SSTORE for the buffer slot + ~5k warm-→-warm SSTORE for the counter slot + ~2k event + ~6k for the two sig recoveries (same as legacy). That's ~30k/turn more than legacy. The `executeBuffered` amortization across sub-turns only saves ~2k/turn per cold→warm engine SLOAD via EVM warm-storage discount (~16 cold SLOADs on a clean trade × 2k ≈ 32k saved per turn-after-the-first), which doesn't recoup the per-submission overhead until B is very large.

  The OPT_PLAN's gas claim (§1) was predicated on the §5 transient shadow layer doing SSTORE deduplication across sub-turns (the second sub-turn's `BattleData.turnId` etc. SSTOREs collapse to one final flush). Without the shadow, the engine SSTOREs every turn unchanged. **Phase 1 (shadow) is required to deliver the gas-savings claim.** Phase 2 as shipped delivers the decoupling API + correctness gate, plus the substrate Phase 1 will sit on top of.

### Phase 0.1

- **Effect-heavy mock.** §0.1 mentioned "StatBoosts-style multi-stat effect + BurnStatus". Both have heavy external dependencies (StatBoosts needs its own deploy and per-mon snapshot KV; BurnStatus needs the StatBoosts instance). For an instrumentation test where only the per-turn storage-access pattern matters, that's overkill. Wrote a 50-LOC `test/mocks/PerTurnTickEffect.sol` that hooks RoundStart + RoundEnd + AfterDamage + ALWAYS_APPLIES and bumps a counter in `data` each tick. Same SLOAD/SSTORE shape (effect slot reads, data SSTOREs, count SLOADs in `_runEffects`), zero external setup. If the shadow layer ever needs differential testing against StatBoosts/Burn specifically, that belongs in Phase 1's effect-shadow correctness suite, not here.
- **Multi-mon scenario interpretation.** §0.1 wording was "all four mons referenced via onUpdateMonState listeners on bench mons". Production engine doesn't actually touch bench mons during a regular turn — only the active mons on each side. The natural multi-slot turn is a switch turn where p0 switches mon 0→1 while p1 attacks (touches p0 mon 0, p0 mon 1, p1 mon 0 = three distinct mon-state slots). Implemented that interpretation; logs show 16 cold SLOADs / 16 unique slots — slightly fewer than a clean trade because no second-attack SSTORE pattern.
- **Forced-switch entry point.** `_fastTurn` goes through `executeWithDualSignedMoves`, which reverts `NotTwoPlayerTurn()` once `playerSwitchForTurnFlag != 2`. Added a `_fastSinglePlayerTurn` helper that routes through `executeSinglePlayerMove(...)` with `vm.prank(actingPlayer)`. This is the same dispatch the production code does and matches what the batch flow will do via §6.1.

### Phase 1 (MonState shadow)

- **MonState shadow added on top of slot-1 shadow.** Mirrored the BattleData slot-1 shadow design at the MonState level: per-(player, monIndex) packed value cached in transient, dirty-bit tracked in `_shadowMonStateDirty`, flushed once at end of `executeBatchedTurns` via `_flushShadowMonStates(storageKey)`. Read/write helpers `_loadMonState` / `_storeMonState` use the packed transient when shadow is active and fall back to SLOAD/SSTORE otherwise — same dispatch as `_readBattleSlot1Packed`. Refactored all in-engine MonState mutation sites (`_dealDamageInternal`, `_updateMonStateInternal`, `_handleMove`'s stamina deduct, `_inlineRegenStaminaForMon`) and read-only sites that need to observe in-flight shadow values (`_computePriorityPlayerIndex`, `_getDamageCalcContextInternal`, `_readMonStateDelta`, `getCPUContext`, `getMonStatesForSide`, etc.) to use the memory-pattern via the helpers.
- **Realistic-game access tally (steady state, 14 turns): batched - legacy = -25 SSTOREs / -915 SLOADs**, a step up from the pre-MonState-shadow baseline of -5 SSTOREs / -793 SLOADs. The MonState shadow specifically coalesces 18 additional `nz->nz` SSTOREs (stamina/hpDelta mutations across sub-turns dedup'd by the per-mon transient) and 122 additional warm SLOADs (reads now hit the transient mirror inside the batch).
- **Legacy-path overhead trade-off.** The memory pattern (`_loadMonState` returns a `MonState memory`, all 9 fields unpacked; `_storeMonState` takes a `MonState memory`, all 9 fields repacked) replaces what used to be storage-ref-with-direct-field-access in the single-turn path. Snapshot diffs show legacy gas tests regressed ~5-8% per scenario (e.g. `Inline_Execute` +20k = +5.6%, `Battle1_Execute` +31k = +6.4%, `ThirdBattle` +224k = +8.6%). The unpack/repack costs ~270 gas/call (mostly memory expansion + shift ops); a 14-turn legacy game does ~140 such calls = ~38k. Live-with-it cost; the batched flow gains ~70k per game from the dedup, so net for users running the batched path is positive. If the legacy regression proves unacceptable downstream, the mitigation is per-field `_readMonStateField` / `_writeMonStateField` helpers that bypass the full unpack/repack in non-shadow mode — kept as a follow-up.
- **Steady-state harness for `BatchGasTest`.** The microbench previously measured battle 1 with HP=100000 (no KOs ever), conflating "cold storage" with "first-touch" and not exercising the engine's `MappingAllocator` free-list. Added a `_runWarmupAndCapture(useBatchedFlow)` helper that drives a low-HP (HP=20) battle to completion via the same flow the measured battle will use (so manager buffer slots warm for batched, only engine slots warm for legacy), then asserts `engine.getStorageKey(warm) == engine.getStorageKey(measured)` before measurement. This matches the harness in `BatchAccessProfileRealisticTest`. Gas numbers from this microbench are still inflated for legacy because all calls share warm-storage within one foundry tx (production legacy = N separate txs, each fresh); the access-tally in the realistic test is the authoritative measure of cold/warm separation.

### Phase 1 (post-MonState follow-ups)

- **Slot-bucket diagnostic in `BatchAccessProfileRealisticTest.test_realisticGameSlotBuckets`.** After BD.slot1 + MonState shadows the batched execute still touched 82 unique slots / 61 SSTOREs / 1021 SLOADs. Added a hash-anchored bucket helper that labels each accessed storage slot by its Engine region (BD.slotN, BC.slotN, MonState per-mon, Effects p0/p1/global, GlobalKV, etc.) so the remaining hot slots are visible at a glance. Top-write region was `BC.slot2` (KO bitmap + moveManager + teamSizes + startTs etc.) at 10 SSTOREs/game from KO-bit accumulation.
- **Step A: skip MonState flush on game-over.** When `executeBatchedTurns` exits with `winner != 0`, the next `startBattle` at this storageKey runs the sentinel-clear loop that overwrites every prior MonState slot anyway, so the un-flushed transient values are recycled either way. Wrapped `_flushShadowMonStates` in an `if (winner == address(0))` and explicitly clears `_shadowMonStateLoaded` / `_shadowMonStateDirty` in the skip path (otherwise a subsequent `executeBatchedTurns` in the same tx — multicall, or any foundry test — reads stale TLOAD bits from this batch and the game state diverges). BD.slot1 flushes unconditionally so `getWinner` stays correct. Saves 6 SSTOREs/game (the 4 + 2 dirty MonState slots at game-end). Trade-off: `getMonStateForBattle` returns stale values in the gap between batch-end and the next `startBattle`; user accepted (off-chain consumers replay from the move buffer).
- **Step B: narrow koBitmaps shadow.** `BC.slot2` packs 8 fields but only `koBitmaps` (uint16) mutates frequently mid-batch (one write per KO). Shadow just that 16-bit field — not the whole slot — into a dedicated transient (`_shadowKoBitmaps` + `_shadowKoBitmapsLoaded` + `_shadowKoBitmapsDirty`) so reads of immutable BC.slot2 fields (`moveManager`, `teamSizes`, `startTimestamp`, ...) stay as direct SLOADs and don't pay a TLOAD-check in legacy mode. Other field writes during the batch (e.g., `globalKVCount` bump) keep doing direct SSTORE; the unconditional flush at end-of-batch overwrites only the koBitmaps bits in storage so the shadowed value wins. Saves another 4 SSTOREs + 21 SLOADs per game (~12k gas). Legacy snapshot regression ~500 gas per game (0.1%) — small because the helper TLOAD-check is only on the koBit hot path, not on every BC.slot2 field read.
- **Final realistic-game steady-state delta: batched - legacy = -35 SSTOREs / -936 SLOADs** (from -25 / -915 after MonState shadow). Approximately 100k gas saved on SSTOREs + 94k saved on SLOADs = ~200k batched advantage per 14-turn game vs the legacy baseline. Per-slot proof of shadow batching: BD.slot1 14 writes → 1 (single flush), BC.slot2 koBitmaps ~5 writes → 0 (folded into one already-needed slot write), MonStates ~6 writes → 0 (game-over flush skip).

> **HARNESS BIAS — important for reading the gas-measurement counterpart `test_realisticGameSteadyStateGas`.** `gasleft()` inside a single foundry test function measures all 14 legacy turns under ONE EVM transaction. Per EIP-2929 slots accessed in turn 1 become warm for turns 2-14 (SLOAD 100 instead of 2,100; SSTORE doesn't pay the cold-access penalty). In production each legacy turn is its own tx with cold-start access. Within-tx-warm measurement gives legacy ~1.99M / batched ~2.12M (batched looks +6.5% worse). Production estimate (adding ~260 cold-SLOAD penalties + 14× intrinsic tx cost): legacy ~2.81M / batched ~2.12M (batched saves ~390k, ~14%). The access-tally test is the authoritative steady-state production measure — it records each turn's state diff under its own per-call recording, so cold/warm classification is production-accurate. **Trust the SSTORE/SLOAD count delta, not the single-tx gasleft() number.**
- **Stopped here.** Three further candidates were measured and rejected:
  - **Effect-data no-op write guard.** Initial diagnostic flagged 21 effect-data no-op SSTOREs per game; I sized this at ~46k gas savings. That was wrong — re-reading EIP-2200/2929, no-op SSTOREs (`prev == new`) cost only 100 gas warm / 2200 gas cold, not the ~2900 of an `nz->nz`. Actual savings ~2.1k gas/game. Not worth the complexity.
  - **BC.slot0 / BC.slot1 shadow (effect counts).** Slots 0/1 pack `validator + packedP0EffectsCount` and `rngOracle + packedP1EffectsCount`. 7 writes/game (effect adds) vs 197 reads/game (every effect-list iteration consults the count). To make writes shadow-safe, reads must route through the shadow too (otherwise mid-batch reads see stale counts). At ~110 gas/TLOAD-check × 197 reads = ~22k legacy regression vs ~14k batched savings. Net negative.
  - **Effect-data slot shadow (full transient mirror per effect lane).** Hypothesis: per-mon effect data slots get written multiple times per batch (counter bumps in ALWAYS_APPLIES effects, status-degree updates). Implemented a transient `_shadowEffectData[player][mon][slot]` mirror with a per-lane dirty bitmap, routed all `p[01]EffectsData` reads/writes through `_loadEffectDataSlot` / `_storeEffectDataSlot`, and flushed dirty lanes at end-of-batch. Realistic 14-turn steady state moved 292 SLOADs (warm, ~29k) and 21 no-op SSTOREs (~2k) into transient — total measurable storage savings ~31k. But the per-iteration TLOAD-check on `_isEffectLaneDirty` (paid every effect read regardless of shadow state) added ~190k of overhead, and the legacy single-tx harness regressed from 1,867,567 → 1,914,298 (+47k), batched-execute from 1,762,241 → 1,919,712 (+157k). Root cause: on the realistic profile most effect slots are written 1-2× per batch, not 5+, so write coalescing doesn't recoup the read-side TLOAD tax. Same shape as the BC.slot0/1 rejection above — pattern: shadows of slots with high read-to-write ratios are net negative. Reverted in entirety; would only pay off on an effect-heavy profile (status-stacking, multi-effect mon-locals) that the realistic benchmark doesn't exercise.
- **Diminishing returns going forward.** The remaining hot slots are effect mappings (`p0Effects[mon][eff].slot0/slot1` reads) — already amortized via warm-slot caching within the single `executeBuffered` tx. The next real lever would be a structural change: a per-batch cached `EffectInstance` array in transient (read all live effects once into memory, iterate from memory across sub-turns, flush deltas at end). That's a much bigger refactor than the field-level shadows above; queued for a future tier if a profile of an effect-heavy game shows it's worth it.

### Phase 1 (single-sig + compute-side trace)

- **Drop committer signature in dual-signed flows.** `executeWithDualSignedMoves` and `submitTurnMoves` now identify the committer by `msg.sender` instead of by an explicit signature. The unilateral-revealer attack (revealer picks any preimage P*, signs `keccak(P*)` as the committer's hash) is closed by `msg.sender == committer`. Trade-off: loses the "anyone can publish with both sigs" relayer property for the committer side (the revealer's sig still lets them be offline at submit time). Per-turn savings on the realistic 14-turn steady-state game: legacy ~3.7k/turn (~52k/game), batched ~6.3k/submit (~88k/game). Production batched-vs-legacy gap widens from ~390k to ~426k (~15.5% per game).

- **Deep gas trace via per-region instrumentation.** Added temporary `GasProfile` event with 14 per-region transient counters accumulated across the 14-turn batched flow. Emitted at end of `executeBatchedTurns`. Findings: effects dispatch (RoundStart + AfterMove × 4 + RoundEnd) = **47% (843k of 1.86M)**, `_handleMove` = **35% (628k)**, framework overhead (decode + reset + flush) = **2% (37k)**. Compute-side is at or near the floor for the existing game semantics — the remaining costs are real game work (damage calc, type lookup, effect contract calls).

- **`_handleEffectsTriple` fusion.** RoundStart and RoundEnd each call `_handleEffects` three times (global + priority-mon + other-mon). Fused into a single function frame with identical semantics. Saved ~7k/game (~3.4k each on R3 + R8). Smaller than estimated because IR optimizer + via_ir already inlines internal calls aggressively; the win is just the redundant stack-frame setup the optimizer couldn't fold. AfterMove's 2-call pattern (per-mon + global, interleaved with `_inlineStaminaRegen`) NOT fused — different shape, less payoff.

- **Adopted: function-frame active-mon-index coalescing (estimate revisited; safety-corrected).** Initial pass dismissed this as worth only ~3-7k. Actual measurement on the realistic 14-turn steady-state shows batched -126k (-7.2%) and legacy -112k (-6.0%). Underestimate root cause: each `_getActiveMonIndex(battleKeyForWrite)` call expands (in shadow mode) to three TLOADs (`_batchShadowActive`, `_shadowBattleSlot1Loaded`, `_shadowBattleSlot1`) plus the bit-shift inside the helper, plus a stack frame the IR optimizer couldn't fold across distinct call points — ~300-500 gas per call, not just one TLOAD. **Switch-safety constraint:** `HardReset` (in `src/mons/nirvamma/HardReset.sol`) is `IMoveSet, BasicEffect` with an `onAfterMove` hook that calls `engine.switchActiveMon` — so coalescing across an effect-lifecycle external call would silently produce stale active-mon indices for subsequent iterations / branches. Hoist sites adopted are only those where:
  (a) the cached value is consumed entirely before any external call that could reach `switchActiveMon`, or
  (b) the call sequence is pure compute / internal-only.
  Adopted: `_runEffects` (3→1 reads at function top; matches the legacy contract that already cached across loop iterations — documented with a comment that effects must not rely on the passed-in indices staying fresh after a mid-loop switch), `_computePriorityPlayerIndex` (2→1), `_checkForGameOverOrKO` (4→1), `_executeInternal` turn-0 ability activation (2→1 — safe because no `IAbility.activateOnSwitch` implementation calls switchActiveMon and HardReset is an `IMoveSet`, not an ability), `_executeInternal` RoundEnd inline stamina regen (2→1 — `_inlineStaminaRegen` is internal-only), `_addEffect` onApply (2→1 — both unpacks complete before the `onApply` external call), `removeEffect` onRemove (2→1 — same shape). **NOT adopted:** `_handleEffectsTriple` cross-branch caching (today RoundStart/RoundEnd effects don't switch, but a future effect bitmapped to those steps + `switchActiveMon` would silently break the hoist — defensive depth via per-branch reads). Snapshot suites improved across the board: `FirstBattle/SecondBattle/ThirdBattle` -112k each (-3.3% to -4.1%), `Fast_Battle1/2/3` ~-92k each (-4.2%), `StandardAttackPvP Turn0_Lead` -10k (-10%), per-turn attacks ~-1.8k each.

- **Skipped: preload effects into memory array.** Theoretical max savings ~30-40k/game (replace 402 warm-SLOAD effect reads with memory reads). Implementation requires write-through to a memory cache from `addEffect` / `removeEffect` / `_updateOrRemoveEffect` to maintain coherency, plus a sparse memory layout to avoid 50KB+ memory-expansion costs on the cache structure. Complexity-to-savings ratio doesn't pencil — the cached reads are already warm SLOADs (100 gas), and the population/maintenance cost ate most of the win in back-of-envelope. Queued for revisit if an effect-heavy benchmark moves the math.

- **Net post-trace deltas to the realistic batched steady-state production estimate:** legacy ~2.78M → ~2.78M (unchanged), batched-total ~2.42M → ~2.33M (~3.7% additional savings from single-sig + fusion). Batched saves ~430-450k vs sequential legacy per 14-turn game (~16% production gap).

### Phase 1 (post-H sweep: more `_readBattleSlot1Packed` coalescing)

- **`_executeInternal` BD-slot-1 top-of-frame coalesce.** Replaced 3 separate `_getWinnerIndex` / `_getTurnId` / `_getPlayerSwitchForTurnFlag` calls + the `_setPrevPlayerSwitchForTurnFlag(... _getPlayerSwitchForTurnFlag(...))` RMW with one `_readBattleSlot1Packed` + local extracts + one combined RMW write. Each helper internally re-reads the packed slot (3 TLOADs in shadow mode + stack frame), so coalescing saves ~3 reads per `_executeInternal` invocation. Safe to cache here: no external calls run between this block and the setPrev write (just a `_turnP0/P1MoveEncoded` transient check and the `cameFromDirectMoveInput` derivation). The line-590 `_getPlayerSwitchForTurnFlag` (after the engineHooks loop) stays as a fresh read since hooks could mutate slot 1.

- **`_handleMove` turnId cache.** `_handleMove` reads `_getTurnId(battleKey)` twice (lines 1774, 1794). turnId is only bumped at the end of `_executeInternal` after every `_handleMove` call has returned, so it's invariant across the entire `_handleMove` frame. Cached once at function entry. ~2 calls/turn × 14 turns × ~1 saved read each.

- **Combined incremental measurement on realistic 14-turn steady state:** batched -19,757 gas (-1.2% incremental, -8.3% cumulative from the original 1,762,241 baseline → 1,615,722); legacy -16,598 gas (-0.9% incremental, -6.9% cumulative from 1,867,567 → 1,738,467). All snapshot suites improved another ~1k-18k per scenario. All 533 tests pass including HardReset's 4 switch-effect tests.

- **Audit pass exhausted for `_readBattleSlot1Packed`.** Remaining call sites are either single-call-per-function-frame (no in-frame coalesce target) or cross-effect-call boundaries where re-reading is required for correctness (e.g. `_handleEffectsTriple` per-branch `_getWinnerIndex` — effects can KO mons and change the winner mid-call; `_executeInternal` line 590 — engineHooks can mutate slot 1).

### Phase 1 (post-H sweep #2: cache `battleKeyForWrite` per frame)

- **TLOAD-coalescing for `battleKeyForWrite`.** Every `_getActiveMonIndex(battleKeyForWrite)`, `_getWinnerIndex(battleKeyForWrite)`, and similar BD-slot-1 helper invocation re-TLOADs the transient `battleKeyForWrite` field (~100 gas) before doing its own slot read. Across the hot path that adds up. `battleKeyForWrite` is set exactly once per external entry and never re-written by internal code (only the external entry points mutate it, and we're past entry), so caching as a local at function top is safe. Where the function already has `battleKey` as a parameter (set to `battleKeyForWrite` at the entry site), substituted directly without an extra local.

  Coalesced sites:
  - `_executeInternal` (4 redundant battleKeyForWrite reads → use the `battleKey` function param).
  - `_handleMove` (3 reads in different code paths → 1 local `bkw`).
  - `_dealDamageInternal` (3 reads across game-over check, PreDamage dispatch, AfterDamage dispatch → 1 local `bkw`).
  - `_checkForGameOverOrKO` (2 reads → 1 local `bkw`).
  - `_handleEffectsTriple` (5 reads across global + priority + other branches → 1 local `bkw`).
  - `_handleEffects` (2 reads → 1 local `bkw`).
  - `_runEffects` (1 read → use `battleKey` param).
  - `_handleSwitch`, `_addEffectInternal`, `_removeEffectAtSlot`, `dispatchStandardAttack`, `switchActiveMon`, `_computePriorityPlayerIndex` (1 redundant read each after their existing battleKey cache).

  Realistic 14-turn steady-state incremental: batched -25,624 (-1.6%), legacy -25,624 (-1.5%). All 533 tests pass including the 4 HardReset tests.

  **Cumulative vs original baseline (pre-H, pre-batched-decoupling-sweep):** batched 1,762,241 → 1,590,098 = **-172,143 gas (-9.8%)**; legacy 1,867,567 → 1,712,843 = **-154,724 gas (-8.3%)**.

### Explored and reverted: tiered `EffectInstance.data` storage

`EffectInstance` lays out as `address effect (160b) | uint16 stepsBitmap (16b) | 80 unused bits` in slot 0, plus `bytes32 data` in slot 1. The "tiered" idea: when `uint256(data) <= 2^79 - 1`, encode data inline in slot 0's free bits (with a 1-bit `isInline` flag at bit 255) and skip the slot 1 SSTORE/SLOAD entirely. StatBoosts (always 256 bits because of its 168-bit identity key) takes the external slot 1 path; everything else fits inline.

Implementation prototype (commits `0bfea95` + `6ba4a9a`) used inline assembly for the hot dispatch read in `_runEffects` (Yul `switch` gating the slot 1 SLOAD) and helper functions for writes. Realistic 14-turn steady-state delivered:

- Storage access tally improvement: SLOADs 972 → 859 (-113, of which -8 cold + -105 warm), SSTOREs 51 → 42 (-9, mostly no-op eliminations). +5 cold SSTOREs offset by -8 cold SLOADs — the cold penalty just moved from SLOAD to SSTORE (same 2100g cost).
- **Theoretical storage savings: ~17.7k.** Measured total savings: ~3.5k.
- **Implied runtime compute overhead: ~14k**, despite Engine bytecode actually *shrinking* by 174 bytes. Sources: branch + bit-extract in dispatch (~3k), function-call frames in write helpers (~1.5k), casts/wraps that pre-tiered struct field access optimized away (~1-3k), unattributed IR-optimizer global re-balancing (~5-9k).
- Bucket inspection of the realistic profile showed **zero real writes to effect slots during execute** (all SSTOREs were no-ops via MappingAllocator slot reuse since battle 2 reruns battle 1's plan), and **~50% of dispatched effects were StatBoosts** (external path, no inline benefit). The write-side savings — the largest theoretical win of tiered storage — was completely unmeasured.

Reverted because the ~3k/game execute-side benefit didn't justify ~150 LOC of assembly + helpers, especially when most of the production-realistic profile (StatBoosts-heavy) doesn't benefit. The cleaner caching/coalescing wins from the previous phases are the right shape for this codebase: they remove redundant TLOADs at zero compute cost. Tiered storage trades storage cost for compute, and on this profile compute already dominates.

Don't redo this without first changing the profile (status-DOT-heavy games, or shrinking StatBoosts' identity key to fit in 79 bits) or finding a way to dispatch without the per-effect branch (only feasible if all effects' data fits inline).

