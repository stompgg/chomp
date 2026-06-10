// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MonStateIndexName, StatBoostType} from "../Enums.sol";
import {StatBoostToApply} from "../Structs.sol";

/**
 * @notice Pure math + packing helpers for the Engine's inlined stat-boost system. This is the
 *         former StatBoosts effect contract's stateless core, lifted into a library so the Engine
 *         can apply boosts natively (no external call round-trips). The packed per-source data
 *         layout and multiplicative aggregation/clamp semantics are identical to the legacy effect.
 *
 *  Per-source packed boost data (bytes32):
 *  [8 bits isPerm | 168 bits key | 80 bits stat data]
 *  stat data = 5 stats × 16 bits: [8 boostPercent | 7 boostCount | 1 isMultiply]
 *
 *  The legacy aggregated globalKV snapshot is gone: the Engine telescopes off the live monState
 *  stat deltas instead (it is the sole writer of those fields), so no separate snapshot is stored.
 */
library StatBoostLib {
    uint256 internal constant DENOM = 100;
    // Per-instance boost count is stored in a 7-bit field. Cap merge increments here so the packed
    // write can't bleed into the boostPercent field above it, and the in-memory uint8 can't revert.
    uint8 internal constant MAX_BOOST_COUNT_PER_INSTANCE = 127;
    // Apply-time clamp on the boosted stat: keeps the int32 cast safe and gives downstream damage
    // math headroom against uint32 overflow.
    uint32 internal constant MAX_BOOSTED_STAT = uint32(type(int32).max);

    uint256 private constant PERM_FLAG_OFFSET = 248; // 256 - 8
    uint256 private constant KEY_OFFSET = 80;
    uint256 private constant KEY_MASK = (1 << 168) - 1;

    function isPerm(bytes32 data) internal pure returns (bool) {
        return uint8(uint256(data) >> PERM_FLAG_OFFSET) != 0;
    }

    // Pack a fresh boost instance from the caller-supplied boosts.
    function packBoostData(uint168 key, bool perm, StatBoostToApply[] memory statBoostsToApply)
        internal
        pure
        returns (bytes32)
    {
        uint256 packed = perm ? (uint256(1) << PERM_FLAG_OFFSET) : 0;
        packed |= uint256(key) << KEY_OFFSET;
        for (uint256 i = 0; i < statBoostsToApply.length; i++) {
            uint256 statIndex = monStateIndexToStatBoostIndex(statBoostsToApply[i].stat);
            uint256 offset = statIndex * 16;
            bool isMul = statBoostsToApply[i].boostType == StatBoostType.Multiply;
            uint256 boostInstance =
                (uint256(statBoostsToApply[i].boostPercent) << 8) | (1 << 1) | (isMul ? 1 : 0);
            packed |= boostInstance << offset;
        }
        return bytes32(packed);
    }

    function unpackBoostHeader(bytes32 data) internal pure returns (bool perm, uint168 key) {
        uint256 packed = uint256(data);
        perm = uint8(packed >> PERM_FLAG_OFFSET) != 0;
        key = uint168((packed >> KEY_OFFSET) & KEY_MASK);
    }

    function unpackBoostData(bytes32 data)
        internal
        pure
        returns (bool perm, uint168 key, uint8[5] memory boostPercents, uint8[5] memory boostCounts, bool[5] memory isMul)
    {
        uint256 packed = uint256(data);
        perm = uint8(packed >> PERM_FLAG_OFFSET) != 0;
        key = uint168((packed >> KEY_OFFSET) & KEY_MASK);
        for (uint256 i = 0; i < 5; i++) {
            uint256 offset = i * 16;
            uint256 boostInstance = (packed >> offset) & 0xFFFF;
            boostPercents[i] = uint8(boostInstance >> 8);
            boostCounts[i] = uint8((boostInstance >> 1) & 0x7F);
            isMul[i] = (boostInstance & 0x1) == 1;
        }
    }

    function packBoostDataWithArrays(
        uint168 key,
        bool perm,
        uint8[5] memory boostPercents,
        uint8[5] memory boostCounts,
        bool[5] memory isMul
    ) internal pure returns (bytes32) {
        uint256 packed = perm ? (uint256(1) << PERM_FLAG_OFFSET) : 0;
        packed |= uint256(key) << KEY_OFFSET;
        for (uint256 i = 0; i < 5; i++) {
            uint256 offset = i * 16;
            uint256 boostInstance =
                (uint256(boostPercents[i]) << 8) | (uint256(boostCounts[i]) << 1) | (isMul[i] ? 1 : 0);
            packed |= boostInstance << offset;
        }
        return bytes32(packed);
    }

    function generateKeyNoSalt(uint256 targetIndex, uint256 monIndex, address caller)
        internal
        pure
        returns (uint168)
    {
        // Layout: [160 bits address | 7 bits monIndex | 1 bit targetIndex]
        return uint168((uint256(uint160(caller)) << 8) | (monIndex << 1) | targetIndex);
    }

    function generateKey(uint256 targetIndex, uint256 monIndex, address caller, string memory salt)
        internal
        pure
        returns (uint168)
    {
        return uint168(uint256(keccak256(abi.encode(targetIndex, monIndex, caller, salt))));
    }

    // Accumulate boost contributions into running totals (modifies arrays in place). Multiplication
    // is unchecked: high stack counts wrap mod 2^256 instead of reverting; the apply step clamps the
    // final boosted stat to int32, so the wrap is observable as a weird stat value but never a revert.
    function accumulateBoosts(
        uint32[5] memory baseStats,
        uint8[5] memory boostPercents,
        uint8[5] memory boostCounts,
        bool[5] memory isMul,
        uint32[5] memory numBoostsPerStat,
        uint256[5] memory accumulatedNumeratorPerStat
    ) internal pure {
        for (uint256 k = 0; k < 5; k++) {
            if (boostCounts[k] == 0) continue;
            _accumulateOne(
                k, boostPercents[k], boostCounts[k], isMul[k], baseStats, numBoostsPerStat, accumulatedNumeratorPerStat
            );
        }
    }

    /// @dev accumulateBoosts for a FRESH source straight from the caller's StatBoostToApply
    ///      entries — skips the pack -> unpack round-trip through the 5-lane arrays that
    ///      _addStatBoostWithKey otherwise pays just to feed the aggregation.
    function accumulateBoostsToApply(
        uint32[5] memory baseStats,
        StatBoostToApply[] memory statBoostsToApply,
        uint32[5] memory numBoostsPerStat,
        uint256[5] memory accumulatedNumeratorPerStat
    ) internal pure {
        for (uint256 i = 0; i < statBoostsToApply.length; i++) {
            _accumulateOne(
                monStateIndexToStatBoostIndex(statBoostsToApply[i].stat),
                statBoostsToApply[i].boostPercent,
                1,
                statBoostsToApply[i].boostType == StatBoostType.Multiply,
                baseStats,
                numBoostsPerStat,
                accumulatedNumeratorPerStat
            );
        }
    }

    /// @dev Shared accumulation core for one stat lane (see accumulateBoosts for the unchecked
    ///      rationale).
    function _accumulateOne(
        uint256 k,
        uint256 boostPercent,
        uint256 boostCount,
        bool isMul,
        uint32[5] memory baseStats,
        uint32[5] memory numBoostsPerStat,
        uint256[5] memory accumulatedNumeratorPerStat
    ) private pure {
        uint256 existingStatValue =
            (accumulatedNumeratorPerStat[k] == 0) ? baseStats[k] : accumulatedNumeratorPerStat[k];
        uint256 scalingFactor = isMul ? DENOM + boostPercent : DENOM - boostPercent;
        unchecked {
            accumulatedNumeratorPerStat[k] = existingStatValue * (scalingFactor ** boostCount);
            numBoostsPerStat[k] += uint32(boostCount);
        }
    }

    function denomPower(uint256 exp) internal pure returns (uint256) {
        if (exp == 0) return 1;
        if (exp == 1) return 100;
        if (exp == 2) return 10000;
        if (exp == 3) return 1000000;
        if (exp == 4) return 100000000;
        if (exp == 5) return 10000000000;
        if (exp == 6) return 1000000000000;
        if (exp == 7) return 100000000000000;
        // Fallback for larger exponents — unchecked so high total stack counts don't revert. 100 =
        // 2^2 * 25, so 100^exp wraps to 0 mod 2^256 once exp >= 128; substitute 1 so the apply-time
        // division can't divide by zero — the resulting raw value is garbage but the clamp contains it.
        unchecked {
            uint256 result = DENOM ** exp;
            return result == 0 ? 1 : result;
        }
    }

    // Compute final boosted stats from aggregated numerators, clamping each to [1, MAX_BOOSTED_STAT].
    // Stats with no boosts fall back to baseStats. Lower bound matters: the snapshot uses 0 as a
    // "no snapshot" sentinel, so a wrapped-to-0 result must store 1 to keep delta telescoping intact.
    function finalizeBoostedStats(
        uint32[5] memory baseStats,
        uint32[5] memory numBoostsPerStat,
        uint256[5] memory accumulatedNumeratorPerStat
    ) internal pure returns (uint32[5] memory newBoostedStats) {
        for (uint256 i = 0; i < 5; i++) {
            if (numBoostsPerStat[i] > 0) {
                uint256 raw = accumulatedNumeratorPerStat[i] / denomPower(numBoostsPerStat[i]);
                if (raw > MAX_BOOSTED_STAT) {
                    newBoostedStats[i] = MAX_BOOSTED_STAT;
                } else if (raw == 0) {
                    newBoostedStats[i] = 1;
                } else {
                    newBoostedStats[i] = uint32(raw);
                }
            } else {
                newBoostedStats[i] = baseStats[i];
            }
        }
    }

    function mergeExistingAndNewBoosts(
        uint8[5] memory existingBoostPercents,
        uint8[5] memory existingBoostCounts,
        bool[5] memory existingIsMul,
        StatBoostToApply[] memory newBoostsToApply
    )
        internal
        pure
        returns (uint8[5] memory mergedBoostPercents, uint8[5] memory mergedBoostCounts, bool[5] memory mergedIsMul)
    {
        mergedBoostPercents = existingBoostPercents;
        mergedBoostCounts = existingBoostCounts;
        mergedIsMul = existingIsMul;
        for (uint256 i; i < newBoostsToApply.length; i++) {
            uint256 statIndex = monStateIndexToStatBoostIndex(newBoostsToApply[i].stat);
            if (existingBoostPercents[statIndex] != 0) {
                if (mergedBoostCounts[statIndex] < MAX_BOOST_COUNT_PER_INSTANCE) {
                    mergedBoostCounts[statIndex]++;
                }
            } else {
                mergedBoostPercents[statIndex] = newBoostsToApply[i].boostPercent;
                mergedBoostCounts[statIndex] = 1;
                mergedIsMul[statIndex] = newBoostsToApply[i].boostType == StatBoostType.Multiply;
            }
        }
    }

    // Attack(3)->0, Defense(4)->1, SpecialAttack(5)->2, SpecialDefense(6)->3, Speed(2)->4.
    // WARNING: assumes MonStateIndexName ordering Hp(0), Stamina(1), Speed(2), Attack(3)...
    function monStateIndexToStatBoostIndex(MonStateIndexName statIndex) internal pure returns (uint256) {
        uint256 idx = uint256(statIndex);
        if (idx == 2) return 4; // Speed
        return idx - 3;
    }

    function statBoostIndexToMonStateIndex(uint256 statBoostIndex) internal pure returns (MonStateIndexName) {
        if (statBoostIndex == 4) return MonStateIndexName.Speed;
        return MonStateIndexName(statBoostIndex + 3);
    }
}
