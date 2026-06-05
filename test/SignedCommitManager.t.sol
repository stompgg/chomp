// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultValidator} from "../src/DefaultValidator.sol";
import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";
import {SignedCommitHelper} from "./abstract/SignedCommitHelper.sol";
import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {TestMoveFactory} from "./mocks/TestMoveFactory.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

abstract contract SignedCommitManagerTestBase is BattleHelper, SignedCommitHelper {
    Engine engine;
    SignedCommitManager signedCommitManager;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultValidator validator;
    DefaultMatchmaker matchmaker;
    TestMoveFactory moveFactory;

    // Private keys for signing (addresses derived via vm.addr)
    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    address p0;
    address p1;

    function setUp() public virtual {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine(0, 0);
        validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 100})
        );
        signedCommitManager = new SignedCommitManager(IEngine(address(engine)));
        matchmaker = new DefaultMatchmaker(engine);
        moveFactory = new TestMoveFactory();

        _setupTeams();
    }

    function _setupTeams() internal {
        IMoveSet testMove = moveFactory.createMove(MoveClass.Physical, Type.Fire, 10, 10);

        // Build on _createMon() from BattleHelper, override stats and add a move
        Mon memory mon = _createMon();
        mon.stats.hp = 100;
        mon.stats.stamina = 100;
        mon.stats.speed = 100;
        mon.stats.attack = 100;
        mon.stats.defense = 100;
        mon.stats.specialAttack = 100;
        mon.stats.specialDefense = 100;
        mon.moves = new uint256[](1);
        mon.moves[0] = uint256(uint160(address(testMove)));

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;
        defaultRegistry.setIndices(indices);
    }

    function _startBattleWith(address commitManager) internal returns (bytes32) {
        vm.startPrank(p0);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        vm.startPrank(p1);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = defaultRegistry.getMonRegistryIndicesForTeam(p0, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: p0,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: p1,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: mockOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: commitManager,
            matchmaker: matchmaker
        });

        vm.startPrank(p0);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(p1);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);

        vm.startPrank(p0);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);

        return battleKey;
    }

    /// @dev Completes a turn using the normal commit-reveal flow.
    ///      Turn 0 uses SWITCH_MOVE_INDEX; subsequent turns use NO_OP_MOVE_INDEX.
    function _completeTurnNormal(bytes32 battleKey, uint256 turnId) internal {
        uint104 salt = uint104(turnId + 1);
        uint8 moveIndex = turnId == 0 ? SWITCH_MOVE_INDEX : NO_OP_MOVE_INDEX;
        bytes32 moveHash = keccak256(abi.encodePacked(moveIndex, salt, uint16(0)));

        if (turnId % 2 == 0) {
            // p0 commits
            vm.startPrank(p0);
            signedCommitManager.commitMove(battleKey, moveHash);
            vm.startPrank(p1);
            signedCommitManager.revealMove(battleKey, moveIndex, uint104(0), 0, false);
            vm.startPrank(p0);
            signedCommitManager.revealMove(battleKey, moveIndex, salt, 0, true);
        } else {
            // p1 commits
            vm.startPrank(p1);
            signedCommitManager.commitMove(battleKey, moveHash);
            vm.startPrank(p0);
            signedCommitManager.revealMove(battleKey, moveIndex, uint104(0), 0, false);
            vm.startPrank(p1);
            signedCommitManager.revealMove(battleKey, moveIndex, salt, 0, true);
        }
        vm.stopPrank();
        engine.resetCallContext();
    }

    /// @dev Completes a turn using the dual-signed flow (1 TX).
    ///      Turn 0 uses SWITCH_MOVE_INDEX; subsequent turns use NO_OP_MOVE_INDEX.
    function _completeTurnFast(bytes32 battleKey, uint256 turnId) internal {
        uint104 committerSalt = uint104(turnId + 1);
        uint104 revealerSalt = uint104(turnId + 2);
        uint8 moveIndex = turnId == 0 ? SWITCH_MOVE_INDEX : NO_OP_MOVE_INDEX;
        bytes32 committerMoveHash = keccak256(abi.encodePacked(moveIndex, committerSalt, uint16(0)));

        (, uint256 revealerPk) = turnId % 2 == 0 ? (P0_PK, P1_PK) : (P1_PK, P0_PK);
        bytes memory revealerSignature = _signDualReveal(
            address(signedCommitManager),
            revealerPk,
            battleKey,
            uint64(turnId),
            committerMoveHash,
            moveIndex,
            revealerSalt,
            0
        );

        // Single-sig: the committer must be msg.sender (no committer signature).
        vm.startPrank(turnId % 2 == 0 ? p0 : p1);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, moveIndex, committerSalt, 0, moveIndex, revealerSalt, 0, revealerSignature
        );
        vm.stopPrank();
        engine.resetCallContext();
    }
}

