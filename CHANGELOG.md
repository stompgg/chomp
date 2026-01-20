# Changelog

## Double Battles Implementation

This document summarizes all changes made to implement double battles support.

---

### Core Data Structure Changes

#### `src/Enums.sol`
- Added `GameMode` enum: `Singles`, `Doubles`

#### `src/Structs.sol`
- **`BattleArgs`** and **`Battle`**: Added `GameMode gameMode` field
- **`BattleData`**: Added `slotSwitchFlagsAndGameMode` (packed field: lower 4 bits = per-slot switch flags, bit 4 = game mode)
- **`BattleContext`** / **`BattleConfigView`**: Added `p0ActiveMonIndex0`, `p0ActiveMonIndex1`, `p1ActiveMonIndex0`, `p1ActiveMonIndex1`, `slotSwitchFlags`, `gameMode`

#### `src/Constants.sol`
- Added `GAME_MODE_BIT`, `SWITCH_FLAGS_MASK`, `ACTIVE_MON_INDEX_MASK` for packed storage

---

### New Files

#### `src/BaseCommitManager.sol`
Extracted shared commit/reveal logic from singles and doubles managers:
- Common errors, events, and storage
- Shared validation functions: `_validateCommit`, `_validateRevealPreconditions`, `_validateRevealTiming`, `_updateAfterReveal`, `_shouldAutoExecute`

#### `src/DoublesCommitManager.sol`
Commit/reveal manager for doubles handling 2 moves per player per turn:
- `commitMoves(battleKey, moveHash)` - Single hash for both moves
- `revealMoves(...)` - Reveal both slot moves with cross-slot switch validation

---

### Interface Changes

#### `src/IEngine.sol`
```solidity
function getActiveMonIndexForSlot(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex) external view returns (uint256);
function getGameMode(bytes32 battleKey) external view returns (GameMode);
function switchActiveMonForSlot(uint256 playerIndex, uint256 slotIndex, uint256 monToSwitchIndex) external;
function setMoveForSlot(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex, uint256 moveIndex, bytes32 salt, uint240 extraData) external;
```

#### `src/IValidator.sol`
```solidity
function validatePlayerMoveForSlot(bytes32 battleKey, uint256 moveIndex, uint256 playerIndex, uint256 slotIndex, uint240 extraData) external returns (bool);
function validatePlayerMoveForSlotWithClaimed(bytes32 battleKey, uint256 moveIndex, uint256 playerIndex, uint256 slotIndex, uint240 extraData, uint256 claimedByOtherSlot) external returns (bool);
function validateSpecificMoveSelection(bytes32 battleKey, uint256 moveIndex, uint256 playerIndex, uint256 slotIndex, uint240 extraData) external returns (bool);
```

---

### Engine Changes

#### Unified Active Mon Index Packing
- Singles and doubles now use the same 4-bit-per-slot packing format
- Singles uses slot 0 only; doubles uses slots 0 and 1
- Removed deprecated `_packActiveMonIndices`, `_unpackActiveMonIndex`, `_setActiveMonIndex`
- All code now uses `_unpackActiveMonIndexForSlot` and `_setActiveMonIndexForSlot`

#### Slot-Aware Effect Execution
- Added overloaded `_runEffects` accepting explicit `monIndex` parameter
- Switch effects (`OnMonSwitchIn`, `OnMonSwitchOut`) pass the switching mon's index
- `dealDamage` passes target mon index to `AfterDamage` effects
- `updateMonState` passes affected mon index to `OnUpdateMonState` effects

#### Doubles Execution Flow
- `_executeDoubles` handles 4 moves per turn with priority/speed ordering
- `_checkForGameOverOrKO_Doubles` checks both slots for each player
- Per-slot switch flags track which slots need to switch after KOs

---

### Validator Changes

#### `src/DefaultValidator.sol`
- `validateSwitch` checks both slots in doubles mode
- `validateSpecificMoveSelection` accepts `slotIndex` for correct mon lookup
- `_getActiveMonIndexFromContext` helper for slot-aware active mon retrieval
- Unified `_hasValidSwitchTargetForSlot` with optional `claimedByOtherSlot` parameter

---

### Test Coverage

#### `test/DoublesValidationTest.sol` (35 tests)
- Turn 0 switch requirements
- KO'd slot handling (with/without valid switch targets)
- Both slots KO'd scenarios (0, 1, or 2 reserves)
- Single-player switch turns (one player switches, other attacks)
- Force-switch moves targeting specific slots
- Storage reuse between singles↔doubles transitions
- Effects running on correct mon for both slots
- Move validation using correct slot's mon stamina
- AfterDamage effects healing correct mon

#### `test/DoublesCommitManagerTest.sol` (11 tests)
- Commit/reveal flow for doubles
- Move execution ordering by priority and speed
- Position tiebreaker for equal speed
- Game over detection when all mons KO'd

#### Test Mocks Added
- `DoublesTargetedAttack` - Attack targeting specific opponent slot
- `DoublesForceSwitchMove` - Force-switch specific opponent slot
- `DoublesEffectAttack` - Apply effect to specific slot
- `EffectApplyingAttack` - Generic effect applicator for testing
- `MonIndexTrackingEffect` - Tracks which mon effects run on

---

### Client Usage

#### Starting a Doubles Battle
```solidity
Battle memory battle = Battle({
    // ... other fields ...
    moveManager: address(doublesCommitManager),
    gameMode: GameMode.Doubles
});
```

#### Turn Flow
```solidity
// Commit hash of both moves
bytes32 moveHash = keccak256(abi.encodePacked(
    moveIndex0, extraData0,
    moveIndex1, extraData1,
    salt
));
doublesCommitManager.commitMoves(battleKey, moveHash);

// Reveal both moves
doublesCommitManager.revealMoves(battleKey, moveIndex0, extraData0, moveIndex1, extraData1, salt, true);
```

#### KO'd Slot Handling
- KO'd slot with valid switch targets → must SWITCH
- KO'd slot with no valid switch targets → must NO_OP
- Both slots KO'd with one reserve → slot 0 switches, slot 1 NO_OPs

---

### Future Work

#### Target Redirection
When a target slot is KO'd mid-turn, moves targeting that slot should redirect or fail. Currently handled by individual move implementations.

#### Move Targeting System
- Standardize targeting semantics (self, ally, opponent slot 0/1, both opponents, all)
- Consider `TargetType` enum and standardized `extraData` encoding

#### Speed Tie Handling
Currently uses basic speed comparison with position tiebreaker. May need explicit rules (random, player advantage).

#### Ability/Effect Integration
- Abilities affecting both slots (e.g., Intimidate)
- Weather/terrain affecting 4 mons
- Spread moves hitting multiple targets

#### Execution Pattern Unification
- Singles: `revealMove` → `execute` directly
- Doubles: `revealMoves` → `setMoveForSlot` × 2 → `execute`
- Consider unifying if performance permits

#### Slot Information in Move Interface
- `IMoveSet.move()` doesn't receive attacker's slot index
- Limits slot-aware move logic in doubles
