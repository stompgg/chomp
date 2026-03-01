# Plan: Re-implement Doubles Battle Support on Current Main

## Design Principles

1. **Work WITH main's architecture** - Keep `getStepsBitmap()`, keep `battleKey` + `p0ActiveMonIndex`/`p1ActiveMonIndex` in effect signatures, keep bitmap-based hook filtering, keep `ValidatorLogic` library
2. **Additive, not destructive** - Singles behavior must remain identical; doubles is a new code path
3. **Minimal interface changes** - Add new functions/getters rather than changing existing ones where possible
4. **Incremental commits** - Each commit should compile and not break existing tests

## Phase 1: Core Data Structures

### 1a. Add GameMode enum to Enums.sol
```solidity
enum GameMode {
    Singles,  // 0
    Doubles   // 1
}
```

### 1b. Update Structs.sol

**BattleData** - Add `slotSwitchFlagsAndGameMode` field:
```solidity
struct BattleData {
    address p1;
    uint64 turnId;
    address p0;
    uint8 winnerIndex;
    uint8 prevPlayerSwitchForTurnFlag;
    uint8 playerSwitchForTurnFlag;
    uint16 activeMonIndex; // Singles: 8+8 bit packing; Doubles: 4+4+4+4 bit packing
    uint8 slotSwitchFlagsAndGameMode; // bits 0-3: slot switch flags, bit 4: gameMode
}
```

**BattleConfig** - Add second move pair for doubles:
```solidity
MoveDecision p0Move;   // Slot 0 for p0
MoveDecision p1Move;   // Slot 0 for p1
MoveDecision p0Move2;  // Slot 1 for p0 (doubles only)
MoveDecision p1Move2;  // Slot 1 for p1 (doubles only)
```

**Battle/ProposedBattle** - Add `GameMode gameMode` field

**BattleContext** - Keep existing `p0ActiveMonIndex`/`p1ActiveMonIndex` for singles backward compatibility

**CommitContext** - Add `uint8 slotSwitchFlags` and `GameMode gameMode`

**DamageCalcContext** - No change needed (callers will provide correct mon indices)

**New struct: RevealedMovesPair** - For DoublesCommitManager:
```solidity
struct RevealedMovesPair {
    uint8 moveIndex0;
    uint240 extraData0;
    uint8 moveIndex1;
    uint240 extraData1;
    bytes32 salt;
}
```

### 1c. Update Constants.sol
Add doubles-specific constants:
```solidity
uint8 constant ACTIVE_MON_INDEX_BITS = 4;
uint8 constant ACTIVE_MON_INDEX_MASK = 0x0F;
uint8 constant SWITCH_FLAG_P0_SLOT0 = 0x01;
uint8 constant SWITCH_FLAG_P0_SLOT1 = 0x02;
uint8 constant SWITCH_FLAG_P1_SLOT0 = 0x04;
uint8 constant SWITCH_FLAG_P1_SLOT1 = 0x08;
uint8 constant SWITCH_FLAGS_MASK = 0x0F;
uint8 constant GAME_MODE_BIT = 0x10;
```

## Phase 2: Engine.sol Changes

### 2a. Doubles active mon index packing helpers
Add alongside existing `_packActiveMonIndices`/`_unpackActiveMonIndex`/`_setActiveMonIndex`:

```solidity
function _unpackActiveMonIndexForSlot(uint16 packed, uint256 playerIndex, uint256 slotIndex) internal pure returns (uint256)
function _setActiveMonIndexForSlot(uint16 packed, uint256 playerIndex, uint256 slotIndex, uint256 monIndex) internal pure returns (uint16)
```

Packing layout for doubles: bits [0-3]=p0slot0, [4-7]=p0slot1, [8-11]=p1slot0, [12-15]=p1slot1

### 2b. Slot switch flag helpers
```solidity
function _getSlotSwitchFlags(BattleData storage battle) internal view returns (uint8)
function _setSlotSwitchFlag(BattleData storage battle, uint256 playerIndex, uint256 slotIndex) internal
function _clearSlotSwitchFlags(BattleData storage battle) internal
function _isDoublesMode(BattleData storage battle) internal view returns (bool)
```

### 2c. New getters (IEngine + Engine)
```solidity
function getGameMode(bytes32 battleKey) external view returns (GameMode)
function getActiveMonIndexForSlot(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex) external view returns (uint256)
function getDamageCalcContextForSlot(bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerSlotIndex, uint256 defenderPlayerIndex, uint256 defenderSlotIndex) external view returns (DamageCalcContext memory)
```

### 2d. Doubles move helpers
```solidity
function setMoveForSlot(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex, uint8 moveIndex, bytes32 salt, uint240 extraData) external
function _getMoveDecisionForSlot(BattleConfig storage config, uint256 playerIndex, uint256 slotIndex) internal view returns (MoveDecision memory)
```

### 2e. startBattle updates
- Accept `GameMode` from Battle struct
- When doubles: initialize activeMonIndex with 4-bit packing (p0slot0=0, p0slot1=1, p1slot0=0, p1slot1=1)
- Store gameMode in `slotSwitchFlagsAndGameMode`

