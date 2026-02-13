// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {EffectStep, MonStateIndexName, StatBoostFlag, StatBoostType} from "../Enums.sol";
import {EffectInstance, MonStats, StatBoostToApply} from "../Structs.sol";

import {IEngine} from "../IEngine.sol";
import {BasicEffect} from "./BasicEffect.sol";
import {IEffect} from "./IEffect.sol";

/**
 * Usage Notes:
 *  - Each effect instance stores ONE boost source in bytes32 format
 *  - Multiple boosts = multiple effect instances
 *  - Snapshot (aggregated multipliers) stored in globalKV
 *
 *  Extra Data Layout (bytes32):
 *  [8 bits isPerm | 168 bits key | 80 bits stat data]
 *  stat data = 5 stats × 16 bits: [8 boostPercent | 7 boostCount | 1 isMultiply]
 *
 *  Snapshot stored in globalKV with key: keccak256(targetIndex, monIndex, address(this))
 *  Snapshot layout (uint256):
 *  [32 empty (255-224) | 32 atk (223-192) | 32 def (191-160) | 32 spatk (159-128) | 32 spdef (127-96) | 32 speed (95-64) | 64 empty (63-0)]
 */

contract StatBoosts is BasicEffect {
    uint256 public constant DENOM = 100;
    // Layout: [8 bits isPerm | 168 bits key | 80 bits stat data]
    uint256 private constant PERM_FLAG_OFFSET = 248; // 256 - 8 = 248
    uint256 private constant KEY_OFFSET = 80;
    uint256 private constant KEY_MASK = (1 << 168) - 1;

    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() public pure override returns (string memory) {
        return "Stat Boost";
    }

    // OnMonSwitchOut=5 -> (1<<5) = 0x20
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x20;
    }

    function getStepsToRun() external pure override returns (EffectStep[] memory) {
        EffectStep[] memory steps = new EffectStep[](1);
        steps[0] = EffectStep.OnMonSwitchOut;
        return steps;
    }

    // Removes all temporary boosts on mon switch out
    function onMonSwitchOut(uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32, bool)
    {
        // Check if this is a temp boost (isPerm flag is 0)
        bool isPerm = _isPerm(extraData);
        if (!isPerm) {
            // This is a temp boost, remove it and recalculate stats
            // Pass excludeTempBoosts=true since all temp boosts are being removed
            _recalculateAndApplyStats(targetIndex, monIndex, true);
            return (extraData, true); // Remove this effect
        }
        return (extraData, false);
    }

    function _isPerm(bytes32 data) internal pure returns (bool) {
        return uint8(uint256(data) >> PERM_FLAG_OFFSET) != 0;
    }

    function _snapshotKey(uint256 targetIndex, uint256 monIndex) internal view returns (bytes32) {
        return keccak256(abi.encode(targetIndex, monIndex, address(this)));
    }

    // Pack boost instance with isPerm flag
    // Layout: [8 bits isPerm | 168 bits key | 80 bits stat data]
    function _packBoostData(uint168 key, bool isPerm, StatBoostToApply[] memory statBoostsToApply)
        internal
        pure
        returns (bytes32)
    {
        uint256 packed = isPerm ? (uint256(1) << PERM_FLAG_OFFSET) : 0;
        packed |= uint256(key) << KEY_OFFSET;

        for (uint256 i = 0; i < statBoostsToApply.length; i++) {
            uint256 statIndex = _monStateIndexToStatBoostIndex(statBoostsToApply[i].stat);
            uint256 offset = statIndex * 16;
            bool isMultiply = statBoostsToApply[i].boostType == StatBoostType.Multiply;
            uint256 boostInstance = (uint256(statBoostsToApply[i].boostPercent) << 8) | (1 << 1) | (isMultiply ? 1 : 0);
            packed |= boostInstance << offset;
        }
        return bytes32(packed);
    }

    // Extracts only isPerm and key without allocating arrays (for key matching)
    function _unpackBoostHeader(bytes32 data) internal pure returns (bool isPerm, uint168 key) {
        uint256 packed = uint256(data);
        isPerm = uint8(packed >> PERM_FLAG_OFFSET) != 0;
        key = uint168((packed >> KEY_OFFSET) & KEY_MASK);
    }

    // Full unpack with fixed-size arrays (no dynamic allocation)
    function _unpackBoostData(bytes32 data)
        internal
        pure
        returns (bool isPerm, uint168 key, uint8[5] memory boostPercents, uint8[5] memory boostCounts, bool[5] memory isMultiply)
    {
        uint256 packed = uint256(data);
        isPerm = uint8(packed >> PERM_FLAG_OFFSET) != 0;
        key = uint168((packed >> KEY_OFFSET) & KEY_MASK);
        for (uint256 i = 0; i < 5; i++) {
            uint256 offset = i * 16;
            uint256 boostInstance = (packed >> offset) & 0xFFFF;
            boostPercents[i] = uint8(boostInstance >> 8);
            boostCounts[i] = uint8((boostInstance >> 1) & 0x7F);
            isMultiply[i] = (boostInstance & 0x1) == 1;
        }
    }

    function _generateKeyNoSalt(uint256 targetIndex, uint256 monIndex, address caller)
        internal
        pure
        returns (uint168)
    {
        // Layout: [160 bits address | 7 bits monIndex | 1 bit targetIndex]
        return uint168((uint256(uint160(caller)) << 8) | (monIndex << 1) | targetIndex);
    }

    function _generateKey(uint256 targetIndex, uint256 monIndex, address caller, string memory salt)
        internal
        pure
        returns (uint168)
    {
        return uint168(uint256(keccak256(abi.encode(targetIndex, monIndex, caller, salt))));
    }

    // Accumulate boost contributions into running totals (modifies arrays in place)
    function _accumulateBoosts(
        uint32[5] memory baseStats,
        uint8[5] memory boostPercents,
        uint8[5] memory boostCounts,
        bool[5] memory isMultiply,
        uint32[5] memory numBoostsPerStat,
        uint256[5] memory accumulatedNumeratorPerStat
    ) internal pure {
        for (uint256 k = 0; k < 5; k++) {
            if (boostCounts[k] == 0) continue;
            uint256 existingStatValue = (accumulatedNumeratorPerStat[k] == 0) ? baseStats[k] : accumulatedNumeratorPerStat[k];
            uint256 scalingFactor = isMultiply[k] ? DENOM + boostPercents[k] : DENOM - boostPercents[k];
            accumulatedNumeratorPerStat[k] = existingStatValue * (scalingFactor ** boostCounts[k]);
            numBoostsPerStat[k] += boostCounts[k];
        }
    }

    function _denomPower(uint256 exp) internal pure returns (uint256) {
        if (exp == 0) return 1;
        if (exp == 1) return 100;
        if (exp == 2) return 10000;
        if (exp == 3) return 1000000;
        if (exp == 4) return 100000000;
        if (exp == 5) return 10000000000;
        if (exp == 6) return 1000000000000;
        if (exp == 7) return 100000000000000;
        // Fallback for larger exponents (rare)
        return DENOM ** exp;
    }

    function _packBoostSnapshot(uint32[5] memory unpackedSnapshot) internal pure returns (uint192) {
        return uint192(
            (uint256(unpackedSnapshot[0]) << 160) | (uint256(unpackedSnapshot[1]) << 128)
                | (uint256(unpackedSnapshot[2]) << 96) | (uint256(unpackedSnapshot[3]) << 64)
                | (uint256(unpackedSnapshot[4]) << 32)
        );
    }

    // Apply stat deltas from pre-aggregated boost data (avoids re-iterating effects)
    function _applyStatsFromAggregatedData(
        bytes32 battleKey,
        uint256 targetIndex,
        uint256 monIndex,
        uint32[5] memory baseStats,
        uint32[5] memory numBoostsPerStat,
        uint256[5] memory accumulatedNumeratorPerStat
    ) internal {
        bytes32 snapshotKey = _snapshotKey(targetIndex, monIndex);
        uint192 prevSnapshot = ENGINE.getGlobalKV(battleKey, snapshotKey);
        uint32[5] memory oldBoostedStats = _unpackBoostSnapshot(prevSnapshot, baseStats);

        // Calculate final values
        uint32[5] memory newBoostedStats;
        for (uint256 i = 0; i < 5; i++) {
            if (numBoostsPerStat[i] > 0) {
                newBoostedStats[i] = uint32(accumulatedNumeratorPerStat[i] / _denomPower(numBoostsPerStat[i]));
            } else {
                newBoostedStats[i] = baseStats[i];
            }
        }

        // Apply deltas
        for (uint256 i = 0; i < 5; i++) {
            int32 delta = int32(newBoostedStats[i]) - int32(oldBoostedStats[i]);
            if (delta != 0) {
                ENGINE.updateMonState(targetIndex, monIndex, _statBoostIndexToMonStateIndex(i), delta);
            }
        }

        // Update snapshot in globalKV
        ENGINE.setGlobalKV(snapshotKey, _packBoostSnapshot(newBoostedStats));
    }

    // Unpack snapshot, using provided base stats to fill in zeros (avoids redundant ENGINE call)
    function _unpackBoostSnapshot(uint192 boostSnapshot, uint32[5] memory baseStats)
        internal
        pure
        returns (uint32[5] memory snapshotPerStat)
    {
        snapshotPerStat[0] = uint32((boostSnapshot >> 160) & 0xFFFFFFFF);
        snapshotPerStat[1] = uint32((boostSnapshot >> 128) & 0xFFFFFFFF);
        snapshotPerStat[2] = uint32((boostSnapshot >> 96) & 0xFFFFFFFF);
        snapshotPerStat[3] = uint32((boostSnapshot >> 64) & 0xFFFFFFFF);
        snapshotPerStat[4] = uint32((boostSnapshot >> 32) & 0xFFFFFFFF);
        for (uint256 i; i < 5; i++) {
            if (snapshotPerStat[i] == 0) {
                snapshotPerStat[i] = baseStats[i];
            }
        }
    }

    // Mapping: Attack(3)->0, Defense(4)->1, SpecialAttack(5)->2, SpecialDefense(6)->3, Speed(2)->4
    // Uses arithmetic to calculate index
    // WARNING: This assumes MonStateIndexName enum ordering: Hp(0), Stamina(1), Speed(2), Attack(3), Defense(4), SpecialAttack(5), SpecialDefense(6), ...
    // If the enum is reordered, this function will break!
    function _monStateIndexToStatBoostIndex(MonStateIndexName statIndex) internal pure returns (uint256) {
        uint256 idx = uint256(statIndex);
        // Speed (2) maps to 4, Attack-SpecialDefense (3-6) map to 0-3
        if (idx == 2) return 4;
        return idx - 3; // Attack(3)->0, Defense(4)->1, SpAtk(5)->2, SpDef(6)->3
    }

    // Reverse mapping: 0->Attack(3), 1->Defense(4), 2->SpecialAttack(5), 3->SpecialDefense(6), 4->Speed(2)
    // WARNING: This assumes MonStateIndexName enum ordering (see above)
    function _statBoostIndexToMonStateIndex(uint256 statBoostIndex) internal pure returns (MonStateIndexName) {
        if (statBoostIndex == 4) return MonStateIndexName.Speed;
        return MonStateIndexName(statBoostIndex + 3);
    }

    function _getMonStatSubset(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) internal view returns (uint32[5] memory stats) {
        MonStats memory monStats = ENGINE.getMonStatsForBattle(battleKey, playerIndex, monIndex);
        stats[0] = monStats.attack;
        stats[1] = monStats.defense;
        stats[2] = monStats.specialAttack;
        stats[3] = monStats.specialDefense;
        stats[4] = monStats.speed;
    }

    // Recalculate stats by iterating through all StatBoosts effects
    // If excludeTempBoosts is true, skip temp boosts (used during onMonSwitchOut when temp boosts are being removed)
    function _recalculateAndApplyStats(uint256 targetIndex, uint256 monIndex, bool excludeTempBoosts) internal {
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        bytes32 snapshotKey = _snapshotKey(targetIndex, monIndex);
        uint192 prevSnapshot = ENGINE.getGlobalKV(battleKey, snapshotKey);

        (EffectInstance[] memory effects,) = ENGINE.getEffects(battleKey, targetIndex, monIndex);

        // Get base stats once and pass to _unpackBoostSnapshot to avoid duplicate ENGINE call
        uint32[5] memory stats = _getMonStatSubset(battleKey, targetIndex, monIndex);
        uint32[5] memory oldBoostedStats = _unpackBoostSnapshot(prevSnapshot, stats);
        uint32[5] memory newBoostedStats;
        uint32[5] memory numBoostsPerStat;
        uint256[5] memory accumulatedNumeratorPerStat;

        // Iterate through all StatBoosts effects and aggregate
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                (bool isPerm, , uint8[5] memory boostPercents, uint8[5] memory boostCounts, bool[5] memory isMultiply) =
                    _unpackBoostData(effects[i].data);
                // Skip temp boosts if excludeTempBoosts is true
                if (excludeTempBoosts && !isPerm) continue;
                _accumulateBoosts(stats, boostPercents, boostCounts, isMultiply, numBoostsPerStat, accumulatedNumeratorPerStat);
            }
        }

        // Calculate final values
        for (uint256 i = 0; i < 5; i++) {
            if (numBoostsPerStat[i] > 0) {
                newBoostedStats[i] = uint32(accumulatedNumeratorPerStat[i] / _denomPower(numBoostsPerStat[i]));
            } else {
                newBoostedStats[i] = stats[i];
            }
        }

        // Apply deltas
        for (uint256 i = 0; i < 5; i++) {
            int32 delta = int32(newBoostedStats[i]) - int32(oldBoostedStats[i]);
            if (delta != 0) {
                ENGINE.updateMonState(targetIndex, monIndex, _statBoostIndexToMonStateIndex(i), delta);
            }
        }

        // Update snapshot in globalKV (reuse cached snapshotKey)
        ENGINE.setGlobalKV(snapshotKey, _packBoostSnapshot(newBoostedStats));
    }

    function _mergeExistingAndNewBoosts(
        uint8[5] memory existingBoostPercents,
        uint8[5] memory existingBoostCounts,
        bool[5] memory existingIsMultiply,
        StatBoostToApply[] memory newBoostsToApply
    )
        internal
        pure
        returns (uint8[5] memory mergedBoostPercents, uint8[5] memory mergedBoostCounts, bool[5] memory mergedIsMultiply)
    {
        mergedBoostPercents = existingBoostPercents;
        mergedBoostCounts = existingBoostCounts;
        mergedIsMultiply = existingIsMultiply;
        for (uint256 i; i < newBoostsToApply.length; i++) {
            uint256 statIndex = _monStateIndexToStatBoostIndex(newBoostsToApply[i].stat);
            if (existingBoostPercents[statIndex] != 0) {
                mergedBoostCounts[statIndex]++;
            } else {
                mergedBoostPercents[statIndex] = newBoostsToApply[i].boostPercent;
                mergedBoostCounts[statIndex] = 1;
                mergedIsMultiply[statIndex] = newBoostsToApply[i].boostType == StatBoostType.Multiply;
            }
        }
        return (mergedBoostPercents, mergedBoostCounts, mergedIsMultiply);
    }

    function _packBoostDataWithArrays(uint168 key, bool isPerm, uint8[5] memory boostPercents, uint8[5] memory boostCounts, bool[5] memory isMultiply)
        internal
        pure
        returns (bytes32)
    {
        uint256 packed = isPerm ? (uint256(1) << PERM_FLAG_OFFSET) : 0;
        packed |= uint256(key) << KEY_OFFSET;

        for (uint256 i = 0; i < 5; i++) {
            uint256 offset = i * 16;
            uint256 boostInstance = (uint256(boostPercents[i]) << 8) | (uint256(boostCounts[i]) << 1) | (isMultiply[i] ? 1 : 0);
            packed |= boostInstance << offset;
        }
        return bytes32(packed);
    }

    function addStatBoosts(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostToApply[] memory statBoostsToApply,
        StatBoostFlag boostFlag
    ) public {
        uint168 key = _generateKeyNoSalt(targetIndex, monIndex, msg.sender);
        _addStatBoostsWithKey(targetIndex, monIndex, statBoostsToApply, boostFlag, key);
    }

    function addKeyedStatBoosts(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostToApply[] memory statBoostsToApply,
        StatBoostFlag boostFlag,
        string memory keyToUse
    ) public {
        uint168 key = _generateKey(targetIndex, monIndex, msg.sender, keyToUse);
        _addStatBoostsWithKey(targetIndex, monIndex, statBoostsToApply, boostFlag, key);
    }

    function _addStatBoostsWithKey(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostToApply[] memory statBoostsToApply,
        StatBoostFlag boostFlag,
        uint168 key
    ) internal {
        bool isPerm = boostFlag == StatBoostFlag.Perm;

        // Single-pass: find existing boost AND aggregate all OTHER boosts
        // We exclude the matching effect from aggregation so we can add the merged/new version
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        (EffectInstance[] memory effects, uint256[] memory indices) = ENGINE.getEffects(battleKey, targetIndex, monIndex);
        uint32[5] memory baseStats = _getMonStatSubset(battleKey, targetIndex, monIndex);

        bool found;
        uint256 foundEffectIndex;
        bytes32 existingData;
        uint32[5] memory numBoostsPerStat;
        uint256[5] memory accumulatedNumeratorPerStat;

        // Single pass: find matching key AND aggregate all OTHER StatBoost effects
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                (bool effIsPerm, uint168 existingKey, uint8[5] memory boostPercents, uint8[5] memory boostCounts, bool[5] memory isMultiply) =
                    _unpackBoostData(effects[i].data);

                // Check if this is the effect we're searching for
                if (existingKey == key && effIsPerm == isPerm) {
                    found = true;
                    foundEffectIndex = indices[i];
                    existingData = effects[i].data;
                    // DON'T add to aggregation - we'll add the merged version later
                    continue;
                }

                // Aggregate this effect's boosts
                _accumulateBoosts(baseStats, boostPercents, boostCounts, isMultiply, numBoostsPerStat, accumulatedNumeratorPerStat);
            }
        }

        // Compute the new/merged boost data and add its contribution to aggregation
        uint8[5] memory finalPercents;
        uint8[5] memory finalCounts;
        bool[5] memory finalIsMultiply;
        bytes32 newData;

        if (found) {
            // Merge with existing boost
            (, , uint8[5] memory existingBoostPercents, uint8[5] memory existingBoostCounts, bool[5] memory existingIsMultiply) =
                _unpackBoostData(existingData);
            (finalPercents, finalCounts, finalIsMultiply) =
                _mergeExistingAndNewBoosts(existingBoostPercents, existingBoostCounts, existingIsMultiply, statBoostsToApply);
            newData = _packBoostDataWithArrays(key, isPerm, finalPercents, finalCounts, finalIsMultiply);
        } else {
            // Pack new boost data and extract its components for aggregation
            newData = _packBoostData(key, isPerm, statBoostsToApply);
            (, , finalPercents, finalCounts, finalIsMultiply) = _unpackBoostData(newData);
        }

        // Add the new/merged boost's contribution to aggregation
        _accumulateBoosts(baseStats, finalPercents, finalCounts, finalIsMultiply, numBoostsPerStat, accumulatedNumeratorPerStat);

        // Update effect storage
        ENGINE.setUpstreamCaller(msg.sender);
        if (found) {
            ENGINE.editEffect(targetIndex, monIndex, foundEffectIndex, newData);
        } else {
            ENGINE.addEffect(targetIndex, monIndex, IEffect(address(this)), newData);
        }

        // Apply stats using already-computed aggregation (no second iteration needed)
        _applyStatsFromAggregatedData(battleKey, targetIndex, monIndex, baseStats, numBoostsPerStat, accumulatedNumeratorPerStat);
    }

    function removeStatBoosts(uint256 targetIndex, uint256 monIndex, StatBoostFlag boostFlag) public {
        uint168 key = _generateKeyNoSalt(targetIndex, monIndex, msg.sender);
        _removeStatBoostsWithKey(targetIndex, monIndex, key, boostFlag);
    }

    function removeKeyedStatBoosts(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostFlag boostFlag,
        string memory stringToUse
    ) public {
        uint168 key = _generateKey(targetIndex, monIndex, msg.sender, stringToUse);
        _removeStatBoostsWithKey(targetIndex, monIndex, key, boostFlag);
    }

    function _removeStatBoostsWithKey(uint256 targetIndex, uint256 monIndex, uint168 key, StatBoostFlag boostFlag) internal {
        bool isPerm = boostFlag == StatBoostFlag.Perm;

        // Single-pass: find existing boost AND aggregate all OTHER boosts (excluding the one to remove)
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        (EffectInstance[] memory effects, uint256[] memory indices) = ENGINE.getEffects(battleKey, targetIndex, monIndex);
        uint32[5] memory baseStats = _getMonStatSubset(battleKey, targetIndex, monIndex);

        bool found;
        uint256 foundEffectIndex;
        uint32[5] memory numBoostsPerStat;
        uint256[5] memory accumulatedNumeratorPerStat;

        // Single pass: find matching key AND aggregate all OTHER StatBoost effects
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                (bool effIsPerm, uint168 existingKey, uint8[5] memory boostPercents, uint8[5] memory boostCounts, bool[5] memory isMultiply) =
                    _unpackBoostData(effects[i].data);

                // Check if this is the effect we're removing
                if (existingKey == key && effIsPerm == isPerm) {
                    found = true;
                    foundEffectIndex = indices[i];
                    // DON'T add to aggregation - we're removing this effect
                    continue;
                }

                // Aggregate this effect's boosts
                _accumulateBoosts(baseStats, boostPercents, boostCounts, isMultiply, numBoostsPerStat, accumulatedNumeratorPerStat);
            }
        }

        if (found) {
            // Remove the effect
            ENGINE.removeEffect(targetIndex, monIndex, foundEffectIndex);
            // Apply stats using already-computed aggregation (no second iteration needed)
            _applyStatsFromAggregatedData(battleKey, targetIndex, monIndex, baseStats, numBoostsPerStat, accumulatedNumeratorPerStat);
        }
    }

    /// @notice Clears all stat boosts for a mon and resets stats to base values
    /// @param targetIndex The player index
    /// @param monIndex The mon index
    function clearAllBoostsForMon(uint256 targetIndex, uint256 monIndex) external {
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        (EffectInstance[] memory effects, uint256[] memory indices) = ENGINE.getEffects(battleKey, targetIndex, monIndex);
        uint32[5] memory baseStats = _getMonStatSubset(battleKey, targetIndex, monIndex);

        // Single pass: collect indices to remove in reverse order
        // We iterate forward but store in reverse to enable proper removal
        uint256 removeCount = 0;
        for (uint256 i = effects.length; i > 0; i--) {
            if (address(effects[i - 1].effect) == address(this)) {
                // Remove immediately while iterating in reverse (avoids index shifting)
                ENGINE.removeEffect(targetIndex, monIndex, indices[i - 1]);
                removeCount++;
            }
        }

        if (removeCount == 0) {
            return;
        }

        // Reset stats to base values by applying with empty aggregation
        uint32[5] memory numBoostsPerStat;
        uint256[5] memory accumulatedNumeratorPerStat;
        _applyStatsFromAggregatedData(battleKey, targetIndex, monIndex, baseStats, numBoostsPerStat, accumulatedNumeratorPerStat);
    }
}
