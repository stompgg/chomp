// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

abstract contract MappingAllocator {
    // Non-shrinking free list. Values stay in place above the live count (pop only decrements
    // the counter), so steady-state push/pop cycles are nonzero->nonzero counter rewrites
    // (~2.9k) — or even same-value no-ops for the key lane — instead of the fresh 20k
    // zero->nonzero writes Solidity's array push/pop paid every battle lifecycle (pop() zeroes
    // the element and the length slot toggles 0<->1 at low pool depth).
    //
    // `freeKeyCountPlusOne` is the live count biased +1 once initialized (0 = never used), so
    // the counter itself also never returns to zero. Lanes at index >= count hold stale garbage
    // BY DESIGN — every reader must bound itself by the counter.
    //
    // NOTE for Surgery.s.sol / any in-place migration: these two declarations replace the old
    // `bytes32[] freeStorageKeys; mapping(bytes32 => bytes32) battleKeyToStorageKey;` pair. The
    // slot COUNT is unchanged (inheriting contracts' own variables do not shift), but slot 0's
    // meaning changed (array length -> lane mapping base) and the counter lives in slot 1's
    // position... fresh deploys only.
    mapping(uint256 => bytes32) private freeStorageKeys;
    uint256 private freeKeyCountPlusOne;
    mapping(bytes32 => bytes32) private battleKeyToStorageKey;

    function _freeKeyCount() private view returns (uint256) {
        uint256 v = freeKeyCountPlusOne;
        unchecked {
            return v == 0 ? 0 : v - 1;
        }
    }

    function _initializeStorageKey(bytes32 key) internal returns (bytes32) {
        uint256 count = _freeKeyCount();
        if (count == 0) {
            return key;
        }
        // Pop: decrement the counter only — the lane value stays in place for the next push,
        // keeping that slot warm/nonzero across battle lifecycles.
        bytes32 freeKey = freeStorageKeys[count - 1];
        freeKeyCountPlusOne = count; // == (count - 1) + 1; never zero once initialized
        battleKeyToStorageKey[key] = freeKey;
        return freeKey;
    }

    function _getStorageKey(bytes32 battleKey) internal view returns (bytes32) {
        bytes32 storageKey = battleKeyToStorageKey[battleKey];
        if (storageKey == bytes32(0)) {
            return battleKey;
        }
        return storageKey;
    }

    function _freeStorageKey(bytes32 battleKey) internal {
        _freeStorageKey(battleKey, _getStorageKey(battleKey));
    }

    function _freeStorageKey(bytes32 battleKey, bytes32 storageKey) internal {
        uint256 count = _freeKeyCount();
        // Push: re-pushing into a lane that last held the same key (the single-concurrent-battle
        // steady state) is a same-value no-op write.
        freeStorageKeys[count] = storageKey;
        unchecked {
            freeKeyCountPlusOne = count + 2; // == (count + 1) + 1
        }
        delete battleKeyToStorageKey[battleKey];
    }

    function getFreeStorageKeys() public view returns (bytes32[] memory keys) {
        uint256 count = _freeKeyCount();
        keys = new bytes32[](count);
        for (uint256 i; i < count; i++) {
            keys[i] = freeStorageKeys[i];
        }
    }
}
