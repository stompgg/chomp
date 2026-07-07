// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {SignedCommitManagerTestBase} from "./SignedCommitManager.t.sol";
import {BatchHelper} from "./abstract/BatchHelper.sol";

/// @notice Adversarial + functional tests for the Engine's BUILT-IN dual-signed buffer flow
///         (BUILTIN_DUAL_SIGNED_MANAGER battles): submitTurnMoves / executeBuffered live in the
///         Engine, no external SignedCommitManager. Reuses SignedCommitManagerTestBase's setup
///         (engine + validator + matchmaker + 2-mon teams) and BatchHelper's Engine-domain signing.
contract EngineBuiltInBufferTest is SignedCommitManagerTestBase, BatchHelper {
    function _startBuiltIn() internal returns (bytes32 battleKey) {
        battleKey = _startBattleWith(BUILTIN_DUAL_SIGNED_MANAGER);
        vm.stopPrank(); // _startBattleWith leaves an active prank on p0
    }

    /// @dev Build the Engine-domain submit args and call submitTurnMoves (or the combined variant)
    ///      as the parity-correct committer.
    function _submit(
        bytes32 battleKey,
        uint64 turnId,
        uint8 p0m,
        uint16 p0e,
        uint104 p0s,
        uint8 p1m,
        uint16 p1e,
        uint104 p1s,
        bool combined
    ) internal {
        (uint256 packedMoves, bytes32 r, bytes32 vs) = _buildTurnSubmissionForEngine(
            address(engine), battleKey, turnId, p0m, p0e, p0s, p1m, p1e, p1s, P0_PK, P1_PK
        );
        vm.prank(turnId % 2 == 0 ? p0 : p1);
        if (combined) {
            engine.submitTurnMovesAndExecute(battleKey, packedMoves, r, vs);
        } else {
            engine.submitTurnMoves(battleKey, packedMoves, r, vs);
        }
        engine.resetCallContext();
    }

    function _endBattle(bytes32 battleKey) internal {
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        engine.end(battleKey);
        engine.resetCallContext();
    }

    // ----------------------------- functional -----------------------------

    function test_builtIn_happyPath_bufferThenDrain() public {
        bytes32 battleKey = _startBuiltIn();
        // Turn 0: both switch in mon 0 (buffer only).
        _submit(battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, false);
        (uint64 numExecuted, uint256[] memory turns) = engine.getBufferedTurns(battleKey);
        assertEq(numExecuted, 0, "no turn executed yet");
        assertEq(turns.length, 1, "one turn buffered");
        assertEq(engine.getTurnIdForBattleState(battleKey), 0, "engine turnId unchanged while buffered");

        // Turn 1: both attack with move 0; combined submit drains the whole buffer.
        _submit(battleKey, 1, 0, 0, 3, 0, 0, 4, true);
        (numExecuted, turns) = engine.getBufferedTurns(battleKey);
        assertEq(turns.length, 0, "buffer drained");
        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "both turns executed");
    }

    function test_builtIn_executeBuffered_drainsAccumulated() public {
        bytes32 battleKey = _startBuiltIn();
        _submit(battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, false);
        _submit(battleKey, 1, 0, 0, 3, 0, 0, 4, false);
        // Permissionless drain by a third party.
        vm.prank(address(0xCAFE));
        engine.executeBuffered(battleKey);
        engine.resetCallContext();
        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "both buffered turns executed");
    }

    // ------------------------------ safety --------------------------------

    function test_builtIn_revert_submitOnExternalManagerBattle() public {
        // Battle wired to the real external manager, NOT the sentinel.
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));
        vm.stopPrank();
        (uint256 packedMoves, bytes32 r, bytes32 vs) = _buildTurnSubmissionForEngine(
            address(engine), battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, P0_PK, P1_PK
        );
        vm.prank(p0);
        vm.expectRevert(Engine.NotBuiltInManager.selector);
        engine.submitTurnMoves(battleKey, packedMoves, r, vs);
    }

    function test_builtIn_revert_skipAheadImpossible() public {
        bytes32 battleKey = _startBuiltIn();
        // turnId is derived on-chain (always the next undrained turn = 0 here), not caller-chosen, so a
        // would-be "skip ahead to turn 1" submission is just processed as turn 0: p1 signed/built for turn
        // 1 (revealer parity) but turn 0's committer is p0, so p1 submitting is rejected as NotCommitter.
        (uint256 packedMoves, bytes32 r, bytes32 vs) =
            _buildTurnSubmissionForEngine(address(engine), battleKey, 1, 0, 0, 3, 0, 0, 4, P0_PK, P1_PK);
        vm.prank(p1);
        vm.expectRevert(Engine.NotCommitter.selector);
        engine.submitTurnMoves(battleKey, packedMoves, r, vs);
    }

    function test_builtIn_revert_cannotReaddressBufferedTurn() public {
        bytes32 battleKey = _startBuiltIn();
        _submit(battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, false);
        // Turn 0 is buffered, so the derived next id is now 1 (committer p1). The turn-0 committer p0
        // can't re-address/overwrite turn 0 (turnId is derived, not caller-chosen) → NotCommitter.
        (uint256 packedMoves, bytes32 r, bytes32 vs) = _buildTurnSubmissionForEngine(
            address(engine), battleKey, 0, SWITCH_MOVE_INDEX, 0, 9, SWITCH_MOVE_INDEX, 0, 9, P0_PK, P1_PK
        );
        vm.prank(p0);
        vm.expectRevert(Engine.NotCommitter.selector);
        engine.submitTurnMoves(battleKey, packedMoves, r, vs);
    }

    function test_builtIn_revert_notCommitter() public {
        bytes32 battleKey = _startBuiltIn();
        // Turn 0 committer is p0; p1 (the revealer) cannot submit.
        (uint256 packedMoves, bytes32 r, bytes32 vs) = _buildTurnSubmissionForEngine(
            address(engine), battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, P0_PK, P1_PK
        );
        vm.prank(p1);
        vm.expectRevert(Engine.NotCommitter.selector);
        engine.submitTurnMoves(battleKey, packedMoves, r, vs);
    }

    function test_builtIn_revert_forgedRevealerSignature() public {
        bytes32 battleKey = _startBuiltIn();
        // Committer p0 builds a valid entry, then we corrupt the revealer signature.
        (uint256 packedMoves, bytes32 r, bytes32 vs) = _buildTurnSubmissionForEngine(
            address(engine), battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, P0_PK, P1_PK
        );
        vs ^= bytes32(uint256(1) << 8); // corrupt the compact signature
        vm.prank(p0);
        vm.expectRevert();
        engine.submitTurnMoves(battleKey, packedMoves, r, vs);
    }

    function test_builtIn_revert_managerDomainSignatureRejected() public {
        bytes32 battleKey = _startBuiltIn();
        // A revealer signature for the EXTERNAL manager domain must NOT validate against the Engine.
        (uint256 packedMoves, bytes32 r, bytes32 vs) = _buildTurnSubmission(
            address(signedCommitManager), battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, P0_PK, P1_PK
        );
        vm.prank(p0);
        vm.expectRevert(Engine.InvalidSignature.selector);
        engine.submitTurnMoves(battleKey, packedMoves, r, vs);
    }

    function test_builtIn_revert_submitAfterComplete() public {
        bytes32 battleKey = _startBuiltIn();
        _endBattle(battleKey); // force-end after MAX_BATTLE_DURATION
        (uint256 packedMoves, bytes32 r, bytes32 vs) = _buildTurnSubmissionForEngine(
            address(engine), battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, P0_PK, P1_PK
        );
        vm.prank(p0);
        vm.expectRevert(Engine.GameAlreadyOver.selector);
        engine.submitTurnMoves(battleKey, packedMoves, r, vs);
    }

    function test_builtIn_revert_emptyBufferDrain() public {
        bytes32 battleKey = _startBuiltIn();
        vm.expectRevert(Engine.EmptyBuffer.selector);
        engine.executeBuffered(battleKey);
    }

    function test_builtIn_legacyExecutePathsInert() public {
        bytes32 battleKey = _startBuiltIn();
        _submit(battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, false);
        // Built-in submit writes the buffer, never config.pXMove → legacy execute() sees no moves set.
        vm.expectRevert(Engine.MovesNotSet.selector);
        engine.execute(battleKey);
        // executeWithMoves is moveManager-gated; nobody equals the sentinel.
        vm.prank(p0);
        vm.expectRevert(Engine.WrongCaller.selector);
        engine.executeWithMoves(battleKey, 0, 0, 0, 0, 0, 0);
    }

    function test_builtIn_staleBufferOnStorageKeyReuse() public {
        // Battle 1: buffer a turn, then force-end WITHOUT draining (frees the storageKey with a
        // stale moveBuffer entry + stale numBuffered on the now-dead battleData).
        bytes32 key1 = _startBuiltIn();
        _submit(key1, 0, SWITCH_MOVE_INDEX, 0, 7, SWITCH_MOVE_INDEX, 0, 8, false);
        (, uint256[] memory turns1) = engine.getBufferedTurns(key1);
        assertEq(turns1.length, 1, "battle 1 has a buffered turn");
        _endBattle(key1);

        // Battle 2 reuses the freed storageKey. numBuffered lives in BattleData[battleKey] (reinit
        // each battle), so it starts at 0 — the stale moveBuffer slot is simply overwritten.
        bytes32 key2 = _startBuiltIn();
        require(engine.getStorageKey(key2) == key1, "battle 2 should reuse battle 1's storageKey");
        (uint64 exec2, uint256[] memory turns2) = engine.getBufferedTurns(key2);
        assertEq(exec2, 0, "fresh battle starts at turn 0");
        assertEq(turns2.length, 0, "no stale buffered count leaked across the storageKey reuse");
        // First submit of the fresh battle resolves to the derived turn 0 (no stale numBuffered leaked).
        _submit(key2, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, true);
        assertEq(engine.getTurnIdForBattleState(key2), 1, "battle 2 turn 0 executed cleanly");
    }
}
