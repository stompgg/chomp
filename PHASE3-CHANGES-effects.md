# Phase 3B: Effects System Optimization — Changes Summary

## Change 1: Cached Effect Counts in `_runEffects` (Engine.sol ~line 1158)

**Before:** The `while(true)` loop re-read `effectsCount` from storage (SLOAD) on EVERY iteration, even when no effect was processed (tombstoned effects).

**After:** Cache `effectsCount` before the loop. Only re-read from storage after actually running a non-tombstoned effect (which might add new effects). Tombstoned effect iterations skip the re-read entirely.

**Gas savings:** ~2,100 gas per tombstoned effect iteration (avoids warm SLOAD). For loops with N effects where T are tombstoned, saves T × 2,100 gas.

**Safety:** Effects that add new effects still trigger a re-read, preserving the original behavior where new effects get processed in the same loop.

## Change 2: `updateMonState()` If-Else Chain Order (Engine.sol ~line 619)

**Status:** Already optimal — HP and Stamina (the most common state updates) are already the first two checks in both `updateMonState()` and `getMonValueForBattle()`. No change needed.

**Assembly optimization:** Skipped per task guidance — too risky for the CLEARED_MON_STATE_SENTINEL logic and IsKnockedOut/ShouldSkipTurn special handling.

## Change 3: `getActiveMonIndexPacked()` (Engine.sol ~line 1791, IEngine.sol)

**Added:** New `getActiveMonIndexPacked(bytes32 battleKey) external view returns (uint16)` function that returns the raw packed `activeMonIndex` directly. Lower 8 bits = player 0's active mon, upper 8 bits = player 1's active mon.

**Gas savings:** Avoids memory allocation of `uint256[2]` array (~200+ gas per call). Callers that only need one player's index can unpack with a simple bit shift instead of allocating a full array.

**Backward compatibility:** Original `getActiveMonIndexForBattleState()` preserved unchanged.

## Files Modified
- `src/Engine.sol` — Changes 1 and 3
- `src/IEngine.sol` — Added `getActiveMonIndexPacked` to interface

## Verification
- Build: ✅ Compiles successfully with via_ir
- Tests: ✅ **222 passed, 0 failed, 0 skipped**
