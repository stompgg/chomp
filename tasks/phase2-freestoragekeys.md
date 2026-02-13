# Phase 2B: Pre-allocate freeStorageKeys Array

## Goal
Convert `freeStorageKeys` from a dynamic `bytes32[]` (which allocates new storage slots on `.push()`) to a fixed-size array with a counter. This eliminates expensive 0→nonzero SSTORE when the array grows beyond its previous high-water mark.

## Working Directory
`/root/clawd/projects/stomp-optimized/`

## File to Modify
`src/lib/MappingAllocator.sol`

### Current Implementation
```solidity
bytes32[] private freeStorageKeys;

function _initializeStorageKey(bytes32 key) internal returns (bytes32) {
    uint256 numFreeKeys = freeStorageKeys.length;
    if (numFreeKeys == 0) return key;
    bytes32 freeKey = freeStorageKeys[numFreeKeys - 1];
    freeStorageKeys.pop();
    battleKeyToStorageKey[key] = freeKey;
    return freeKey;
}

function _freeStorageKey(bytes32 battleKey) internal {
    bytes32 storageKey = _getStorageKey(battleKey);
    freeStorageKeys.push(storageKey);
    delete battleKeyToStorageKey[battleKey];
}
```

### Target Implementation
```solidity
uint256 private constant MAX_FREE_KEYS = 64; // Support up to 64 concurrent battles
bytes32[64] private freeStorageKeys; // Fixed-size, pre-allocated slots
uint256 private freeKeysCount; // Track how many keys are in the "stack"

function _initializeStorageKey(bytes32 key) internal returns (bytes32) {
    uint256 count = freeKeysCount;
    if (count == 0) return key;
    unchecked {
        bytes32 freeKey = freeStorageKeys[count - 1];
        freeKeysCount = count - 1;
        battleKeyToStorageKey[key] = freeKey;
        return freeKey;
    }
}

function _freeStorageKey(bytes32 battleKey) internal {
    bytes32 storageKey = _getStorageKey(battleKey);
    uint256 count = freeKeysCount;
    require(count < MAX_FREE_KEYS, "Free keys full");
    freeStorageKeys[count] = storageKey;
    freeKeysCount = count + 1;
    delete battleKeyToStorageKey[battleKey];
}

function _freeStorageKey(bytes32 battleKey, bytes32 storageKey) internal {
    uint256 count = freeKeysCount;
    require(count < MAX_FREE_KEYS, "Free keys full");
    freeStorageKeys[count] = storageKey;
    freeKeysCount = count + 1;
    delete battleKeyToStorageKey[battleKey];
}

function getFreeStorageKeys() view public returns (bytes32[] memory) {
    uint256 count = freeKeysCount;
    bytes32[] memory keys = new bytes32[](count);
    for (uint256 i = 0; i < count;) {
        keys[i] = freeStorageKeys[i];
        unchecked { ++i; }
    }
    return keys;
}
```

### Key Points
1. The fixed-size `bytes32[64]` pre-allocates 64 storage slots at deploy time (they'll be zero but the SLOTS exist)
2. After first use, subsequent writes become nonzero→nonzero (~100-2100 gas) instead of 0→nonzero (22,100+ gas)
3. The `freeKeysCount` counter replaces `.length` / `.push()` / `.pop()`
4. `getFreeStorageKeys()` must still return a dynamic `bytes32[] memory` for backward compatibility
5. The first battle cycle will "warm up" all 64 slots as they get used and freed

### Also check
- `src/Engine.sol` — does it call `getFreeStorageKeys()` or access freeStorageKeys directly? Search for it.
- Any test files that check `getFreeStorageKeys()` behavior

```bash
grep -rn "getFreeStorageKeys\|freeStorageKeys" src/ test/
```

## Verification
```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge build 2>&1 | tail -5
forge test 2>&1 | tail -10
```
Must compile and pass 223 tests.

## Output
Write changes directly to files. Write summary to `/root/clawd/projects/stomp-optimized/PHASE2-CHANGES-freestoragekeys.md`
