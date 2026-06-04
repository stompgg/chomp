// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {BatchHelper} from "./abstract/BatchHelper.sol";
import {SignedCommitManagerTestBase} from "./SignedCommitManager.t.sol";

/// @notice Adversarial + functional tests for the Engine's BUILT-IN dual-signed buffer flow
///         (BUILTIN_DUAL_SIGNED_MANAGER battles): submitTurnMoves / executeBuffered live in the
///         Engine, no external SignedCommitManager. Reuses SignedCommitManagerTestBase's setup
///         (engine + validator + matchmaker + 2-mon teams) and BatchHelper's Engine-domain signing.
contract EngineBuiltInBufferTest is SignedCommitManagerTestBase, BatchHelper {
    function _startBuiltIn() internal returns (bytes32 battleKey) {
        battleKey = _startBattleWith(BUILTIN_DUAL_SIGNED_MANAGER);
        vm.stopPrank(); // _startBattleWith leaves an active prank on p0
    }

    /// @dev Build the Engine-domain TurnSubmission and call submitTurnMoves (or the combined variant)
    ///      as the parity-correct committer.
    function _submit(
        bytes32 battleKey,
        uint64 turnId,
        uint8 p0m, uint16 p0e, uint104 p0s,
        uint8 p1m, uint16 p1e, uint104 p1s,
        bool combined
    ) internal {
        TurnSubmission memory entry =
            _buildTurnSubmissionForEngine(address(engine), battleKey, turnId, p0m, p0e, p0s, p1m, p1e, p1s, P0_PK, P1_PK);
        vm.prank(turnId % 2 == 0 ? p0 : p1);
        if (combined) engine.submitTurnMovesAndExecute(battleKey, entry);
        else engine.submitTurnMoves(battleKey, entry);
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
        (uint64 numExecuted, uint8 numBuffered) = engine.getBufferStatus(battleKey);
        assertEq(numExecuted, 0, "no turn executed yet");
        assertEq(numBuffered, 1, "one turn buffered");
        assertEq(engine.getTurnIdForBattleState(battleKey), 0, "engine turnId unchanged while buffered");

        // Turn 1: both attack with move 0; combined submit drains the whole buffer.
        _submit(battleKey, 1, 0, 0, 3, 0, 0, 4, true);
        (numExecuted, numBuffered) = engine.getBufferStatus(battleKey);
        assertEq(numBuffered, 0, "buffer drained");
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
        TurnSubmission memory entry =
            _buildTurnSubmissionForEngine(address(engine), battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, P0_PK, P1_PK);
        vm.prank(p0);
        vm.expectRevert(Engine.NotBuiltInManager.selector);
        engine.submitTurnMoves(battleKey, entry);
    }

    function test_builtIn_revert_wrongTurnId_skipAhead() public {
        bytes32 battleKey = _startBuiltIn();
        // Next valid id is 0; submitting turn 1 first must revert.
        TurnSubmission memory entry =
            _buildTurnSubmissionForEngine(address(engine), battleKey, 1, 0, 0, 3, 0, 0, 4, P0_PK, P1_PK);
        vm.prank(p1); // committer for turn 1
        vm.expectRevert(Engine.WrongTurnId.selector);
        engine.submitTurnMoves(battleKey, entry);
    }

    function test_builtIn_revert_overwriteBufferedTurn() public {
        bytes32 battleKey = _startBuiltIn();
        _submit(battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, false);
        // Turn 0 already buffered; next valid id is now 1, so re-submitting 0 reverts (no overwrite).
        TurnSubmission memory entry =
            _buildTurnSubmissionForEngine(address(engine), battleKey, 0, SWITCH_MOVE_INDEX, 0, 9, SWITCH_MOVE_INDEX, 0, 9, P0_PK, P1_PK);
        vm.prank(p0);
        vm.expectRevert(Engine.WrongTurnId.selector);
        engine.submitTurnMoves(battleKey, entry);
    }

    function test_builtIn_revert_notCommitter() public {
        bytes32 battleKey = _startBuiltIn();
        // Turn 0 committer is p0; p1 (the revealer) cannot submit.
        TurnSubmission memory entry =
            _buildTurnSubmissionForEngine(address(engine), battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, P0_PK, P1_PK);
        vm.prank(p1);
        vm.expectRevert(Engine.NotCommitter.selector);
        engine.submitTurnMoves(battleKey, entry);
    }

    function test_builtIn_revert_forgedRevealerSignature() public {
        bytes32 battleKey = _startBuiltIn();
        // Committer p0 builds a valid entry, then we corrupt the revealer signature.
        TurnSubmission memory entry =
            _buildTurnSubmissionForEngine(address(engine), battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, P0_PK, P1_PK);
        entry.revealerSig[10] = bytes1(uint8(entry.revealerSig[10]) ^ 0xFF);
        vm.prank(p0);
        vm.expectRevert();
        engine.submitTurnMoves(battleKey, entry);
    }

    function test_builtIn_revert_managerDomainSignatureRejected() public {
        bytes32 battleKey = _startBuiltIn();
        // A revealer signature for the EXTERNAL manager domain must NOT validate against the Engine.
        TurnSubmission memory entry =
            _buildTurnSubmission(address(signedCommitManager), battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, P0_PK, P1_PK);
        vm.prank(p0);
        vm.expectRevert(Engine.InvalidSignature.selector);
        engine.submitTurnMoves(battleKey, entry);
    }

    function test_builtIn_revert_submitAfterComplete() public {
        bytes32 battleKey = _startBuiltIn();
        _endBattle(battleKey); // force-end after MAX_BATTLE_DURATION
        TurnSubmission memory entry =
            _buildTurnSubmissionForEngine(address(engine), battleKey, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, P0_PK, P1_PK);
        vm.prank(p0);
        vm.expectRevert(Engine.GameAlreadyOver.selector);
        engine.submitTurnMoves(battleKey, entry);
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
        (, uint8 buffered1) = engine.getBufferStatus(key1);
        assertEq(buffered1, 1, "battle 1 has a buffered turn");
        _endBattle(key1);

        // Battle 2 reuses the freed storageKey. numBuffered lives in BattleData[battleKey] (reinit
        // each battle), so it starts at 0 — the stale moveBuffer slot is simply overwritten.
        bytes32 key2 = _startBuiltIn();
        require(engine.getStorageKey(key2) == key1, "battle 2 should reuse battle 1's storageKey");
        (uint64 exec2, uint8 buffered2) = engine.getBufferStatus(key2);
        assertEq(exec2, 0, "fresh battle starts at turn 0");
        assertEq(buffered2, 0, "no stale buffered count leaked across the storageKey reuse");
        // First submit of the fresh battle succeeds at turn 0 (no WrongTurnId from stale state).
        _submit(key2, 0, SWITCH_MOVE_INDEX, 0, 1, SWITCH_MOVE_INDEX, 0, 2, true);
        assertEq(engine.getTurnIdForBattleState(key2), 1, "battle 2 turn 0 executed cleanly");
    }
}