contract SignedCommitManagerTest is SignedCommitManagerTestBase {
    // =========================================================================
    // Happy Path Tests
    // =========================================================================

    function test_executeWithDualSigned_turn0() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Turn 0: p0 is committer, p1 is revealer. Must use SWITCH to select first mon.
        uint64 turnId = 0;

        // p0 creates commitment hash off-chain
        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        // Single-sig: committer (p0) is msg.sender; only p1 (revealer) signs.
        uint104 p1Salt = uint104(2);
        bytes memory p1Signature = _signDualReveal(
            address(signedCommitManager), P1_PK, battleKey, turnId, p0MoveHash, SWITCH_MOVE_INDEX, p1Salt, 0
        );

        // p0 submits both moves and executes
        vm.startPrank(p0);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, SWITCH_MOVE_INDEX, p0Salt, 0, SWITCH_MOVE_INDEX, p1Salt, 0, p1Signature
        );

        // Verify turn advanced
        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Turn should have advanced to 1");
    }

    function test_executeWithDualSigned_turn1() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Complete turn 0 using normal flow to get to turn 1
        _completeTurnNormal(battleKey, 0);

        // Turn 1: p1 is committer, p0 is revealer
        uint64 turnId = 1;

        uint104 p1Salt = uint104(2);
        bytes32 p1MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p1Salt, uint16(0)));

        uint104 p0Salt = uint104(3);
        bytes memory p0Signature = _signDualReveal(
            address(signedCommitManager), P0_PK, battleKey, turnId, p1MoveHash, NO_OP_MOVE_INDEX, p0Salt, 0
        );

        // Single-sig: committer (p1) is msg.sender; only p0 (revealer) signs.
        vm.startPrank(p1);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, NO_OP_MOVE_INDEX, p1Salt, 0, NO_OP_MOVE_INDEX, p0Salt, 0, p0Signature
        );

        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "Turn should have advanced to 2");
    }

    function test_mixedFlow_someDualSignedSomeNormal() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Turn 0: Normal flow
        _completeTurnNormal(battleKey, 0);
        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Should be turn 1");

        // Turn 1: Dual-signed flow
        _completeTurnFast(battleKey, 1);
        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "Should be turn 2");

        // Turn 2: Normal flow again
        _completeTurnNormal(battleKey, 2);
        assertEq(engine.getTurnIdForBattleState(battleKey), 3, "Should be turn 3");

        // Turn 3: Dual-signed flow again
        _completeTurnFast(battleKey, 3);
        assertEq(engine.getTurnIdForBattleState(battleKey), 4, "Should be turn 4");
    }

    // =========================================================================
    // Fallback Tests
    // =========================================================================

    function test_fallbackToNormalFlow() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // If the revealer doesn't cooperate (doesn't send signature),
        // the committer can fall back to normal commit-reveal flow
        _completeTurnNormal(battleKey, 0);
        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Should be turn 1");

        _completeTurnNormal(battleKey, 1);
        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "Should be turn 2");
    }

    // =========================================================================
    // Timeout Compatibility Tests
    // =========================================================================

    function test_timeout_worksNormally() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // At the start, no one has timed out
        address loser = validator.validateTimeout(battleKey, 0);
        assertEq(loser, address(0), "No one should timeout yet");

        // Fast forward past the commit timeout (2x timeout duration from battle start)
        vm.warp(block.timestamp + 201);

        // p0 (committer) should timeout for not committing
        loser = validator.validateTimeout(battleKey, 0);
        assertEq(loser, p0, "p0 should timeout for not committing");
    }

    // =========================================================================
    // Signature Security Tests
    // =========================================================================

    function test_revert_invalidSignature() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        // Committer is msg.sender (p0); a garbage revealer sig must revert.
        bytes memory invalidSignature = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

        vm.startPrank(p0);
        vm.expectRevert();
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, SWITCH_MOVE_INDEX, p0Salt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, invalidSignature
        );
    }

    function test_revert_wrongSigner() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        // Wrong revealer signer: p0 signs the revealer slot instead of p1. Committer is msg.sender (p0).
        bytes memory wrongSignature = _signDualReveal(
            address(signedCommitManager), P0_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, SWITCH_MOVE_INDEX, p0Salt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, wrongSignature
        );
    }

    function test_revert_replayAttack_differentTurn() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Complete turns 0 and 1 normally
        _completeTurnNormal(battleKey, 0);
        _completeTurnNormal(battleKey, 1);

        // On turn 2, p0 is committer again. Try to replay turn-0 signatures.
        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p0Salt, uint16(0)));

        // Both signatures bound to turnId=0, replayed at turnId=2
        bytes memory turn0Signature = _signDualReveal(
            address(signedCommitManager), P1_PK, battleKey, 0, p0MoveHash, NO_OP_MOVE_INDEX, uint104(0), 0
        );

        // Committer (p0) is msg.sender; replayed turn-0 revealer sig is invalid at turn 2.
        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, NO_OP_MOVE_INDEX, p0Salt, 0, NO_OP_MOVE_INDEX, uint104(0), 0, turn0Signature
        );
    }

    function test_revert_replayAttack_differentBattle() public {
        bytes32 battleKey1 = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        // Both signatures bound to battle 1
        bytes memory battle1Signature = _signDualReveal(
            address(signedCommitManager), P1_PK, battleKey1, 0, p0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        // Start second battle and try to use battle 1's revealer signature
        bytes32 battleKey2 = _startBattleWith(address(signedCommitManager));

        // Committer (p0) is msg.sender; battle-1 revealer sig is invalid on battle 2.
        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey2, SWITCH_MOVE_INDEX, p0Salt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, battle1Signature
        );
    }

    /// @notice Regression: a revealer alone cannot inject a self-chosen committer preimage `P*`.
    /// Under single-sig the committer binding is `msg.sender == committer`, so the revealer (p1)
    /// submitting on turn 0 (where p0 is committer) reverts NotCommitter — they cannot play a
    /// forged committer move on p0's behalf.
    function test_revert_executeWithDualSigned_unilateralRevealerAttack() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Attacker (p1, the revealer for turn 0) picks a preimage P* of their choosing for p0.
        uint104 attackerCommitterSalt = uint104(0xdead);
        bytes32 chosenCommitterMoveHash =
            keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, attackerCommitterSalt, uint16(0)));

        // p1 signs the DualSignedReveal binding themselves to the chosen committer preimage.
        bytes memory p1Signature = _signDualReveal(
            address(signedCommitManager), P1_PK, battleKey, 0, chosenCommitterMoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        // _startBattleWith leaves an active prank on p0; the attacker (p1, NOT the committer) submits.
        vm.stopPrank();
        vm.prank(p1);
        vm.expectRevert(SignedCommitManager.NotCommitter.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, SWITCH_MOVE_INDEX, attackerCommitterSalt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, p1Signature
        );
    }

    /// @notice Single-sig is NOT relayer-friendly: a third party (not the committer) reverts
    /// NotCommitter — the committer must submit their own turn's tx.
    function test_revert_executeWithDualSigned_thirdPartyRelay_notCommitter() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        uint104 p1Salt = uint104(2);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        bytes memory p1Signature = _signDualReveal(
            address(signedCommitManager), P1_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, p1Salt, 0
        );

        // _startBattleWith leaves an active prank on p0; clear it before pranking the relayer.
        vm.stopPrank();
        address relayer = address(0xCAFE);
        vm.prank(relayer);
        vm.expectRevert(SignedCommitManager.NotCommitter.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, SWITCH_MOVE_INDEX, p0Salt, 0, SWITCH_MOVE_INDEX, p1Salt, 0, p1Signature
        );
    }

    /// @notice The committer cannot change their move after the revealer signs: the revealer's
    /// signature is over `committerMoveHash`, so if the committer (msg.sender) submits a preimage
    /// whose hash differs from the one the revealer signed over, the revealer sig fails to recover
    /// → InvalidSignature. (This is what keeps the committer honest without a committer signature.)
    function test_revert_executeWithDualSigned_committerMoveChanged() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        // Revealer (p1) signs over the committer's ORIGINAL move hash (NO_OP).
        bytes32 p0OriginalHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p0Salt, uint16(0)));
        bytes memory p1Signature = _signDualReveal(
            address(signedCommitManager), P1_PK, battleKey, 0, p0OriginalHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        // Committer (p0, msg.sender) submits a DIFFERENT move (SWITCH). The engine recomputes
        // committerMoveHash from the submitted fields → != p0OriginalHash → the revealer sig
        // recovers a non-p1 address → InvalidSignature.
        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, SWITCH_MOVE_INDEX, p0Salt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, p1Signature
        );
    }

    // =========================================================================
    // Edge Case Tests
    // =========================================================================

    function test_revert_replayPrevented_byTurnAdvancement() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Execute turn 0 with dual-signed flow
        _completeTurnFast(battleKey, 0);

        // After turn 0, we're now on turn 1 where p1 is committer.
        // Try to replay with turn-0 signatures - fails because turnId in sigs (0) doesn't
        // match current turnId (1).
        uint104 p1Salt = uint104(99);
        bytes32 p1MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p1Salt, uint16(0)));

        // Revealer signature bound to turnId=0 (replay attempt at turn 1).
        bytes memory p0Signature = _signDualReveal(
            address(signedCommitManager), P0_PK, battleKey, 0, p1MoveHash, NO_OP_MOVE_INDEX, uint104(0), 0
        );

        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, NO_OP_MOVE_INDEX, p1Salt, 0, NO_OP_MOVE_INDEX, uint104(0), 0, p0Signature
        );
    }

    function test_revert_replayPrevented_sameBlockAttempt() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        bytes memory p1Signature = _signDualReveal(
            address(signedCommitManager), P1_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        vm.startPrank(p0);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, SWITCH_MOVE_INDEX, p0Salt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, p1Signature
        );

        // After execution, turn advances to 1, where p1 (not p0) is the committer. The same caller
        // (p0) replaying is no longer the committer → NotCommitter (single-sig replay prevention;
        // the revealer-sig-replay path is covered by test_revert_replayPrevented_byTurnAdvancement).
        vm.expectRevert(SignedCommitManager.NotCommitter.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, SWITCH_MOVE_INDEX, p0Salt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, p1Signature
        );
    }

    function test_revert_hashMismatch() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // p0's actual move data
        uint104 p0Salt = uint104(1);
        bytes32 p0RealMoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        // p1 signs over a DIFFERENT hash than what p0 will submit
        bytes32 fakeP0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(999), uint16(0)));
        bytes memory p1Signature = _signDualReveal(
            address(signedCommitManager), P1_PK, battleKey, 0, fakeP0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        // p0 (committer, msg.sender) submits their real move data; revealer sig was over
        // fakeP0MoveHash → the recomputed committerMoveHash differs → revealer recovery fails.
        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey, SWITCH_MOVE_INDEX, p0Salt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, p1Signature
        );
    }

    function test_revert_revealerMoveMismatch() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        // p1 signs with SWITCH_MOVE_INDEX
        bytes memory p1Signature = _signDualReveal(
            address(signedCommitManager), P1_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        // p0 (committer, msg.sender) tries to submit a different revealer move (NO_OP not SWITCH).
        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            NO_OP_MOVE_INDEX, // Different from what p1 signed!
            uint104(0),
            0,
            p1Signature
        );
    }

    // =========================================================================
    // commitWithSignature Tests (Fallback when committer stalls)
    // =========================================================================

    function test_commitWithSignature_happyPath() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Turn 0: p0 is committer, p1 is revealer
        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        // p0 signs their commitment
        bytes memory p0CommitSig = _signCommit(address(signedCommitManager), P0_PK, p0MoveHash, battleKey, 0);

        // p1 (revealer) publishes p0's commitment on-chain
        vm.startPrank(p1);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, p0CommitSig);

        // Verify commitment was stored
        (bytes32 storedHash, uint256 storedTurnId) = signedCommitManager.getCommitment(battleKey, p0);
        assertEq(storedHash, p0MoveHash, "Commitment hash not stored");
        assertEq(storedTurnId, 0, "Turn ID not stored correctly");

        // Now p1 can reveal normally
        signedCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, uint104(0), 0, false);

        // p0 reveals to complete the turn
        vm.startPrank(p0);
        signedCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, p0Salt, 0, true);

        // Verify turn advanced
        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Turn should have advanced to 1");
    }

    function test_commitWithSignature_turn1() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Complete turn 0 normally
        _completeTurnNormal(battleKey, 0);

        // Turn 1: p1 is committer, p0 is revealer
        uint104 p1Salt = uint104(2);
        bytes32 p1MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p1Salt, uint16(0)));

        // p1 signs their commitment
        bytes memory p1CommitSig = _signCommit(address(signedCommitManager), P1_PK, p1MoveHash, battleKey, 1);

        // p0 (revealer) publishes p1's commitment on-chain
        vm.startPrank(p0);
        signedCommitManager.commitWithSignature(battleKey, p1MoveHash, p1CommitSig);

        // Verify commitment was stored
        (bytes32 storedHash, uint256 storedTurnId) = signedCommitManager.getCommitment(battleKey, p1);
        assertEq(storedHash, p1MoveHash, "Commitment hash not stored");
        assertEq(storedTurnId, 1, "Turn ID not stored correctly");

        // Now p0 can reveal
        signedCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, uint104(0), 0, false);

        // p1 reveals to complete the turn
        vm.startPrank(p1);
        signedCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, p1Salt, 0, true);

        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "Turn should have advanced to 2");
    }

    function test_commitWithSignature_anyoneCanSubmit() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));
        bytes memory p0CommitSig = _signCommit(address(signedCommitManager), P0_PK, p0MoveHash, battleKey, 0);

        // Even p0 themselves can submit their own signed commitment
        // (though this is equivalent to just calling commitMove)
        vm.startPrank(p0);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, p0CommitSig);

        // Verify commitment was stored
        (bytes32 storedHash,) = signedCommitManager.getCommitment(battleKey, p0);
        assertEq(storedHash, p0MoveHash, "Commitment should be stored");
    }

    function test_commitWithSignature_revert_wrongSigner() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(1), uint16(0)));

        // p1 signs instead of p0 (wrong signer)
        bytes memory wrongSig = _signCommit(address(signedCommitManager), P1_PK, p0MoveHash, battleKey, 0);

        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, wrongSig);
    }

    function test_commitWithSignature_revert_wrongTurn() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(1), uint16(0)));

        // p0 signs for turn 1 instead of turn 0
        bytes memory wrongTurnSig = _signCommit(address(signedCommitManager), P0_PK, p0MoveHash, battleKey, 1);

        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, wrongTurnSig);
    }

    function test_commitWithSignature_revert_wrongBattle() public {
        bytes32 battleKey1 = _startBattleWith(address(signedCommitManager));
        bytes32 battleKey2 = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(1), uint16(0)));

        // p0 signs for battle 1
        bytes memory battle1Sig = _signCommit(address(signedCommitManager), P0_PK, p0MoveHash, battleKey1, 0);

        // Try to use on battle 2
        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.commitWithSignature(battleKey2, p0MoveHash, battle1Sig);
    }

    function test_commitWithSignature_revert_alreadyCommitted() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(1), uint16(0)));
        bytes memory p0CommitSig = _signCommit(address(signedCommitManager), P0_PK, p0MoveHash, battleKey, 0);

        // First commit succeeds
        vm.startPrank(p1);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, p0CommitSig);

        // Second commit fails
        vm.expectRevert(DefaultCommitManager.AlreadyCommited.selector);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, p0CommitSig);
    }

    function test_commitWithSignature_revert_battleNotStarted() public {
        bytes32 fakeBattleKey = bytes32(uint256(123));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(1), uint16(0)));
        bytes memory p0CommitSig = _signCommit(address(signedCommitManager), P0_PK, p0MoveHash, fakeBattleKey, 0);

        vm.startPrank(p1);
        vm.expectRevert(DefaultCommitManager.BattleNotYetStarted.selector);
        signedCommitManager.commitWithSignature(fakeBattleKey, p0MoveHash, p0CommitSig);
    }

    function test_commitWithSignature_afterNormalCommit_reverts() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(1), uint16(0)));

        // p0 commits normally
        vm.startPrank(p0);
        signedCommitManager.commitMove(battleKey, p0MoveHash);

        // Now trying to commit with signature should fail
        bytes memory p0CommitSig = _signCommit(address(signedCommitManager), P0_PK, p0MoveHash, battleKey, 0);
        vm.startPrank(p1);
        vm.expectRevert(DefaultCommitManager.AlreadyCommited.selector);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, p0CommitSig);
    }
}

