// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {FastCommitManagerTestBase} from "./FastCommitManager.t.sol";
import "../src/Constants.sol";

/// @title Gas Benchmark Tests for FastCommitManager
/// @notice Compares gas usage between normal and fast commit flows
/// @dev Tests both cold (first access) and warm (subsequent access) storage patterns
contract FastCommitManagerGasBenchmarkTest is FastCommitManagerTestBase {

    // Gas tracking
    uint256 gasUsed_normalFlow_cold_commit;
    uint256 gasUsed_normalFlow_cold_reveal1;
    uint256 gasUsed_normalFlow_cold_reveal2;
    uint256 gasUsed_fastFlow_cold_signedCommitReveal;
    uint256 gasUsed_fastFlow_cold_reveal;

    uint256 gasUsed_normalFlow_warm_commit;
    uint256 gasUsed_normalFlow_warm_reveal1;
    uint256 gasUsed_normalFlow_warm_reveal2;
    uint256 gasUsed_fastFlow_warm_signedCommitReveal;
    uint256 gasUsed_fastFlow_warm_reveal;

    /// @notice Benchmark: Normal flow - COLD storage access (Turn 0)
    function test_gasBenchmark_normalFlow_cold() public {
        bytes32 battleKey = _startBattleWith(address(fastCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

        vm.startPrank(p0);
        uint256 gasBefore = gasleft();
        fastCommitManager.commitMove(battleKey, p0MoveHash);
        gasUsed_normalFlow_cold_commit = gasBefore - gasleft();

        vm.startPrank(p1);
        gasBefore = gasleft();
        fastCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, bytes32(0), 0, false);
        gasUsed_normalFlow_cold_reveal1 = gasBefore - gasleft();

        vm.startPrank(p0);
        gasBefore = gasleft();
        fastCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, bytes32(uint256(1)), 0, true);
        gasUsed_normalFlow_cold_reveal2 = gasBefore - gasleft();

        emit log_named_uint("Normal Flow (Cold) - Commit", gasUsed_normalFlow_cold_commit);
        emit log_named_uint("Normal Flow (Cold) - Reveal 1 (Bob)", gasUsed_normalFlow_cold_reveal1);
        emit log_named_uint("Normal Flow (Cold) - Reveal 2 (Alice)", gasUsed_normalFlow_cold_reveal2);
        emit log_named_uint("Normal Flow (Cold) - TOTAL",
            gasUsed_normalFlow_cold_commit + gasUsed_normalFlow_cold_reveal1 + gasUsed_normalFlow_cold_reveal2);
    }

    /// @notice Benchmark: Fast flow - COLD storage access (Turn 0)
    function test_gasBenchmark_fastFlow_cold() public {
        bytes32 battleKey = _startBattleWith(address(fastCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory p0Signature = _signCommit(P0_PK, p0MoveHash, battleKey, 0);

        vm.startPrank(p1);
        uint256 gasBefore = gasleft();
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, p0MoveHash, p0Signature, SWITCH_MOVE_INDEX, bytes32(0), 0, false
        );
        gasUsed_fastFlow_cold_signedCommitReveal = gasBefore - gasleft();

        vm.startPrank(p0);
        gasBefore = gasleft();
        fastCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, bytes32(uint256(1)), 0, true);
        gasUsed_fastFlow_cold_reveal = gasBefore - gasleft();

        emit log_named_uint("Fast Flow (Cold) - SignedCommit+Reveal", gasUsed_fastFlow_cold_signedCommitReveal);
        emit log_named_uint("Fast Flow (Cold) - Reveal (Alice)", gasUsed_fastFlow_cold_reveal);
        emit log_named_uint("Fast Flow (Cold) - TOTAL",
            gasUsed_fastFlow_cold_signedCommitReveal + gasUsed_fastFlow_cold_reveal);
    }

    /// @notice Benchmark: Normal flow - WARM storage access (Turn 2+)
    function test_gasBenchmark_normalFlow_warm() public {
        bytes32 battleKey = _startBattleWith(address(fastCommitManager));

        _completeTurnNormal(battleKey, 0);
        _completeTurnNormal(battleKey, 1);

        // Turn 2 (warm storage - p0 commits again)
        bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(100)), uint240(0)));

        vm.startPrank(p0);
        uint256 gasBefore = gasleft();
        fastCommitManager.commitMove(battleKey, p0MoveHash);
        gasUsed_normalFlow_warm_commit = gasBefore - gasleft();

        vm.startPrank(p1);
        gasBefore = gasleft();
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(0), 0, false);
        gasUsed_normalFlow_warm_reveal1 = gasBefore - gasleft();

        vm.startPrank(p0);
        gasBefore = gasleft();
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(100)), 0, true);
        gasUsed_normalFlow_warm_reveal2 = gasBefore - gasleft();

        emit log_named_uint("Normal Flow (Warm) - Commit", gasUsed_normalFlow_warm_commit);
        emit log_named_uint("Normal Flow (Warm) - Reveal 1 (Bob)", gasUsed_normalFlow_warm_reveal1);
        emit log_named_uint("Normal Flow (Warm) - Reveal 2 (Alice)", gasUsed_normalFlow_warm_reveal2);
        emit log_named_uint("Normal Flow (Warm) - TOTAL",
            gasUsed_normalFlow_warm_commit + gasUsed_normalFlow_warm_reveal1 + gasUsed_normalFlow_warm_reveal2);
    }

    /// @notice Benchmark: Fast flow - WARM storage access (Turn 2+)
    function test_gasBenchmark_fastFlow_warm() public {
        bytes32 battleKey = _startBattleWith(address(fastCommitManager));

        _completeTurnNormal(battleKey, 0);
        _completeTurnNormal(battleKey, 1);

        // Turn 2 with fast flow (warm storage)
        bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(100)), uint240(0)));
        bytes memory p0Signature = _signCommit(P0_PK, p0MoveHash, battleKey, 2);

        vm.startPrank(p1);
        uint256 gasBefore = gasleft();
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, p0MoveHash, p0Signature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
        gasUsed_fastFlow_warm_signedCommitReveal = gasBefore - gasleft();

        vm.startPrank(p0);
        gasBefore = gasleft();
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(100)), 0, true);
        gasUsed_fastFlow_warm_reveal = gasBefore - gasleft();

        emit log_named_uint("Fast Flow (Warm) - SignedCommit+Reveal", gasUsed_fastFlow_warm_signedCommitReveal);
        emit log_named_uint("Fast Flow (Warm) - Reveal (Alice)", gasUsed_fastFlow_warm_reveal);
        emit log_named_uint("Fast Flow (Warm) - TOTAL",
            gasUsed_fastFlow_warm_signedCommitReveal + gasUsed_fastFlow_warm_reveal);
    }

    /// @notice Combined benchmark comparison
    function test_gasBenchmark_comparison() public {
        bytes32 battleKey1 = _startBattleWith(address(fastCommitManager));
        bytes32 battleKey2 = _startBattleWith(address(fastCommitManager));

        // === COLD BENCHMARKS ===

        // Normal flow cold
        {
            bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

            vm.startPrank(p0);
            uint256 gasBefore = gasleft();
            fastCommitManager.commitMove(battleKey1, p0MoveHash);
            gasUsed_normalFlow_cold_commit = gasBefore - gasleft();

            vm.startPrank(p1);
            gasBefore = gasleft();
            fastCommitManager.revealMove(battleKey1, SWITCH_MOVE_INDEX, bytes32(0), 0, false);
            gasUsed_normalFlow_cold_reveal1 = gasBefore - gasleft();

            vm.startPrank(p0);
            gasBefore = gasleft();
            fastCommitManager.revealMove(battleKey1, SWITCH_MOVE_INDEX, bytes32(uint256(1)), 0, true);
            gasUsed_normalFlow_cold_reveal2 = gasBefore - gasleft();
        }

        // Fast flow cold
        {
            bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
            bytes memory p0Signature = _signCommit(P0_PK, p0MoveHash, battleKey2, 0);

            vm.startPrank(p1);
            uint256 gasBefore = gasleft();
            fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
                battleKey2, p0MoveHash, p0Signature, SWITCH_MOVE_INDEX, bytes32(0), 0, false
            );
            gasUsed_fastFlow_cold_signedCommitReveal = gasBefore - gasleft();

            vm.startPrank(p0);
            gasBefore = gasleft();
            fastCommitManager.revealMove(battleKey2, SWITCH_MOVE_INDEX, bytes32(uint256(1)), 0, true);
            gasUsed_fastFlow_cold_reveal = gasBefore - gasleft();
        }

        // === WARM BENCHMARKS ===

        // Complete turn 1 for both battles
        _completeTurnNormal(battleKey1, 1);
        _completeTurnFast(battleKey2, 1);

        // Normal flow warm (turn 2)
        {
            bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(100)), uint240(0)));

            vm.startPrank(p0);
            uint256 gasBefore = gasleft();
            fastCommitManager.commitMove(battleKey1, p0MoveHash);
            gasUsed_normalFlow_warm_commit = gasBefore - gasleft();

            vm.startPrank(p1);
            gasBefore = gasleft();
            fastCommitManager.revealMove(battleKey1, NO_OP_MOVE_INDEX, bytes32(0), 0, false);
            gasUsed_normalFlow_warm_reveal1 = gasBefore - gasleft();

            vm.startPrank(p0);
            gasBefore = gasleft();
            fastCommitManager.revealMove(battleKey1, NO_OP_MOVE_INDEX, bytes32(uint256(100)), 0, true);
            gasUsed_normalFlow_warm_reveal2 = gasBefore - gasleft();
        }

        // Fast flow warm (turn 2)
        {
            bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(100)), uint240(0)));
            bytes memory p0Signature = _signCommit(P0_PK, p0MoveHash, battleKey2, 2);

            vm.startPrank(p1);
            uint256 gasBefore = gasleft();
            fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
                battleKey2, p0MoveHash, p0Signature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
            );
            gasUsed_fastFlow_warm_signedCommitReveal = gasBefore - gasleft();

            vm.startPrank(p0);
            gasBefore = gasleft();
            fastCommitManager.revealMove(battleKey2, NO_OP_MOVE_INDEX, bytes32(uint256(100)), 0, true);
            gasUsed_fastFlow_warm_reveal = gasBefore - gasleft();
        }

        // === OUTPUT COMPARISON ===
        emit log("========================================");
        emit log("GAS BENCHMARK COMPARISON");
        emit log("========================================");

        emit log("");
        emit log("--- COLD STORAGE ACCESS (Turn 0) ---");
        uint256 normalColdTotal = gasUsed_normalFlow_cold_commit + gasUsed_normalFlow_cold_reveal1 + gasUsed_normalFlow_cold_reveal2;
        uint256 fastColdTotal = gasUsed_fastFlow_cold_signedCommitReveal + gasUsed_fastFlow_cold_reveal;

        emit log_named_uint("Normal Flow - Commit (Alice)", gasUsed_normalFlow_cold_commit);
        emit log_named_uint("Normal Flow - Reveal (Bob)", gasUsed_normalFlow_cold_reveal1);
        emit log_named_uint("Normal Flow - Reveal (Alice)", gasUsed_normalFlow_cold_reveal2);
        emit log_named_uint("Normal Flow - TOTAL", normalColdTotal);
        emit log("");
        emit log_named_uint("Fast Flow - SignedCommit+Reveal (Bob)", gasUsed_fastFlow_cold_signedCommitReveal);
        emit log_named_uint("Fast Flow - Reveal (Alice)", gasUsed_fastFlow_cold_reveal);
        emit log_named_uint("Fast Flow - TOTAL", fastColdTotal);
        emit log("");

        if (fastColdTotal < normalColdTotal) {
            emit log_named_uint("Fast Flow SAVES (cold)", normalColdTotal - fastColdTotal);
        } else {
            emit log_named_uint("Fast Flow COSTS MORE (cold)", fastColdTotal - normalColdTotal);
        }

        emit log("");
        emit log("--- WARM STORAGE ACCESS (Turn 2+) ---");
        uint256 normalWarmTotal = gasUsed_normalFlow_warm_commit + gasUsed_normalFlow_warm_reveal1 + gasUsed_normalFlow_warm_reveal2;
        uint256 fastWarmTotal = gasUsed_fastFlow_warm_signedCommitReveal + gasUsed_fastFlow_warm_reveal;

        emit log_named_uint("Normal Flow - Commit (Alice)", gasUsed_normalFlow_warm_commit);
        emit log_named_uint("Normal Flow - Reveal (Bob)", gasUsed_normalFlow_warm_reveal1);
        emit log_named_uint("Normal Flow - Reveal (Alice)", gasUsed_normalFlow_warm_reveal2);
        emit log_named_uint("Normal Flow - TOTAL", normalWarmTotal);
        emit log("");
        emit log_named_uint("Fast Flow - SignedCommit+Reveal (Bob)", gasUsed_fastFlow_warm_signedCommitReveal);
        emit log_named_uint("Fast Flow - Reveal (Alice)", gasUsed_fastFlow_warm_reveal);
        emit log_named_uint("Fast Flow - TOTAL", fastWarmTotal);
        emit log("");

        if (fastWarmTotal < normalWarmTotal) {
            emit log_named_uint("Fast Flow SAVES (warm)", normalWarmTotal - fastWarmTotal);
        } else {
            emit log_named_uint("Fast Flow COSTS MORE (warm)", fastWarmTotal - normalWarmTotal);
        }

        emit log("");
        emit log("--- TRANSACTION COUNT ---");
        emit log("Normal Flow: 3 transactions (commit, reveal, reveal)");
        emit log("Fast Flow: 2 transactions (signedCommit+reveal, reveal)");
        emit log("========================================");
    }
}
