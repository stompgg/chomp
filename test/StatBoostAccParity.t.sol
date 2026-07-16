// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import {MonStateIndexName, StatBoostType} from "../src/Enums.sol";
import {StatBoostToApply} from "../src/Structs.sol";
import {StatBoostLib} from "../src/lib/StatBoostLib.sol";

/// @notice R1.b parity invariant: the packed accumulator (incremental multiply-in / divide-out)
///         must finalize to EXACTLY the stats the legacy full recompute produces, for any source
///         set that fits the lanes — including after removing an arbitrary source.
contract StatBoostAccParity is Test {
    function _mkWord(uint256 seed, uint168 key) internal pure returns (bytes32) {
        // 1-2 boosted lanes per source, pct 1..100, count 1..2, mixed mul/div — the realistic
        // envelope (prod uses 15-50% single-lane boosts).
        uint256 numLanes = 1 + (seed & 1);
        StatBoostToApply[] memory boosts = new StatBoostToApply[](numLanes);
        for (uint256 i; i < numLanes; ++i) {
            uint256 s = uint256(keccak256(abi.encode(seed, i)));
            boosts[i] = StatBoostToApply({
                // Distinct stat per lane (well-formed input, like prod callers): packBoostData
                // ORs lanes, so a same-stat collision would corrupt the word.
                stat: MonStateIndexName(uint8(2 + ((seed + i) % 5))),
                boostPercent: uint8(1 + (s >> 8) % 100),
                boostType: (s >> 16) & 1 == 0 ? StatBoostType.Multiply : StatBoostType.Divide
            });
        }
        return StatBoostLib.packBoostData(key, seed & 2 == 0, boosts);
    }

    function _referenceStats(bytes32[] memory words, uint256 skipIdx, uint32[5] memory baseStats)
        internal
        pure
        returns (uint32[5] memory)
    {
        uint32[5] memory numBoosts;
        uint256[5] memory accNum;
        for (uint256 i; i < words.length; ++i) {
            if (i == skipIdx) {
                continue;
            }
            (,, uint8[5] memory bp, uint8[5] memory bc, bool[5] memory im) = StatBoostLib.unpackBoostData(words[i]);
            StatBoostLib.accumulateBoosts(baseStats, bp, bc, im, numBoosts, accNum);
        }
        return StatBoostLib.finalizeBoostedStats(baseStats, numBoosts, accNum);
    }

    function test_repro() public pure {
        _run(3, 12, 41968);
    }

    function testFuzz_accMatchesRecompute(uint256 seed, uint8 numSourcesRaw, uint16 baseRaw) public pure {
        _run(seed, numSourcesRaw, baseRaw);
    }

    function _run(uint256 seed, uint8 numSourcesRaw, uint16 baseRaw) internal pure {
        uint256 numSources = 1 + (numSourcesRaw % 5);
        uint32 base = 1 + uint32(baseRaw) % 1000;
        uint32[5] memory baseStats = [base, base + 7, base + 13, base + 29, base + 51];

        bytes32[] memory words = new bytes32[](numSources);
        uint256 acc;
        bool allOk = true;
        for (uint256 i; i < numSources; ++i) {
            words[i] = _mkWord(uint256(keccak256(abi.encode(seed, "w", i))), uint168(uint160(i + 1)));
            bool ok;
            (acc, ok) = StatBoostLib.applyWordToAcc(acc, words[i], baseStats, true);
            allOk = allOk && ok;
        }
        // Realistic envelopes always fit; if a pathological draw overflowed, the Engine would
        // have disabled + recomputed (parity by construction) — nothing to compare here.
        vm.assume(allOk);

        uint32[5] memory fast = StatBoostLib.finalizeAccStats(acc, baseStats);
        uint32[5] memory ref = _referenceStats(words, type(uint256).max, baseStats);
        for (uint256 k; k < 5; ++k) {
            assertEq(fast[k], ref[k], "add parity");
        }

        // Divide an arbitrary source back out: must equal recompute-without-it. The one designed
        // refusal is a factor-0 lane (100% Divide) — the Engine disables the accumulator there
        // and recomputes from sources, which IS the reference; nothing to compare.
        uint256 removeIdx = uint256(keccak256(abi.encode(seed, "r"))) % numSources;
        (uint256 acc2, bool ok2) = StatBoostLib.applyWordToAcc(acc, words[removeIdx], baseStats, false);
        if (!ok2) {
            return;
        }
        uint32[5] memory fast2 = StatBoostLib.finalizeAccStats(acc2, baseStats);
        uint32[5] memory ref2 = _referenceStats(words, removeIdx, baseStats);
        for (uint256 k; k < 5; ++k) {
            assertEq(fast2[k], ref2[k], "remove parity");
        }
    }
}
