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

    function _signCommit(
        uint256 privateKey,
        bytes32 moveHash,
        bytes32 battleKey,
        uint64 turnId
    ) internal view returns (bytes memory) {
        // Uses _DOMAIN_TYPEHASH imported from EIP712
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
            SignedCommitLib.SignedCommit({moveHash: moveHash, battleKey: battleKey, turnId: turnId})
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

    /// @dev Completes a turn using the signed commit flow.
    ///      Turn 0 uses SWITCH_MOVE_INDEX; subsequent turns use NO_OP_MOVE_INDEX.
    function _completeTurnFast(bytes32 battleKey, uint256 turnId) internal {
        bytes32 salt = bytes32(turnId + 1);
        uint8 moveIndex = turnId == 0 ? SWITCH_MOVE_INDEX : NO_OP_MOVE_INDEX;
        bytes32 moveHash = keccak256(abi.encodePacked(moveIndex, salt, uint240(0)));

        if (turnId % 2 == 0) {
            // p0 commits via signature, p1 reveals
            bytes memory signature = _signCommit(P0_PK, moveHash, battleKey, uint64(turnId));
            vm.startPrank(p1);
            signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
                battleKey, moveHash, signature, moveIndex, bytes32(0), 0, false
            );
            vm.startPrank(p0);
            signedCommitManager.revealMove(battleKey, moveIndex, salt, 0, true);
        } else {
            // p1 commits via signature, p0 reveals
            bytes memory signature = _signCommit(P1_PK, moveHash, battleKey, uint64(turnId));
            vm.startPrank(p0);
            signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
                battleKey, moveHash, signature, moveIndex, bytes32(0), 0, false
            );
            vm.startPrank(p1);
            signedCommitManager.revealMove(battleKey, moveIndex, salt, 0, true);
        }
    }
}

