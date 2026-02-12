// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {IEngine} from "../src/IEngine.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";
import {SignedCommitLib} from "../src/commit-manager/SignedCommitLib.sol";
import {TestMoveFactory} from "./mocks/TestMoveFactory.sol";
import {EIP712} from "../src/lib/EIP712.sol";

abstract contract SignedCommitManagerTestBase is Test, BattleHelper, EIP712 {
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

    // Required by EIP712 inheritance (only used to access _DOMAIN_TYPEHASH)
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("SignedCommitManager", "1");
    }

    function setUp() public virtual {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine();
        validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 100})
        );
        signedCommitManager = new SignedCommitManager(IEngine(address(engine)));
        matchmaker = new DefaultMatchmaker(engine);
        moveFactory = new TestMoveFactory(IEngine(address(engine)));

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
        mon.moves = new IMoveSet[](1);
        mon.moves[0] = testMove;

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

    /// @dev Signs a DualSignedReveal struct for the revealer
    /// @param privateKey The revealer's private key
    /// @param battleKey The battle identifier
    /// @param turnId The current turn ID
    /// @param committerMoveHash The committer's move hash (that revealer signs over)
    /// @param revealerMoveIndex The revealer's move index
    /// @param revealerSalt The revealer's salt
    /// @param revealerExtraData The revealer's extra data
    function _signDualReveal(
        uint256 privateKey,
        bytes32 battleKey,
        uint64 turnId,
        bytes32 committerMoveHash,
        uint8 revealerMoveIndex,
        bytes32 revealerSalt,
        uint240 revealerExtraData
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256("SignedCommitManager"),
                keccak256("1"),
                block.chainid,
                address(signedCommitManager)
            )
        );

        bytes32 structHash = SignedCommitLib.hashDualSignedReveal(
            SignedCommitLib.DualSignedReveal({
                battleKey: battleKey,
                turnId: turnId,
                committerMoveHash: committerMoveHash,
                revealerMoveIndex: revealerMoveIndex,
                revealerSalt: revealerSalt,
                revealerExtraData: revealerExtraData
            })
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signs a SignedCommit struct for the committer
    /// @param privateKey The committer's private key
    /// @param moveHash The committer's move hash
    /// @param battleKey The battle identifier
    /// @param turnId The current turn ID
    function _signCommit(
        uint256 privateKey,
        bytes32 moveHash,
        bytes32 battleKey,
        uint64 turnId
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256("SignedCommitManager"),
                keccak256("1"),
                block.chainid,
                address(signedCommitManager)
            )
        );

        bytes32 structHash = SignedCommitLib.hashSignedCommit(
            SignedCommitLib.SignedCommit({
                moveHash: moveHash,
                battleKey: battleKey,
                turnId: turnId
            })
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Completes a turn using the normal commit-reveal flow.
    ///      Turn 0 uses SWITCH_MOVE_INDEX; subsequent turns use NO_OP_MOVE_INDEX.
    function _completeTurnNormal(bytes32 battleKey, uint256 turnId) internal {
        bytes32 salt = bytes32(turnId + 1);
        uint8 moveIndex = turnId == 0 ? SWITCH_MOVE_INDEX : NO_OP_MOVE_INDEX;
        bytes32 moveHash = keccak256(abi.encodePacked(moveIndex, salt, uint240(0)));

        if (turnId % 2 == 0) {
            // p0 commits
            vm.startPrank(p0);
            signedCommitManager.commitMove(battleKey, moveHash);
            vm.startPrank(p1);
            signedCommitManager.revealMove(battleKey, moveIndex, bytes32(0), 0, false);
            vm.startPrank(p0);
            signedCommitManager.revealMove(battleKey, moveIndex, salt, 0, true);
        } else {
            // p1 commits
            vm.startPrank(p1);
            signedCommitManager.commitMove(battleKey, moveHash);
            vm.startPrank(p0);
            signedCommitManager.revealMove(battleKey, moveIndex, bytes32(0), 0, false);
            vm.startPrank(p1);
            signedCommitManager.revealMove(battleKey, moveIndex, salt, 0, true);
        }
    }

    /// @dev Completes a turn using the dual-signed flow (1 TX).
    ///      Turn 0 uses SWITCH_MOVE_INDEX; subsequent turns use NO_OP_MOVE_INDEX.
    function _completeTurnFast(bytes32 battleKey, uint256 turnId) internal {
        bytes32 committerSalt = bytes32(turnId + 1);
        bytes32 revealerSalt = bytes32(turnId + 2);
        uint8 moveIndex = turnId == 0 ? SWITCH_MOVE_INDEX : NO_OP_MOVE_INDEX;
        bytes32 committerMoveHash = keccak256(abi.encodePacked(moveIndex, committerSalt, uint240(0)));

        if (turnId % 2 == 0) {
            // p0 is committer, p1 is revealer
            bytes memory revealerSignature = _signDualReveal(
                P1_PK, battleKey, uint64(turnId), committerMoveHash, moveIndex, revealerSalt, 0
            );
            vm.startPrank(p0);
            signedCommitManager.executeWithDualSignedMoves(
                battleKey,
                moveIndex,
                committerSalt,
                0,
                moveIndex,
                revealerSalt,
                0,
                revealerSignature
            );
        } else {
            // p1 is committer, p0 is revealer
            bytes memory revealerSignature = _signDualReveal(
                P0_PK, battleKey, uint64(turnId), committerMoveHash, moveIndex, revealerSalt, 0
            );
            vm.startPrank(p1);
            signedCommitManager.executeWithDualSignedMoves(
                battleKey,
                moveIndex,
                committerSalt,
                0,
                moveIndex,
                revealerSalt,
                0,
                revealerSignature
            );
        }
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
        bytes32 p0Salt = bytes32(uint256(1));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint240(0)));

        // p1 signs their move + p0's hash
        bytes32 p1Salt = bytes32(uint256(2));
        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, turnId, p0MoveHash, SWITCH_MOVE_INDEX, p1Salt, 0
        );

        // p0 submits both moves and executes
        vm.startPrank(p0);
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

        // Verify turn advanced
        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Turn should have advanced to 1");

        // Note: In the optimized dual-signed flow, we don't update playerData.numMovesRevealed
        // The engine's lastExecuteTimestamp is used for timeout tracking instead
        assertEq(engine.getLastExecuteTimestamp(battleKey), uint48(block.timestamp), "lastExecuteTimestamp should be set");
    }

    function test_executeWithDualSigned_turn1() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Complete turn 0 using normal flow to get to turn 1
        _completeTurnNormal(battleKey, 0);

        // Turn 1: p1 is committer, p0 is revealer
        uint64 turnId = 1;

        bytes32 p1Salt = bytes32(uint256(2));
        bytes32 p1MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p1Salt, uint240(0)));

        bytes32 p0Salt = bytes32(uint256(3));
        bytes memory p0Signature = _signDualReveal(
            P0_PK, battleKey, turnId, p1MoveHash, NO_OP_MOVE_INDEX, p0Salt, 0
        );

        vm.startPrank(p1);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            NO_OP_MOVE_INDEX,
            p1Salt,
            0,
            NO_OP_MOVE_INDEX,
            p0Salt,
            0,
            p0Signature
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

        bytes32 p0Salt = bytes32(uint256(1));
        bytes memory invalidSignature = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

        vm.startPrank(p0);
        vm.expectRevert();
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            bytes32(0),
            0,
            invalidSignature
        );
    }

    function test_revert_wrongSigner() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0Salt = bytes32(uint256(1));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint240(0)));

        // p0 signs instead of p1 (wrong signer - should be revealer p1)
        bytes memory wrongSignature = _signDualReveal(
            P0_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, bytes32(0), 0
        );

        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            bytes32(0),
            0,
            wrongSignature
        );
    }

    function test_revert_replayAttack_differentTurn() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Complete turns 0 and 1 normally
        _completeTurnNormal(battleKey, 0);
        _completeTurnNormal(battleKey, 1);

        // On turn 2, p0 is committer again. Try to replay a turn 0 signature.
        bytes32 p0Salt = bytes32(uint256(1));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p0Salt, uint240(0)));

        // Create signature for turn 0 (not current turn 2)
        bytes memory turn0Signature = _signDualReveal(
            P1_PK, battleKey, 0, p0MoveHash, NO_OP_MOVE_INDEX, bytes32(0), 0
        );

        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            NO_OP_MOVE_INDEX,
            p0Salt,
            0,
            NO_OP_MOVE_INDEX,
            bytes32(0),
            0,
            turn0Signature
        );
    }

    function test_revert_replayAttack_differentBattle() public {
        bytes32 battleKey1 = _startBattleWith(address(signedCommitManager));

        bytes32 p0Salt = bytes32(uint256(1));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint240(0)));

        // Create signature for battle 1
        bytes memory battle1Signature = _signDualReveal(
            P1_PK, battleKey1, 0, p0MoveHash, SWITCH_MOVE_INDEX, bytes32(0), 0
        );

        // Start second battle and try to use battle 1's signature
        bytes32 battleKey2 = _startBattleWith(address(signedCommitManager));

        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey2,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            bytes32(0),
            0,
            battle1Signature
        );
    }

    function test_revert_callerNotCommitter() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0Salt = bytes32(uint256(1));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint240(0)));

        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, bytes32(0), 0
        );

        // p1 (revealer) tries to call executeWithDualSignedMoves - should fail
        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.CallerNotCommitter.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            bytes32(0),
            0,
            p1Signature
        );
    }

    // =========================================================================
    // Edge Case Tests
    // =========================================================================

    function test_revert_battleNotStarted() public {
        bytes32 fakeBattleKey = bytes32(uint256(123));

        bytes32 p0Salt = bytes32(uint256(1));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint240(0)));

        bytes memory p1Signature = _signDualReveal(
            P1_PK, fakeBattleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, bytes32(0), 0
        );

        vm.startPrank(p0);
        vm.expectRevert(Engine.BattleNotStarted.selector);
        signedCommitManager.executeWithDualSignedMoves(
            fakeBattleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            bytes32(0),
            0,
            p1Signature
        );
    }

    function test_revert_replayPrevented_byTurnAdvancement() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Execute turn 0 with dual-signed flow
        _completeTurnFast(battleKey, 0);

        // After turn 0, we're now on turn 1 where p1 is committer
        // Try to replay with a turn 0 signature - fails because:
        // 1. Turn has advanced, so signature turnId (0) doesn't match current turnId (1)
        bytes32 p1Salt = bytes32(uint256(99));
        bytes32 p1MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p1Salt, uint240(0)));

        bytes memory p0Signature = _signDualReveal(
            P0_PK, battleKey, 0, p1MoveHash, NO_OP_MOVE_INDEX, bytes32(0), 0
        );

        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            NO_OP_MOVE_INDEX,
            p1Salt,
            0,
            NO_OP_MOVE_INDEX,
            bytes32(0),
            0,
            p0Signature
        );
    }

    function test_revert_replayPrevented_sameBlockAttempt() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0Salt = bytes32(uint256(1));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint240(0)));

        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, bytes32(0), 0
        );

        vm.startPrank(p0);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            bytes32(0),
            0,
            p1Signature
        );

        // After execution, turn advances to 1. On turn 1, p1 is committer, not p0.
        // So if p0 tries to call again, it fails with CallerNotCommitter (turn parity changed)
        vm.expectRevert(SignedCommitManager.CallerNotCommitter.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            bytes32(0),
            0,
            p1Signature
        );
    }

    function test_revert_hashMismatch() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // p0's actual move data
        bytes32 p0Salt = bytes32(uint256(1));

        // p1 signs over a DIFFERENT hash than what p0 will submit
        bytes32 fakeP0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(999)), uint240(0)));

        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 0, fakeP0MoveHash, SWITCH_MOVE_INDEX, bytes32(0), 0
        );

        // p0 tries to submit with their real move data, but the hash won't match what p1 signed
        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            bytes32(0),
            0,
            p1Signature
        );
    }

    function test_revert_revealerMoveMismatch() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0Salt = bytes32(uint256(1));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint240(0)));

        // p1 signs with SWITCH_MOVE_INDEX
        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, bytes32(0), 0
        );

        // p0 tries to submit with different move for p1 (NO_OP instead of SWITCH)
        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            NO_OP_MOVE_INDEX, // Different from what p1 signed!
            bytes32(0),
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
        bytes32 p0Salt = bytes32(uint256(1));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint240(0)));

        // p0 signs their commitment
        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, 0);

        // p1 (revealer) publishes p0's commitment on-chain
        vm.startPrank(p1);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, p0CommitSig);

        // Verify commitment was stored
        (bytes32 storedHash, uint256 storedTurnId) = signedCommitManager.getCommitment(battleKey, p0);
        assertEq(storedHash, p0MoveHash, "Commitment hash not stored");
        assertEq(storedTurnId, 0, "Turn ID not stored correctly");

        // Now p1 can reveal normally
        signedCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, bytes32(0), 0, false);

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
        bytes32 p1Salt = bytes32(uint256(2));
        bytes32 p1MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p1Salt, uint240(0)));

        // p1 signs their commitment
        bytes memory p1CommitSig = _signCommit(P1_PK, p1MoveHash, battleKey, 1);

        // p0 (revealer) publishes p1's commitment on-chain
        vm.startPrank(p0);
        signedCommitManager.commitWithSignature(battleKey, p1MoveHash, p1CommitSig);

        // Verify commitment was stored
        (bytes32 storedHash, uint256 storedTurnId) = signedCommitManager.getCommitment(battleKey, p1);
        assertEq(storedHash, p1MoveHash, "Commitment hash not stored");
        assertEq(storedTurnId, 1, "Turn ID not stored correctly");

        // Now p0 can reveal
        signedCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(0), 0, false);

        // p1 reveals to complete the turn
        vm.startPrank(p1);
        signedCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, p1Salt, 0, true);

        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "Turn should have advanced to 2");
    }

    function test_commitWithSignature_anyoneCanSubmit() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0Salt = bytes32(uint256(1));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint240(0)));
        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, 0);

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

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

        // p1 signs instead of p0 (wrong signer)
        bytes memory wrongSig = _signCommit(P1_PK, p0MoveHash, battleKey, 0);

        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, wrongSig);
    }

    function test_commitWithSignature_revert_wrongTurn() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

        // p0 signs for turn 1 instead of turn 0
        bytes memory wrongTurnSig = _signCommit(P0_PK, p0MoveHash, battleKey, 1);

        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, wrongTurnSig);
    }

    function test_commitWithSignature_revert_wrongBattle() public {
        bytes32 battleKey1 = _startBattleWith(address(signedCommitManager));
        bytes32 battleKey2 = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

        // p0 signs for battle 1
        bytes memory battle1Sig = _signCommit(P0_PK, p0MoveHash, battleKey1, 0);

        // Try to use on battle 2
        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.commitWithSignature(battleKey2, p0MoveHash, battle1Sig);
    }

    function test_commitWithSignature_revert_alreadyCommitted() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, 0);

        // First commit succeeds
        vm.startPrank(p1);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, p0CommitSig);

        // Second commit fails
        vm.expectRevert(DefaultCommitManager.AlreadyCommited.selector);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, p0CommitSig);
    }

    function test_commitWithSignature_revert_battleNotStarted() public {
        bytes32 fakeBattleKey = bytes32(uint256(123));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, fakeBattleKey, 0);

        vm.startPrank(p1);
        vm.expectRevert(DefaultCommitManager.BattleNotYetStarted.selector);
        signedCommitManager.commitWithSignature(fakeBattleKey, p0MoveHash, p0CommitSig);
    }

    function test_commitWithSignature_afterNormalCommit_reverts() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

        // p0 commits normally
        vm.startPrank(p0);
        signedCommitManager.commitMove(battleKey, p0MoveHash);

        // Now trying to commit with signature should fail
        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, 0);
        vm.startPrank(p1);
        vm.expectRevert(DefaultCommitManager.AlreadyCommited.selector);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, p0CommitSig);
    }
}
