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

## 7. CPU mode (trusted-state batched)

Same per-turn buffer + `executeBatch` as PvP. CPU manager packs `(Alice move, computed CPU move)` into the same `PackedTurnEntry` layout. **Zero engine changes.**

### 7.1 Trusted state hint

Alice supplies the projected post-prior-turn `CPUContext` in calldata. Not verified. Lying never benefits Alice — it makes the CPU's chosen move suboptimal against her, which she absorbs. This replaces the dozen-plus cold SLOADs `engine.getCPUContext(battleKey)` does today with a single calldata struct.

### 7.2 No signature

Alice calls directly from her wallet. Manager checks `msg.sender == alice` (same as today's `CPUMoveManager.selectMove`). The tx is the proof — no relay path needed for a single-human flow.

### 7.3 Off-chain protocol

Each turn, locally on Alice's client:
1. Hold current `CPUContext`-shaped state. Turn 0 = post-`startBattle` state; later turns = output of last local sim.
2. Pick Alice's move.
3. Run the transpiled engine locally to produce the post-turn state, used as next turn's hint.
4. Submit on-chain with the **current-turn** hint.

### 7.4 Submission

```solidity
function selectMoveWithStateHint(
    bytes32 battleKey,
    uint8   aliceMoveIndex,
    uint16  aliceExtraData,
    uint104 aliceSalt,
    CPUContext calldata projectedState
) external;
```

1. Read/sync the next append `turnId` from `numTurnsExecuted + numTurnsBuffered` using the same buffer counter rules as PvP.
2. Require `msg.sender == alice`.
3. Route on `projectedState.playerSwitchForTurnFlag` (single-player vs two-player CPU branch).
4. `ICPU(cpuAddr).calculateMove(projectedState, aliceMoveIndex, aliceExtraData)` → `(cpuMove, cpuExtra)`. CPU reads from calldata only.
5. Derive CPU salt: `uint104(uint256(keccak256(abi.encode(block.timestamp, aliceSalt, turnId))))`. Emit `CPUTurnSalt(battleKey, turnId, timestamp)` so off-chain replay can reconstruct it. `turnId` in the hash prevents collision when Alice submits multiple CPU turns in the same block.
6. Pack into `PackedTurnEntry` and SSTORE into `moveBuffer[storageKey][turnId]`.

`executeBatch` is shared with PvP — the engine doesn't know whether the buffer came from PvP or CPU submissions.

### 7.5 Coexistence

Battles select via the `moveManager` they're started with:
- `signedCommitManager` (extended) → PvP batched
- `cpuMoveManager` (extended) → CPU batched
- Today's unmodified managers → legacy single-turn paths

Today's `CPUMoveManager.selectMove` stays callable for any battle that doesn't opt into batching.

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

### Phase 0.5 — Helper extraction (zero behavior change) ✅ shipped

Route every `MonState` / `globalKV` / effect-slot / effect-count SLOAD/SSTORE in `Engine.sol` through helpers, with `_shadowActive` wired but permanently false.

- [ ] Add `bool transient _shadowActive;` to `Engine.sol`.
- [ ] Add the eight helpers from §5.2 with non-shadow fast paths.
- [ ] Sweep `Engine.sol` and replace direct accesses in `_updateMonStateInternal`, `_dealDamageInternal`, `setGlobalKV`, `_addEffectInternal`, `editEffect`, `_removeEffectAtSlot`, `_handleEffects`, view getters, and active-mon/move-resolution reads.
- [ ] Full suite green with no test changes.
- [ ] Snapshot diff against `EngineGasTest.json`, `InlineEngineGasTest.json`, `StandardAttackPvPGasTest.json`, `BetterCPUInlineGasTest.json`, `EngineOptimizationTest.json`: flat ±~50 gas per turn.

### Phase 1 — Single-turn shadow ✅ shipped (executeBatchedTurns instead of executeShadowed)

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

### Phase 2.5 — CPU mode

CPU manager rides the same buffer + `executeBatch`. No engine changes.

- [ ] `selectMoveWithStateHint(bytes32, uint8, uint16, uint104, CPUContext calldata)` on `CPUMoveManager.sol` (§7.4).
- [ ] CPU salt derivation + `CPUTurnSalt(battleKey, turnId, timestamp)` event.
- [ ] Pack `(aliceMove, computedCpuMove)` into `PackedTurnEntry` and SSTORE to `moveBuffer`.
- [ ] `test/CPUBatchEquivalenceTest.sol`: 24-turn legacy vs `selectMoveWithStateHint × 24 + executeBatch × 3` byte-equality.
- [ ] Lying-hint test confirms §7.1 trust model.
- [ ] `test/BetterCPUBatchGasTest.sol`: mirror inline tests; snapshot B=1/4/8.

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

### Phase 0.5 + Phase 1 (shadow layer fully implemented)

- **Shadow infrastructure built.** §5.1's full slot inventory landed: MonState (per-mon, lazy-loaded), KO bitmaps (BattleConfig slot 2), BattleData slot 1 (helpers added but BattleData itself stayed on storage refs — see below), effect slots (per §5.1.1: 144 keys, two transient regions per slot), effect counts (3 packed mirrors), and globalKV (sparse 16-slot buffer). Eight §5.2 helpers added with both shadow and storage branches. `_flushShadow` walks dirty bits and SSTOREs once at end of batch. New engine entry `executeBatchedTurns(bytes32, uint256[])` activates shadow, loops sub-turns with flag-based dispatch, flushes, returns executed count + winner. Manager's `executeBuffered` now delegates to this entry.
- **Helpers take `BattleConfig storage cfg` explicitly.** First pass had effect/KO helpers read `battleConfig[storageKeyForWrite]` internally. That broke when external view getters (`getEffects`, `getKOBitmap`) called helpers outside execute — `storageKeyForWrite` is `bytes32(0)` there, so helpers read an empty config and returned 0 effects. Fix: thread cfg through every helper signature. 53 tests failed before the fix; all 533 pass after.
- **Reads are view-compatible (no TSTORE on read).** §5.2's spec implied lazy-load on first read (TSTORE to cache). That's incompatible with `view` callers — Solidity treats TSTORE as state mutation, breaking staticcall from external view getters. Redesigned reads to: check loaded bit (set only by writes), return shadow value if set, else fall back to direct SLOAD. Lazy-load happens only on writes (which are non-view anyway). External view getters can now call shadow read helpers during execute and see in-progress state correctly.
- **External view getters route through shadow.** `getMonStateForBattle`, `getGlobalKV`, `getEffects` all consult shadow when called during execute (effects calling these as part of their hook see the latest values). Outside execute, shadow is inactive so they read storage as before.
- **BattleData stayed on storage refs.** §5.1 lists BattleData slot 1 as shadowed, and I added `_shadowReadBattleData` / `_shadowWriteBattleData` / `_packBattleData` / `_unpackBattleData` / `_flushShadowBattleData`. But refactoring `_executeInternal` and its helpers from `BattleData storage battle = battleData[battleKey]` to the memory pattern would have rippled through ~13 function signatures and required careful checkpoint handling around every external callback (move/effect hooks that re-enter the engine and might mutate `battle.*`). For Phase 1 I left BattleData on the storage-ref pattern — it's still consistent (engine writes/reads via storage refs throughout `_executeInternal`), just not deduplicated across sub-turns. If the architectural finding below changes, this becomes the next optimization to land.
- **Architectural finding (definitive): shadow layer does NOT deliver gas savings.** Measured with `test/BatchGasTest.sol` (8 sub-turn clean damage trade):

  | Path | Before Phase 0.5/1 | After Phase 0.5/1 | Delta |
  |---|---|---|---|
  | legacy (per-turn) — B=8 total | 687,748 | 848,960 | **+161k** (+23%) |
  | batched (submit + execute) — B=8 total | 936,847 | 1,172,164 | **+235k** (+25%) |
  | batched − legacy gap — B=8 | +249k (+36%) | +323k (+38%) | gap grew |

  The shadow layer:
  - Adds ~20k/turn overhead to the legacy path (memory pattern instead of storage refs; helpers do a `_shadowActive` TLOAD check + memory pack/unpack on every read, paid even when shadow is inactive). This regresses every existing gas test by 1-7k.
  - Saves ~24k/sub-turn on the executeBuffered path (within-batch SSTORE coalescing for MonState + effect slots + counts + KO bitmap + globalKV). That's roughly the per-sub-turn SSTORE work that gets deferred to the single final flush.
  - The per-submission overhead (~85k each: sig recovery + buffer SSTORE + counter SSTORE) is unchanged by the shadow — it's submission infrastructure, not engine-state infrastructure. Eight submissions × 85k = 680k of overhead the shadow can't recover.

  Conclusion: the gas-savings claim in OPT_PLAN §1 is **not architecturally achievable** with a per-turn buffer design. The 85k/turn submission cost is the floor, and engine-side savings from shadow (~24k/turn × N−1 amortized) don't close it. To beat dual-signed-per-turn execution, batching would need a fundamentally different submission scheme — Merkle-rooted batch claims, signature aggregation (BLS / SNARK), or off-chain ordering with on-chain finality proofs. None of those fit in the per-turn-SSTORE model.

  The batched API still has real value (single-tx execution off-peak, flexibility for relayers, async submission UX), just not raw gas savings. The shadow layer remains in place because it's correct and the substrate is there if a future submission redesign closes the gap — but on its own, it's a net loss to ship.

### Phase 0.1

- **Effect-heavy mock.** §0.1 mentioned "StatBoosts-style multi-stat effect + BurnStatus". Both have heavy external dependencies (StatBoosts needs its own deploy and per-mon snapshot KV; BurnStatus needs the StatBoosts instance). For an instrumentation test where only the per-turn storage-access pattern matters, that's overkill. Wrote a 50-LOC `test/mocks/PerTurnTickEffect.sol` that hooks RoundStart + RoundEnd + AfterDamage + ALWAYS_APPLIES and bumps a counter in `data` each tick. Same SLOAD/SSTORE shape (effect slot reads, data SSTOREs, count SLOADs in `_runEffects`), zero external setup. If the shadow layer ever needs differential testing against StatBoosts/Burn specifically, that belongs in Phase 1's effect-shadow correctness suite, not here.
- **Multi-mon scenario interpretation.** §0.1 wording was "all four mons referenced via onUpdateMonState listeners on bench mons". Production engine doesn't actually touch bench mons during a regular turn — only the active mons on each side. The natural multi-slot turn is a switch turn where p0 switches mon 0→1 while p1 attacks (touches p0 mon 0, p0 mon 1, p1 mon 0 = three distinct mon-state slots). Implemented that interpretation; logs show 16 cold SLOADs / 16 unique slots — slightly fewer than a clean trade because no second-attack SSTORE pattern.
- **Forced-switch entry point.** `_fastTurn` goes through `executeWithDualSignedMoves`, which reverts `NotTwoPlayerTurn()` once `playerSwitchForTurnFlag != 2`. Added a `_fastSinglePlayerTurn` helper that routes through `executeSinglePlayerMove(...)` with `vm.prank(actingPlayer)`. This is the same dispatch the production code does and matches what the batch flow will do via §6.1.

