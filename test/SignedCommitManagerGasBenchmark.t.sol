// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {SignedCommitManagerTestBase} from "./SignedCommitManager.t.sol";
import "../src/Constants.sol";

/// @title Gas Benchmark Tests for SignedCommitManager
/// @notice Compares gas usage between normal flow (3 TXs) and dual-signed flow (1 TX)
/// @dev Tests both cold (first access) and warm (subsequent access) storage patterns
contract SignedCommitManagerGasBenchmarkTest is SignedCommitManagerTestBase {

    // Gas tracking - Normal flow (3 TXs)
    uint256 gasUsed_normalFlow_cold_commit;
    uint256 gasUsed_normalFlow_cold_reveal1;
    uint256 gasUsed_normalFlow_cold_reveal2;

    uint256 gasUsed_normalFlow_warm_commit;
    uint256 gasUsed_normalFlow_warm_reveal1;
    uint256 gasUsed_normalFlow_warm_reveal2;

    // Gas tracking - Dual-signed flow (1 TX)
    uint256 gasUsed_dualSignedFlow_cold;
    uint256 gasUsed_dualSignedFlow_warm;

    /// @notice Benchmark: Normal flow - COLD storage access (Turn 0)
    function test_gasBenchmark_normalFlow_cold() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

        vm.startPrank(p0);
        uint256 gasBefore = gasleft();
        signedCommitManager.commitMove(battleKey, p0MoveHash);
        gasUsed_normalFlow_cold_commit = gasBefore - gasleft();

        vm.startPrank(p1);
        gasBefore = gasleft();
        signedCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, bytes32(0), 0, false);
        gasUsed_normalFlow_cold_reveal1 = gasBefore - gasleft();

        vm.startPrank(p0);
        gasBefore = gasleft();
        signedCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, bytes32(uint256(1)), 0, true);
        gasUsed_normalFlow_cold_reveal2 = gasBefore - gasleft();

        emit log_named_uint("Normal Flow (Cold) - Commit (Alice)", gasUsed_normalFlow_cold_commit);
        emit log_named_uint("Normal Flow (Cold) - Reveal (Bob)", gasUsed_normalFlow_cold_reveal1);
        emit log_named_uint("Normal Flow (Cold) - Reveal+Execute (Alice)", gasUsed_normalFlow_cold_reveal2);
        emit log_named_uint("Normal Flow (Cold) - TOTAL",
            gasUsed_normalFlow_cold_commit + gasUsed_normalFlow_cold_reveal1 + gasUsed_normalFlow_cold_reveal2);
    }

    /// @notice Benchmark: Dual-signed flow - COLD storage access (Turn 0)
    function test_gasBenchmark_dualSignedFlow_cold() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Prepare move data
        bytes32 p0Salt = bytes32(uint256(1));
        bytes32 p1Salt = bytes32(uint256(2));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint240(0)));

        // p1 (revealer) signs their move + p0's hash
        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, p1Salt, 0
        );

        // p0 (committer) submits everything in 1 TX
        vm.startPrank(p0);
        uint256 gasBefore = gasleft();
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            p1Salt,
            0,
            p1Signature
        );
        gasUsed_dualSignedFlow_cold = gasBefore - gasleft();

        emit log_named_uint("Dual-Signed Flow (Cold) - Execute (1 TX)", gasUsed_dualSignedFlow_cold);
    }

    /// @notice Benchmark: Normal flow - WARM storage access (Turn 2+)
    function test_gasBenchmark_normalFlow_warm() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        _completeTurnNormal(battleKey, 0);
        _completeTurnNormal(battleKey, 1);

        // Turn 2 (warm storage - p0 commits again)
        bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(100)), uint240(0)));

        vm.startPrank(p0);
        uint256 gasBefore = gasleft();
        signedCommitManager.commitMove(battleKey, p0MoveHash);
        gasUsed_normalFlow_warm_commit = gasBefore - gasleft();

        vm.startPrank(p1);
        gasBefore = gasleft();
        signedCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(0), 0, false);
        gasUsed_normalFlow_warm_reveal1 = gasBefore - gasleft();

        vm.startPrank(p0);
        gasBefore = gasleft();
        signedCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(100)), 0, true);
        gasUsed_normalFlow_warm_reveal2 = gasBefore - gasleft();

        emit log_named_uint("Normal Flow (Warm) - Commit (Alice)", gasUsed_normalFlow_warm_commit);
        emit log_named_uint("Normal Flow (Warm) - Reveal (Bob)", gasUsed_normalFlow_warm_reveal1);
        emit log_named_uint("Normal Flow (Warm) - Reveal+Execute (Alice)", gasUsed_normalFlow_warm_reveal2);
        emit log_named_uint("Normal Flow (Warm) - TOTAL",
            gasUsed_normalFlow_warm_commit + gasUsed_normalFlow_warm_reveal1 + gasUsed_normalFlow_warm_reveal2);
    }

    /// @notice Benchmark: Dual-signed flow - WARM storage access (Turn 2+)
    function test_gasBenchmark_dualSignedFlow_warm() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        _completeTurnNormal(battleKey, 0);
        _completeTurnNormal(battleKey, 1);

        // Turn 2 with dual-signed flow (warm storage)
        bytes32 p0Salt = bytes32(uint256(100));
        bytes32 p1Salt = bytes32(uint256(101));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p0Salt, uint240(0)));

        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 2, p0MoveHash, NO_OP_MOVE_INDEX, p1Salt, 0
        );

        vm.startPrank(p0);
        uint256 gasBefore = gasleft();
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            NO_OP_MOVE_INDEX,
            p0Salt,
            0,
            NO_OP_MOVE_INDEX,
            p1Salt,
            0,
            p1Signature
        );
        gasUsed_dualSignedFlow_warm = gasBefore - gasleft();

        emit log_named_uint("Dual-Signed Flow (Warm) - Execute (1 TX)", gasUsed_dualSignedFlow_warm);
    }

    /// @notice Combined benchmark comparison
    function test_gasBenchmark_comparison() public {
        bytes32 battleKey1 = _startBattleWith(address(signedCommitManager));
        bytes32 battleKey2 = _startBattleWith(address(signedCommitManager));

        // === COLD BENCHMARKS ===

        // Normal flow cold (3 TXs)
        {
            bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

            vm.startPrank(p0);
            uint256 gasBefore = gasleft();
            signedCommitManager.commitMove(battleKey1, p0MoveHash);
            gasUsed_normalFlow_cold_commit = gasBefore - gasleft();

            vm.startPrank(p1);
            gasBefore = gasleft();
            signedCommitManager.revealMove(battleKey1, SWITCH_MOVE_INDEX, bytes32(0), 0, false);
            gasUsed_normalFlow_cold_reveal1 = gasBefore - gasleft();

            vm.startPrank(p0);
            gasBefore = gasleft();
            signedCommitManager.revealMove(battleKey1, SWITCH_MOVE_INDEX, bytes32(uint256(1)), 0, true);
            gasUsed_normalFlow_cold_reveal2 = gasBefore - gasleft();
        }

        // Dual-signed flow cold (1 TX)
        {
            bytes32 p0Salt = bytes32(uint256(1));
            bytes32 p1Salt = bytes32(uint256(2));
            bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint240(0)));

            bytes memory p1Signature = _signDualReveal(
                P1_PK, battleKey2, 0, p0MoveHash, SWITCH_MOVE_INDEX, p1Salt, 0
            );

            vm.startPrank(p0);
            uint256 gasBefore = gasleft();
            signedCommitManager.executeWithDualSignedMoves(
                battleKey2,
                SWITCH_MOVE_INDEX,
                p0Salt,
                0,
                SWITCH_MOVE_INDEX,
                p1Salt,
                0,
                p1Signature
            );
            gasUsed_dualSignedFlow_cold = gasBefore - gasleft();
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
            signedCommitManager.commitMove(battleKey1, p0MoveHash);
            gasUsed_normalFlow_warm_commit = gasBefore - gasleft();

            vm.startPrank(p1);
            gasBefore = gasleft();
            signedCommitManager.revealMove(battleKey1, NO_OP_MOVE_INDEX, bytes32(0), 0, false);
            gasUsed_normalFlow_warm_reveal1 = gasBefore - gasleft();

            vm.startPrank(p0);
            gasBefore = gasleft();
            signedCommitManager.revealMove(battleKey1, NO_OP_MOVE_INDEX, bytes32(uint256(100)), 0, true);
            gasUsed_normalFlow_warm_reveal2 = gasBefore - gasleft();
        }

        // Dual-signed flow warm (turn 2)
        {
            bytes32 p0Salt = bytes32(uint256(100));
            bytes32 p1Salt = bytes32(uint256(101));
            bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p0Salt, uint240(0)));

            bytes memory p1Signature = _signDualReveal(
                P1_PK, battleKey2, 2, p0MoveHash, NO_OP_MOVE_INDEX, p1Salt, 0
            );

            vm.startPrank(p0);
            uint256 gasBefore = gasleft();
            signedCommitManager.executeWithDualSignedMoves(
                battleKey2,
                NO_OP_MOVE_INDEX,
                p0Salt,
                0,
                NO_OP_MOVE_INDEX,
                p1Salt,
                0,
                p1Signature
            );
            gasUsed_dualSignedFlow_warm = gasBefore - gasleft();
        }

        // === OUTPUT COMPARISON ===
        emit log("========================================");
        emit log("GAS BENCHMARK COMPARISON");
        emit log("========================================");

        emit log("");
        emit log("--- COLD STORAGE ACCESS (Turn 0) ---");
        uint256 normalColdTotal = gasUsed_normalFlow_cold_commit + gasUsed_normalFlow_cold_reveal1 + gasUsed_normalFlow_cold_reveal2;

        emit log_named_uint("Normal Flow - Commit (Alice)", gasUsed_normalFlow_cold_commit);
        emit log_named_uint("Normal Flow - Reveal (Bob)", gasUsed_normalFlow_cold_reveal1);
        emit log_named_uint("Normal Flow - Reveal+Execute (Alice)", gasUsed_normalFlow_cold_reveal2);
        emit log_named_uint("Normal Flow - TOTAL (3 TXs)", normalColdTotal);
        emit log("");
        emit log_named_uint("Dual-Signed Flow - Execute (1 TX)", gasUsed_dualSignedFlow_cold);
        emit log("");

        if (gasUsed_dualSignedFlow_cold < normalColdTotal) {
            emit log_named_uint("Dual-Signed Flow SAVES (cold)", normalColdTotal - gasUsed_dualSignedFlow_cold);
        } else {
            emit log_named_uint("Dual-Signed Flow COSTS MORE (cold)", gasUsed_dualSignedFlow_cold - normalColdTotal);
        }

        emit log("");
        emit log("--- WARM STORAGE ACCESS (Turn 2+) ---");
        uint256 normalWarmTotal = gasUsed_normalFlow_warm_commit + gasUsed_normalFlow_warm_reveal1 + gasUsed_normalFlow_warm_reveal2;

        emit log_named_uint("Normal Flow - Commit (Alice)", gasUsed_normalFlow_warm_commit);
        emit log_named_uint("Normal Flow - Reveal (Bob)", gasUsed_normalFlow_warm_reveal1);
        emit log_named_uint("Normal Flow - Reveal+Execute (Alice)", gasUsed_normalFlow_warm_reveal2);
        emit log_named_uint("Normal Flow - TOTAL (3 TXs)", normalWarmTotal);
        emit log("");
        emit log_named_uint("Dual-Signed Flow - Execute (1 TX)", gasUsed_dualSignedFlow_warm);
        emit log("");

        if (gasUsed_dualSignedFlow_warm < normalWarmTotal) {
            emit log_named_uint("Dual-Signed Flow SAVES (warm)", normalWarmTotal - gasUsed_dualSignedFlow_warm);
        } else {
            emit log_named_uint("Dual-Signed Flow COSTS MORE (warm)", gasUsed_dualSignedFlow_warm - normalWarmTotal);
        }

        emit log("");
        emit log("--- TRANSACTION COUNT ---");
        emit log("Normal Flow:       3 transactions (commit, reveal, reveal+execute)");
        emit log("Dual-Signed Flow:  1 transaction  (execute with both signatures)");
        emit log("");
        emit log("--- ADDITIONAL SAVINGS (not measured above) ---");
        emit log("Dual-Signed Flow saves 2 TX base costs (~42,000 gas)");
        emit log("========================================");
    }
}