### 2f. Doubles execution path
In `execute()` / `_executeInternal()`:
- Check game mode; if doubles, branch to `_executeDoubles()`
- `_executeDoubles()` handles:
  - Move order calculation across 4 slots (priority + speed tiebreaker)
  - Per-slot move execution via `_handleMoveForSlot()`
  - Per-slot switch handling via `_handleSwitchForSlot()`
  - Doubles-specific KO/game-over checks
  - Slot switch flag management for forced switches

### 2g. switchActiveMonForSlot
New external function for doubles force-switch moves:
```solidity
function switchActiveMonForSlot(uint256 playerIndex, uint256 slotIndex, uint256 monToSwitchIndex) external
```

## Phase 3: AttackCalculator.sol Updates

Add a slot-aware overload of `_calculateDamage`:
```solidity
function _calculateDamageForSlot(
    IEngine ENGINE,
    ITypeCalculator TYPE_CALCULATOR,
    bytes32 battleKey,
    uint256 attackerPlayerIndex,
    uint256 attackerSlotIndex,
    uint256 defenderSlotIndex,
    uint32 basePower,
    ... // same other params
) internal returns (int32, bytes32)
```

This calls `ENGINE.getDamageCalcContextForSlot()` instead of `ENGINE.getDamageCalcContext()`.

Keep existing `_calculateDamage` unchanged for singles backward compatibility.

## Phase 4: Slot-Aware Effects

### 4a. StaminaRegen.sol
Update `onRoundEnd`:
- Check `ENGINE.getGameMode(battleKey)`
- If doubles: iterate both slots for each player using `ENGINE.getActiveMonIndexForSlot()`
- If singles: use existing logic with `p0ActiveMonIndex`/`p1ActiveMonIndex`

### 4b. Overclock.sol
Update `onApply` and `onRemove`:
- Check game mode
- If doubles: apply/remove stat changes for both slots using `ENGINE.getActiveMonIndexForSlot()`
- If singles: use existing `p0ActiveMonIndex`/`p1ActiveMonIndex` logic

**Key insight**: These effects keep all their existing signatures. They just need to internally query extra data from the engine when in doubles mode.

## Phase 5: DoublesCommitManager

New contract `src/commit-manager/DoublesCommitManager.sol`:
- Extends the same pattern as DefaultCommitManager
- Handles committing/revealing 2 moves per turn (one per slot)
- Uses a single hash covering both moves
- Validates both moves are legal for their respective slots
- Prevents both slots from switching to the same mon
- Calls `ENGINE.setMoveForSlot()` for each slot

## Phase 6: IEngine.sol Updates

Add new function signatures (don't remove existing ones):
- `getGameMode()`
- `getActiveMonIndexForSlot()`
- `getDamageCalcContextForSlot()`
- `setMoveForSlot()`
- `switchActiveMonForSlot()`

## Phase 7: Matchmaker/Battle struct updates

- Add `GameMode gameMode` to `Battle` and `ProposedBattle`
- DefaultMatchmaker passes it through
- Default to `Singles` for backward compatibility

## Phase 8: Test Infrastructure

### 8a. BattleHelper.sol additions
- `_startDoublesBattle()` - starts a doubles mode battle
- `_doublesCommitRevealExecute()` - commit/reveal/execute for doubles (4 moves per turn)

### 8b. Test files
- Doubles validation tests (DoublesValidationTest.sol or inline in EngineTest.sol)
- StaminaRegen doubles test
- Overclock doubles test
- DoublesCommitManager test

## File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `src/Enums.sol` | Modify | Add `GameMode` enum |
| `src/Constants.sol` | Modify | Add doubles packing constants |
| `src/Structs.sol` | Modify | Add fields to BattleData, BattleConfig, Battle, ProposedBattle; add RevealedMovesPair |
| `src/IEngine.sol` | Modify | Add new getter/setter signatures |
| `src/Engine.sol` | Modify | Add doubles execution path, slot helpers, new getters |
| `src/moves/AttackCalculator.sol` | Modify | Add slot-aware damage calc function |
| `src/effects/StaminaRegen.sol` | Modify | Make doubles-aware |
| `src/effects/battlefield/Overclock.sol` | Modify | Make doubles-aware |
| `src/commit-manager/DoublesCommitManager.sol` | New | Doubles commit/reveal manager |
| `src/matchmaker/DefaultMatchmaker.sol` | Modify | Pass through GameMode |
| `test/abstract/BattleHelper.sol` | Modify | Add doubles helpers |
| `test/DoublesTest.sol` (or similar) | New | Doubles test suite |

## Commit Order

1. **Data structures + constants** - Enums, Constants, Structs changes
2. **IEngine interface** - Add new function signatures
3. **Engine core** - Slot packing helpers, getters, startBattle updates
4. **Engine doubles execution** - _executeDoubles and related functions
5. **AttackCalculator** - Slot-aware damage calculation
6. **Effects** - StaminaRegen and Overclock doubles awareness
7. **DoublesCommitManager** - New commit manager
8. **Matchmaker** - GameMode passthrough
9. **Tests** - Test infrastructure and test cases
