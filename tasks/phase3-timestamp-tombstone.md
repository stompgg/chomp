# Phase 3A: block.timestamp Reordering + Tombstone Storage Refunds

## Working Directory
`/root/clawd/projects/stomp-optimized/`

## Change 1: Move block.timestamp to End of startBattle()

### Why
On MegaETH, accessing `block.timestamp` triggers a 20M compute gas ceiling for the remainder of the function. In `startBattle()` (Engine.sol line 250), it's accessed BEFORE team validation, hook calls, and storage writes — all heavy operations that could hit the ceiling.

### Current (Engine.sol ~line 250):
```solidity
// Set start timestamp
config.startTimestamp = uint48(block.timestamp);  // ← TRIGGERS 20M CEILING

// Build teams array for validation
Mon[][] memory teams = new Mon[][](2);
// ... heavy validation, hooks, etc follow
```

### Fix:
Move `config.startTimestamp = uint48(block.timestamp)` to the VERY LAST line of `startBattle()`, after all validation and hook calls. Find the end of the function and place it just before the final event emission or return.

**IMPORTANT:** Check that nothing between the current position and the end of the function READS `config.startTimestamp`. If something does, you can't move it past that read. Search for `config.startTimestamp` and `startTimestamp` within `startBattle()`.

### Also check DefaultCommitManager.sol:
Lines 53, 116, 225, 233 — `pd.lastMoveTimestamp = uint96(block.timestamp)`. These are in `commitMove()` and `revealMove()`. Check if they can be moved later in their respective functions.

## Change 2: Zero Tombstoned Effect Data for Storage Refunds

### Why
When effects are removed, they're "tombstoned" by setting `effect = IEffect(TOMBSTONE_ADDRESS)`, but `stepsBitmap` and `data` fields are NOT zeroed. Zeroing them gives a storage refund (~4,800 gas per cleared slot on standard EVM, potentially more on MegaETH).

### Current (Engine.sol ~line 801 and ~831):
```solidity
// Tombstone the effect
effectToRemove.effect = IEffect(TOMBSTONE_ADDRESS);
```

### Fix — add clearing of stepsBitmap and data:
```solidity
// Tombstone the effect and clear data for storage refunds
effectToRemove.effect = IEffect(TOMBSTONE_ADDRESS);
effectToRemove.stepsBitmap = 0;  // Storage refund
effectToRemove.data = bytes32(0);  // Storage refund
```

Apply this to BOTH `_removeGlobalEffect()` (~line 801) and `_removePlayerEffect()` (~line 831).

**IMPORTANT:** Verify that nothing reads `stepsBitmap` or `data` from a tombstoned effect. Search for code that accesses these fields after checking `TOMBSTONE_ADDRESS`. The `_runEffects` loop already skips tombstones (line 1187-1188), so this should be safe.

## Change 3: Short-Circuit Validation Ordering in DefaultValidator

### Why
Cheaper checks (pure comparisons, msg.sender) should come before expensive checks (storage reads).

### Check DefaultValidator.sol
Look at `validateMove()` and `validateGameStart()`. If there are storage-reading checks before pure arithmetic checks, reorder them so cheapest checks fail first.

## Verification
```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge build 2>&1 | tail -5
forge test 2>&1 | tail -10
```
Must compile and pass 222 tests.

## Output
Write changes directly to files. Write summary to `/root/clawd/projects/stomp-optimized/PHASE3-CHANGES-timestamp-tombstone.md`
