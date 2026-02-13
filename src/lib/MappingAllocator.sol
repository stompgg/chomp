// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

abstract contract MappingAllocator {

    uint256 private constant MAX_FREE_KEYS = 64;
    bytes32[64] private freeStorageKeys;
    uint256 private freeKeysCount;
    mapping(bytes32 => bytes32) private battleKeyToStorageKey;

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

    function _getStorageKey(bytes32 battleKey) internal view returns (bytes32) {
        bytes32 storageKey = battleKeyToStorageKey[battleKey];
        if (storageKey == bytes32(0)) {
            return battleKey;
        }
        else {
            return storageKey;
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
}
