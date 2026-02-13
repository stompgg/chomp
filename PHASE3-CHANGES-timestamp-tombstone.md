# Phase 3A Changes: block.timestamp Reordering + Tombstone Storage Refunds

## Change 1: Move `block.timestamp` to End of `startBattle()` (Engine.sol)

**Rationale:** On MegaETH, accessing `block.timestamp` triggers a 20M compute ceiling for the remainder of the function. Previously, it was accessed BEFORE team validation, hook calls, and the event emission — all heavy operations that could hit the ceiling.

**What changed:** Moved `config.startTimestamp = uint48(block.timestamp)` from before team validation to just before the final `emit BattleStart(...)` — after all validation (`validateGameStart`), hook calls (`onBattleStart`), and storage writes.

**Safety verification:**
- Searched all uses of `config.startTimestamp` / `startTimestamp` in `startBattle()` — nothing between the old position and the new position reads it
- `validateGameStart()` receives only player addresses, teams, registry, and team indices — NOT config
- `onBattleStart(battleKey)` hooks receive only the battleKey; no hook implementations read `startTimestamp`
- The only consumers of `startTimestamp` are in `execute()`, `commitMove()`, `revealMove()`, and `validateTimeout()` — all separate transactions

**DefaultCommitManager:** The `block.timestamp` assignments at lines 53, 116, 225, 233 are already at the end of their respective storage operations (after all validation), so no reordering needed.

## Change 2: Zero Tombstoned Effect Fields for Storage Refunds (Engine.sol)

**Rationale:** When effects are tombstoned, only `effect` was set to `TOMBSTONE_ADDRESS`, leaving `stepsBitmap` and `data` as non-zero. Zeroing them triggers EVM storage refunds (~4,800 gas per cleared slot).

**What changed:** Added two lines after each tombstone assignment in both `_removeGlobalEffect()` and `_removePlayerEffect()`:
```solidity
effectToRemove.stepsBitmap = 0;
effectToRemove.data = bytes32(0);
```

**Safety verification:**
- `_runEffects` loop already skips tombstoned effects via `if (address(eff.effect) != TOMBSTONE_ADDRESS)` check
- All effect iteration code checks the tombstone address FIRST, before reading `stepsBitmap` or `data`
- The `stepsBitmap` and `data` values are read INTO local variables BEFORE the tombstone is set (for the `onRemove` callback), so the zeroing doesn't affect the removal flow

## Change 3: Short-Circuit Validation Ordering (DefaultValidator.sol)

**Assessment:** The existing validation ordering in `DefaultValidator.sol` is already well-optimized:
- `validatePlayerMove()` already checks cheap operations first (turnId == 0, moveIndex comparisons) before expensive external calls
- `validateGameStart()` checks team counts (single storage read) before iterating mons
- Phase 2 already introduced `ValidationContext` to batch external calls

No changes were needed — the existing ordering is already optimal.

## Verification

- **Build:** `forge build` — compiled successfully (206 files, Solc 0.8.28, via_ir)
- **Tests:** `forge test` — **222/222 tests passed**, 0 failed, 0 skipped