/// @title SignedCommitManagerEngineSafetyTest
/// @notice Verifies that the Engine correctly handles invalid moves arriving through the
///         dual-signed flow - the default production stack. Dual-signed skips commit-manager
///         validation entirely (comment in SignedCommitManager:107 says "engine validates
///         during execution"), so these scenarios would hit Engine._handleMove directly.
///         Before the safety checks were added, an OOB regular moveIndex would revert the
///         entire execute(), an OOB switch target would silently wrap to an unintended mon,
///         and a non-switch on a forced-switch turn would run against a KO'd/unset mon.
contract SignedCommitManagerEngineSafetyTest is SignedCommitManagerTestBase {
    /// @dev Helper: committer submits their move, revealer signs over it + their own move.
    /// Bypasses signedCommitManager's validatePlayerMove (none exists in the dual-signed flow).
    function _executeDualSigned(
        bytes32 battleKey,
        uint64 turnId,
        uint8 committerMoveIndex,
        uint16 committerExtraData,
        uint8 revealerMoveIndex,
        uint16 revealerExtraData
    ) internal {
        uint104 committerSalt = uint104(turnId + 1);
        uint104 revealerSalt = uint104(turnId + 2);
        bytes32 committerMoveHash = keccak256(abi.encodePacked(committerMoveIndex, committerSalt, committerExtraData));

        // Committer is p0 on even turns, p1 on odd turns. SINGLE-SIG: committer == msg.sender (no
        // committer signature); only the revealer signs.
        (, uint256 revealerPk, address committerAddr) = turnId % 2 == 0 ? (P0_PK, P1_PK, p0) : (P1_PK, P0_PK, p1);

        bytes memory revealerSig = _signDualReveal(
            address(signedCommitManager),
            revealerPk,
            battleKey,
            turnId,
            committerMoveHash,
            revealerMoveIndex,
            revealerSalt,
            revealerExtraData
        );

        vm.startPrank(committerAddr);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            committerMoveIndex,
            committerSalt,
            committerExtraData,
            revealerMoveIndex,
            revealerSalt,
            revealerExtraData,
            revealerSig
        );
        vm.stopPrank();
        engine.resetCallContext();
    }

    /// @notice Turn 0 with a non-switch move must coerce into a switch-to-mon-0, not revert
    ///         or run an "attack" before any mon has been sent in.
    function test_engineSafety_turn0NonSwitch_coercesToSwitchToMonZero() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // p0 sends a valid switch to mon 1, p1 sends NO_OP (would have been rejected at reveal in
        // the old flow). Engine must force p1 to switch-to-mon-0.
        _executeDualSigned(battleKey, 0, SWITCH_MOVE_INDEX, uint16(1), NO_OP_MOVE_INDEX, 0);

        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "turn should advance");
        uint256[] memory active = engine.getActiveMonIndexForBattleState(battleKey);
        assertEq(active[0], 1, "p0 should have switched in mon 1 via valid SWITCH");
        assertEq(active[1], 0, "p1 should have been force-switched to mon 0");
    }

    /// @notice Turn 0 with a regular (attack) moveIndex must also coerce, not try to run the attack.
    function test_engineSafety_turn0RegularMove_coercesToSwitchToMonZero() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Both players submit "move 0" on turn 0 - clearly invalid since nothing has been sent in.
        _executeDualSigned(battleKey, 0, 0, 0, 0, 0);

        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "turn should advance");
        uint256[] memory active = engine.getActiveMonIndexForBattleState(battleKey);
        assertEq(active[0], 0, "p0 force-switched to mon 0");
        assertEq(active[1], 0, "p1 force-switched to mon 0");
    }

    /// @notice Regular move with an out-of-bounds moveIndex must silently no-op rather than revert
    ///         on the `moves[moveIndex]` array access.
    function test_engineSafety_outOfBoundsRegularMove_silentNoOp() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Turn 0: both switch in mon 0.
        _executeDualSigned(battleKey, 0, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0);

        // Turn 1: p1 is committer. Submit moveIndex=50 - only 1 move is configured, so this is OOB.
        // p0 submits NO_OP. Before the fix this would have reverted inside _handleMove.
        // Snapshot pre-turn state so we can confirm nothing changed beyond turnId incrementing.
        int32 p0HpBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        int32 p1HpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        _executeDualSigned(battleKey, 1, 50, 0, NO_OP_MOVE_INDEX, 0);

        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "turn should advance despite bad moveIndex");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), p0HpBefore, "p0 HP unchanged");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), p1HpBefore, "p1 HP unchanged");
    }

    /// @notice Switch with an out-of-bounds target index must silently no-op, not silently wrap
    ///         via uint8 truncation and land on an unintended mon.
    function test_engineSafety_outOfBoundsSwitchTarget_silentNoOp() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Turn 0: both switch in mon 0.
        _executeDualSigned(battleKey, 0, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0);

        // Turn 1: p1 commits SWITCH with an out-of-bounds target (team size is 2, submit 99).
        // p0 NO_OPs. p1's active mon should stay at 0 (switch is a no-op), not wrap to 99 & 0xFF.
        _executeDualSigned(battleKey, 1, SWITCH_MOVE_INDEX, uint16(99), NO_OP_MOVE_INDEX, 0);

        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "turn should advance");
        uint256[] memory active = engine.getActiveMonIndexForBattleState(battleKey);
        assertEq(active[1], 0, "p1 still on mon 0 - OOB switch silently no-oped");
    }

    /// @notice Switch to the same mon on a non-turn-0 must silently no-op.
    function test_engineSafety_switchToSameMon_silentNoOp() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Turn 0: p0 switches to mon 1, p1 to mon 0.
        _executeDualSigned(battleKey, 0, SWITCH_MOVE_INDEX, uint16(1), SWITCH_MOVE_INDEX, 0);
        assertEq(engine.getActiveMonIndexForBattleState(battleKey)[0], 1);

        // Turn 1: p1 is committer. p1 tries to switch to their own active mon (0). p0 NO_OP.
        _executeDualSigned(battleKey, 1, SWITCH_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0);

        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "turn should advance");
        uint256[] memory active = engine.getActiveMonIndexForBattleState(battleKey);
        assertEq(active[1], 0, "p1 still on mon 0 - same-mon switch silent no-op");
    }

    function test_revertBattleNotCommiter() public {
        bytes32 fakeBattleKey = bytes32(uint256(123));
        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));
        bytes memory p1Signature = _signDualReveal(
            address(signedCommitManager), P1_PK, fakeBattleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );
        vm.startPrank(p0);
        vm.expectRevert(Engine.NotCommitter.selector);
        signedCommitManager.executeWithDualSignedMoves(
            fakeBattleKey, SWITCH_MOVE_INDEX, p0Salt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, p1Signature
        );
    }
}
