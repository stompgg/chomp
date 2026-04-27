# OPT_PLAN — Batched Execute Gas Optimization

## 1. Goal

Amortize per-turn cold-storage access in `Engine.execute()` by:
1. Submitting each turn's signed moves on-chain immediately to a per-turn buffer (no execute).
2. Executing `N` buffered turns in one tx with engine state held in **transient shadow storage**, flushed to persistent storage once at the end.

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

`Engine.executeBatch(battleKey, numTurns)`:
- Anyone can call (sigs were checked at submission).
- Reads buffered entries `[BattleData.turnId, BattleData.turnId + numTurns)`, runs each in sequence inside transient shadow storage, flushes once at end.
- `BattleData.turnId` advances inside the loop; next batch starts at the right slot.
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
function executeBatch(bytes32 battleKey, uint64 numTurns) external;
```

1. Read `startTurn = BattleData.turnId`; require turns `[startTurn, startTurn+numTurns)` all buffered.
2. Hydrate shadow.
3. For each turn: read buffer slot, populate per-turn move/salt transient, run `_executeOneTurn()`, break on game-over.
4. Flush shadow → storage.

---

## 5. Transient shadow storage

### 5.1 Shadowed state

| Storage | Shadow form |
|---|---|
| `MonState` (per mon) | Per-`(playerIndex, monIndex)` mirror, lazy-loaded. Dirty bit per slot. |
| `koBitmaps` (16 bits in `BattleConfig` slot 2) | `uint16` mirror, loaded flag. |
| `winnerIndex` / `prevPlayerSwitchForTurnFlag` / `playerSwitchForTurnFlag` / `activeMonIndex` / `turnId` / `lastExecuteTimestamp` | Single packed `uint256` mirror. |
| Effect data slots (`globalEffects[i].data`, `pXEffects[i].data`) | Sparse transient map keyed by slot index, mirrors `data` only. `effect`/`stepsBitmap` read from storage (warm after first hit). |
| `packedP0EffectsCount` / `packedP1EffectsCount` / `globalEffectsLength` | Three small mirrors, flushed with effect-list shadow. |
| `globalKV[storageKey][key]` | Per-`key` mirror, lazy-loaded. |
| `BattleConfig.p0Move` / `p1Move` / salts | Re-populated per sub-turn from buffer slot. |

Hydrate strategy:
- **Eager**: `BattleData` slot 1 + `BattleConfig` slot 2 (always touched).
- **Lazy**: `MonState`, effect data, `globalKV` (sparse — pay only for slots touched).

Loaded-flag strategy:
- **Bitmap** for fixed-shape slots (MonState, effects, slot-2 packed fields).
- **Per-key transient hash-set** for `globalKV` (dynamic keys).

### 5.2 Helper boundary

Mirrored helpers in `Engine.sol`:

```solidity
function _shadowReadMonState(BattleConfig storage cfg, uint256 playerIndex, uint256 monIndex) internal returns (MonState memory);
function _shadowWriteMonState(uint256 playerIndex, uint256 monIndex, MonState memory state) internal;
function _shadowReadKV(bytes32 storageKey, uint64 key) internal returns (uint192);
function _shadowWriteKV(bytes32 storageKey, uint64 key, uint192 value) internal;
function _shadowReadEffectData(uint256 effectList, uint256 monIndex, uint256 slotIndex) internal returns (bytes32);
function _shadowWriteEffectData(uint256 effectList, uint256 monIndex, uint256 slotIndex, bytes32 data) internal;
```

When `_shadowActive == false`, helpers SLOAD/SSTORE storage directly. When `true`, they read/write the transient mirror with lazy-load and dirty-bit bookkeeping.

External `IEngine` writers (`updateMonState`, `dealDamage`, `addEffect`, `removeEffect`, `editEffect`, `setGlobalKV`, `switchActiveMon`, `dispatchStandardAttack`, `setMove`) and external readers (`getMonStateForBattle`, `getEffects`, `getGlobalKV`, etc.) all route through these helpers. The `battleKeyForWrite != bytes32(0)` gate stays.

### 5.3 Batch loop

```
executeBatch(battleKey, numTurns):
    storageKey = _getStorageKey(battleKey)
    storageKeyForWrite = storageKey
    battleKeyForWrite = battleKey
    _shadowActive = true

    _hydrateBattleData(battleKey)
    _hydrateConfigSlot2(storageKey)

    startTurn = BattleData.turnId
    for t in [startTurn .. startTurn + numTurns):
        bufferEntry = _readMoveBufferSlot(storageKey, t)
        _populateTurnMoveTransient(bufferEntry)
        _executeOneTurn()
        if winnerIndex != 2: break
        _resetPerTurnTransients()

    _flushBattleData(battleKey)
    _flushConfigSlot2(storageKey)
    _flushDirtyMonStates(storageKey)
    _flushDirtyEffectData(storageKey)
    _flushDirtyGlobalKV(storageKey)

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

`_executeInternal` already breaks when `winnerIndex != 2`. Same check stops the batch loop. Remaining buffered entries stay untouched.

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

1. Read current `turnId` from `BattleData`.
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

**Phase 2 — PvP per-turn submission + batch execute.** Extend `SignedCommitManager` with `submitTurnMoves`. Add per-turn move buffer mapping. Add `Engine.executeBatch` with flag-based dispatch (§6.1). Equivalence tests + gas snapshots.

**Phase 2.5 — CPU mode.** Extend `CPUMoveManager` with `selectMoveWithStateHint` (§7.4). Reuse Phase-2 buffer + `executeBatch`. Equivalence test: 24-turn CPU game via legacy `selectMove × 24` vs `selectMoveWithStateHint × 24 + executeBatch × 3` produces identical end state.

**Phase 3 — Transpiler parity (deferred).** Local TS engine continues running single-turn `execute()` against hydrated state. Eventual batched parity desired but not v1.

**Phase 4 — Optional cutover.** If `executeShadowed` (B=1) is gas-neutral or better, consider redirecting. Otherwise keep the legacy fast path.

---

## 10. Test surface

New `BattleHelper` helpers:
- `_submitTurnMoves(battleKey, turnId, p0Move, p1Move)` — synthesizes signatures and calls `submitTurnMoves`.
- `_executeBuffered(battleKey, numTurns)` — calls `executeBatch`.

New tests:
- **Submission validation**: wrong committer signer, wrong revealer signer (parity), wrong turnId, wrong battleKey, replay, committer preimage hash mismatch, missing committer sig (regression for unilateral-revealer attack), missing revealer sig.
- **Buffer ordering**: out-of-order rejected; batch executes in turnId order.
- **Switch-turn dispatch**: `flag == 0` and `flag == 1` ignore the non-acting half; non-acting player signing a non-NO_OP has no effect.
- **Equivalence (core gate)**: B turns through legacy path vs `submitTurnMoves × B + executeBatch` produce byte-identical state.
- **Game-over short-circuit** mid-batch.
- **Effect lifecycle parity**: BurnStatus DOT over a 4-turn batch matches per-turn execution.
- **Multi-batch in one battle**: two batches of 4, then one of 6 — `turnId` advances correctly.
- **Shadow flush**: post-batch `getMonStateForBattle` / `getGlobalKV` / `getEffects` match equivalent per-turn execution.
- **CPU equivalence**: 24-turn CPU game via legacy vs trusted-state batched produces identical end state.

Existing tests stay untouched — they use the legacy entry points.

Targeted equivalence tests for v1; differential fuzzing as a follow-up.
