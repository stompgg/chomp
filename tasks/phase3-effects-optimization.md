# Phase 3B: Effects System Optimization + Engine Loop Improvements

## Working Directory
`/root/clawd/projects/stomp-optimized/`

## Change 1: Cache Effect Counts in _runEffects Loop

### Why
In Engine.sol's `_runEffects` while-loop (~line 1149+), the effects count is re-read from storage on EVERY iteration. This means N SLOAD operations for N effects (~2,100 gas each for warm reads).

### Fix
Cache the initial count and only re-check if an effect was actually added during the loop iteration. Use a local variable:

```solidity
// Cache initial count
uint256 effectsCount = _getEffectsCount(config, targetIndex, monIndex);
uint256 i = 0;
while (i < effectsCount) {
    // ... process effect ...
    // After processing, check if count changed (effect added another effect)
    uint256 newCount = _getEffectsCount(config, targetIndex, monIndex);
    if (newCount != effectsCount) {
        effectsCount = newCount; // Update only when changed
    }
    unchecked { ++i; }
}
```

**IMPORTANT:** Read the actual `_runEffects` implementation carefully. The re-read is intentional because effects can add new effects. Your caching must preserve this behavior — only skip the re-read when no new effects were added.

Find the exact function by searching:
```bash
grep -n "_runEffects\|runEffects" src/Engine.sol
```

## Change 2: Optimize updateMonState() with Assembly

### Why
`updateMonState()` uses a 9-branch if-else chain over `MonStateIndexName`. Each call does ~4.5 comparisons on average, plus a storage read and write. Since `MonState` packs into a known layout, we can use assembly to read the slot, modify the specific field by offset, and write back in 1 SLOAD + 1 SSTORE.

### Current pattern (~Engine.sol, search for `updateMonState`):
```solidity
function updateMonState(..., MonStateIndexName stateVarIndex, int32 valueDelta) {
    if (stateVarIndex == MonStateIndexName.Hp) {
        monState.hpDelta += valueDelta;
    } else if (stateVarIndex == MonStateIndexName.Stamina) {
        monState.staminaDelta += valueDelta;
    } else if ...
}
```

### Fix with assembly:
```solidity
function updateMonState(..., MonStateIndexName stateVarIndex, int32 valueDelta) {
    MonState storage monState = _getMonState(config, playerIndex, monIndex);
    // MonState layout: 7 x int32 (32 bits each) + 2 x bool (8 bits each)
    // Slot 0: hpDelta(32) | staminaDelta(32) | speedDelta(32) | attackDelta(32) | defenceDelta(32) | specialAttackDelta(32) | specialDefenceDelta(32) | isKnockedOut(8) | shouldSkipTurn(8)
    // Total: 7*32 + 2*8 = 240 bits = fits in 1 slot
    
    uint256 stateIndex = uint256(stateVarIndex);
    // Each int32 field is at offset stateIndex * 32 bits (for the first 7 fields)
    // Only update if it's one of the 7 int32 delta fields (indices 0-6)
    require(stateIndex < 7, "Invalid state index for delta update");
    
    assembly {
        let slot := monState.slot
        let packed := sload(slot)
        let bitOffset := mul(stateIndex, 32)
        let mask := shl(bitOffset, 0xFFFFFFFF)
        let currentVal := and(shr(bitOffset, packed), 0xFFFFFFFF)
        // Sign-extend currentVal from int32
        let signBit := and(currentVal, 0x80000000)
        if signBit { currentVal := or(currentVal, not(0xFFFFFFFF)) }
        // Add delta (also needs sign extension)
        let delta := valueDelta
        let newVal := add(currentVal, delta)
        // Mask back to 32 bits
        let newValMasked := and(newVal, 0xFFFFFFFF)
        // Clear old value and set new
        let cleared := and(packed, not(mask))
        let updated := or(cleared, shl(bitOffset, newValMasked))
        sstore(slot, updated)
    }
}
```

**CAUTION:** This is complex assembly. If you're not confident in the bit manipulation, skip this change and focus on the other optimizations. Getting assembly wrong will break the game.

**Alternative simpler approach:** Instead of assembly, just reorder the if-else chain so the most common state updates (HP, Stamina) are checked first. This saves a few comparisons on average.

Search for the function:
```bash
grep -n "function updateMonState\|MonStateIndexName" src/Engine.sol | head -20
```

## Change 3: Memory Optimization in getActiveMonIndexForBattleState

### Why
`getActiveMonIndexForBattleState()` returns `uint256[] memory` — allocating a memory array every call. It's called frequently during battle execution. Could return a packed uint16 instead (lower 8 bits = p0, upper 8 bits = p1).

### Fix
Add a new function `getActiveMonIndexPacked()` that returns `uint16` and use it in internal calls. Keep the old function for backward compatibility.

Search for usage:
```bash
grep -n "getActiveMonIndexForBattleState" src/ -r | head -20
```

## Verification
```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge build 2>&1 | tail -5
forge test 2>&1 | tail -10
```
Must pass 222 tests.

## Output
Write changes to files. Summary to `/root/clawd/projects/stomp-optimized/PHASE3-CHANGES-effects.md`
