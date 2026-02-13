# Phase 1: Quick Wins — Implementation Brief

## Scope
Mechanical gas optimizations that don't change logic, storage layout, or architecture.
These are safe, low-risk changes that should NOT break any existing tests.

## Changes to Apply

### 1. Unchecked Loop Increments
Find ALL `for` loops with bounded counters and wrap the increment in `unchecked`:

```solidity
// BEFORE:
for (uint256 i = 0; i < length; i++) {

// AFTER:
for (uint256 i = 0; i < length;) {
    // ... body ...
    unchecked { ++i; }
}
```

**Rules:**
- Only apply when the loop bound is a known-safe value (array length, constant, function param)
- Use `++i` (pre-increment) not `i++`
- Move the increment to the END of the loop body inside `unchecked {}`

### 2. `calldata` Instead of `memory` for Read-Only Parameters
Find function parameters declared as `memory` that are never modified within the function body:

```solidity
// BEFORE:
function foo(uint256[] memory data) external {

// AFTER:
function foo(uint256[] calldata data) external {
```

**Rules:**
- Only for `external` functions (not `public` that might be called internally)
- Only when the param is NOT modified in the function body
- Applies to: arrays, bytes, strings, structs passed as params
- Do NOT change `memory` returns — only parameters

### 3. `pure` for Constant-Returning Functions
Functions that return compile-time constants should be `pure` not `view`:

```solidity
// BEFORE:
function name() external view returns (string memory) { return "MyEffect"; }

// AFTER:
function name() external pure returns (string memory) { return "MyEffect"; }
```

**Rules:**
- Only when the function reads NO storage and NO blockchain state
- Common targets: `name()`, `moveClass()`, `moveType()`, `priority()`, `stamina()` that return constants
- Check that the function doesn't inherit from an interface that requires `view` — if the interface says `view`, you can still make the implementation `pure` (pure is stricter than view, it's compatible)

### 4. Cache Repeated `keccak256` Computations
When the same hash is computed multiple times in a function, compute once and reuse:

```solidity
// BEFORE:
bytes32 key1 = keccak256(abi.encode(playerIndex, monIndex, name()));
// ... later in same function ...
bytes32 key2 = keccak256(abi.encode(playerIndex, monIndex, name()));

// AFTER:
bytes32 key = keccak256(abi.encode(playerIndex, monIndex, name()));
// ... reuse `key` everywhere ...
```

**For keys that use `name()` (a constant string):** Consider computing once as an immutable:
```solidity
bytes32 private immutable EFFECT_KEY_HASH = keccak256(bytes(name()));
// Then in functions:
bytes32 key = keccak256(abi.encode(playerIndex, monIndex, EFFECT_KEY_HASH));
```
NOTE: immutable can't call name() at deploy time if it's virtual. In that case, just cache within each function call.

## Verification
After making changes:
1. Run `forge build` — must compile with zero errors
2. Run `forge test` — must pass the same 221 tests that currently pass (2 are pre-existing failures)
3. Do NOT introduce new test failures

## Output
Write all changes directly to the .sol files in `/root/clawd/projects/stomp-optimized/`.
After making changes, run `forge build` and `forge test` to verify.
Write a summary of all changes made to `/root/clawd/projects/stomp-optimized/PHASE1-CHANGES-{your-scope}.md`.