contract SignedCommitManagerTest is SignedCommitManagerTestBase {

    // =========================================================================
    // Happy Path Tests
    // =========================================================================

    function test_revealWithSignedCommit_turn0() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Turn 0: p0 is committer, p1 is revealer. Must use SWITCH to select first mon.
        uint64 turnId = 0;

        // p0 creates and signs commitment off-chain (switch to mon 0)
        bytes32 p0Salt = bytes32(uint256(1));
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint240(0)));
        bytes memory p0Signature = _signCommit(P0_PK, p0MoveHash, battleKey, turnId);

        // p1 reveals with p0's signed commit (p1 also switches to mon 0)
        vm.startPrank(p1);
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, p0MoveHash, p0Signature, SWITCH_MOVE_INDEX, bytes32(0), 0, false
        );

        // Verify p0's commitment was stored
        (bytes32 storedHash, uint256 storedTurnId) = signedCommitManager.getCommitment(battleKey, p0);
        assertEq(storedHash, p0MoveHash, "p0's move hash not stored");
        assertEq(storedTurnId, turnId, "Turn ID not stored correctly");

        // Verify p1's reveal was recorded
        assertEq(signedCommitManager.getMoveCountForBattleState(battleKey, p1), 1, "p1's move count should be 1");

        // p0 can now reveal normally
        vm.startPrank(p0);
        signedCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, p0Salt, 0, true);

        // Verify turn advanced
        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Turn should have advanced to 1");
    }

    function test_revealWithSignedCommit_turn1() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Complete turn 0 using normal flow to get to turn 1
        _completeTurnNormal(battleKey, 0);

        // Turn 1: p1 is committer, p0 is revealer
        uint64 turnId = 1;

        bytes32 p1Salt = bytes32(uint256(2));
        bytes32 p1MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p1Salt, uint240(0)));
        bytes memory p1Signature = _signCommit(P1_PK, p1MoveHash, battleKey, turnId);

        // p0 reveals with p1's signed commit
        vm.startPrank(p0);
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, p1MoveHash, p1Signature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );

        // Verify p1's commitment was stored
        (bytes32 storedHash, uint256 storedTurnId) = signedCommitManager.getCommitment(battleKey, p1);
        assertEq(storedHash, p1MoveHash, "p1's move hash not stored");
        assertEq(storedTurnId, turnId, "Turn ID not stored correctly");

        // p1 can now reveal normally
        vm.startPrank(p1);
        signedCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, p1Salt, 0, true);

        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "Turn should have advanced to 2");
    }

    function test_mixedFlow_someSignedSomeNormal() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Turn 0: Normal flow
        _completeTurnNormal(battleKey, 0);
        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Should be turn 1");

        // Turn 1: Signed commit flow
        _completeTurnFast(battleKey, 1);
        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "Should be turn 2");

        // Turn 2: Normal flow again
        _completeTurnNormal(battleKey, 2);
        assertEq(engine.getTurnIdForBattleState(battleKey), 3, "Should be turn 3");
    }

    // =========================================================================
    // Fallback Tests
    // =========================================================================

    function test_fallbackToNormalCommit_afterSignedCommitNotUsed() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // p0 signs a commit but p1 never uses it — p0 falls back to normal commit flow
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

        vm.startPrank(p0);
        signedCommitManager.commitMove(battleKey, p0MoveHash);

        (bytes32 storedHash,) = signedCommitManager.getCommitment(battleKey, p0);
        assertEq(storedHash, p0MoveHash, "p0's commitment should be stored");

        vm.startPrank(p1);
        signedCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, bytes32(0), 0, false);

        vm.startPrank(p0);
        signedCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, bytes32(uint256(1)), 0, true);

        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Should be turn 1");
    }

    function test_revealWithSignedCommit_whenAlreadyCommitted() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // p0 commits on-chain normally
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        vm.startPrank(p0);
        signedCommitManager.commitMove(battleKey, p0MoveHash);

        // p1 tries to use revealWithSignedCommit with a different hash
        // The signature should be ignored and normal reveal should happen
        bytes32 fakeMoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(999)), uint240(0)));
        bytes memory fakeSignature = _signCommit(P0_PK, fakeMoveHash, battleKey, 0);

        vm.startPrank(p1);
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, fakeMoveHash, fakeSignature, SWITCH_MOVE_INDEX, bytes32(0), 0, false
        );

        // Original on-chain commitment should still be stored
        (bytes32 storedHash,) = signedCommitManager.getCommitment(battleKey, p0);
        assertEq(storedHash, p0MoveHash, "Original commitment should remain");

        // p0 can reveal with original preimage
        vm.startPrank(p0);
        signedCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, bytes32(uint256(1)), 0, true);

        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Should be turn 1");
    }

    // =========================================================================
    // Timeout Compatibility Tests
    // =========================================================================

    function test_timeout_committerTimesOut_afterSignedCommitPublished() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // p1 publishes p0's signed commit
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory p0Signature = _signCommit(P0_PK, p0MoveHash, battleKey, 0);

        vm.startPrank(p1);
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, p0MoveHash, p0Signature, SWITCH_MOVE_INDEX, bytes32(0), 0, false
        );

        // p0 doesn't reveal in time
        vm.warp(block.timestamp + 101);

        address loser = validator.validateTimeout(battleKey, 0);
        assertEq(loser, p0, "p0 should timeout");
    }

    function test_timeout_worksNormally_withSignedCommitFlow() public {
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

        bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory invalidSignature = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

        vm.startPrank(p1);
        vm.expectRevert();
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, p0MoveHash, invalidSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    function test_revert_wrongSigner() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        // p1 signs instead of p0 (wrong signer)
        bytes memory p1Signature = _signCommit(P1_PK, p0MoveHash, battleKey, 0);

        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidCommitSignature.selector);
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, p0MoveHash, p1Signature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    function test_revert_replayAttack_differentTurn() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        _completeTurnNormal(battleKey, 0);
        _completeTurnNormal(battleKey, 1);

        // On turn 2, p0 is committer again. Replay p0's turn 0 signature.
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory turn0Signature = _signCommit(P0_PK, p0MoveHash, battleKey, 0);

        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidCommitSignature.selector);
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, p0MoveHash, turn0Signature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    function test_revert_replayAttack_differentBattle() public {
        bytes32 battleKey1 = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory battle1Signature = _signCommit(P0_PK, p0MoveHash, battleKey1, 0);

        // Start second battle and try to use battle 1's signature
        bytes32 battleKey2 = _startBattleWith(address(signedCommitManager));

        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidCommitSignature.selector);
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey2, p0MoveHash, battle1Signature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    function test_revert_callerNotRevealer() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory p0Signature = _signCommit(P0_PK, p0MoveHash, battleKey, 0);

        // p0 (committer) tries to call revealWithSignedCommit - should fail
        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.CallerNotRevealer.selector);
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, p0MoveHash, p0Signature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    // =========================================================================
    // Edge Case Tests
    // =========================================================================

    function test_turn0_edgeCase_moveHashZeroCheck() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Turn 0 checks moveHash != 0 (instead of turnId) for existing commits
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory p0Signature = _signCommit(P0_PK, p0MoveHash, battleKey, 0);

        // Before signed commit, commitment should be empty
        (bytes32 storedHash, uint256 storedTurnId) = signedCommitManager.getCommitment(battleKey, p0);
        assertEq(storedHash, bytes32(0), "Hash should be 0 before commit");
        assertEq(storedTurnId, 0, "Turn ID should be 0");

        vm.startPrank(p1);
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, p0MoveHash, p0Signature, SWITCH_MOVE_INDEX, bytes32(0), 0, false
        );

        // After signed commit, commitment should be stored
        (storedHash, storedTurnId) = signedCommitManager.getCommitment(battleKey, p0);
        assertEq(storedHash, p0MoveHash, "Hash should be stored after signed commit");
        assertEq(storedTurnId, 0, "Turn ID should still be 0");
    }

    function test_revert_battleNotStarted() public {
        bytes32 fakeBattleKey = bytes32(uint256(123));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory p0Signature = _signCommit(P0_PK, p0MoveHash, fakeBattleKey, 0);

        vm.startPrank(p1);
        vm.expectRevert(DefaultCommitManager.BattleNotYetStarted.selector);
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            fakeBattleKey, p0MoveHash, p0Signature, SWITCH_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    function test_revert_doubleReveal() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory p0Signature = _signCommit(P0_PK, p0MoveHash, battleKey, 0);

        vm.startPrank(p1);
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, p0MoveHash, p0Signature, SWITCH_MOVE_INDEX, bytes32(0), 0, false
        );

        vm.expectRevert(DefaultCommitManager.AlreadyRevealed.selector);
        signedCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, p0MoveHash, p0Signature, SWITCH_MOVE_INDEX, bytes32(0), 0, false
        );
    }
}
