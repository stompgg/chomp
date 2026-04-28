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
        engine = new Engine(0, 0, 0);
        validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 100})
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
        uint104 revealerSalt,
        uint16 revealerExtraData
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

        (uint256 committerPk, uint256 revealerPk) = turnId % 2 == 0 ? (P0_PK, P1_PK) : (P1_PK, P0_PK);
        bytes memory committerSignature =
            _signCommit(committerPk, committerMoveHash, battleKey, uint64(turnId));
        bytes memory revealerSignature = _signDualReveal(
            revealerPk, battleKey, uint64(turnId), committerMoveHash, moveIndex, revealerSalt, 0
        );

        // Caller can be anyone; pick committer for parity with old test setup.
        vm.startPrank(turnId % 2 == 0 ? p0 : p1);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            moveIndex,
            committerSalt,
            0,
            moveIndex,
            revealerSalt,
            0,
            committerSignature,
            revealerSignature
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

        // p0 signs their commitment, p1 signs their move + p0's hash
        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, turnId);
        uint104 p1Salt = uint104(2);
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
            p0CommitSig,
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

        uint104 p1Salt = uint104(2);
        bytes32 p1MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p1Salt, uint16(0)));
        bytes memory p1CommitSig = _signCommit(P1_PK, p1MoveHash, battleKey, turnId);

        uint104 p0Salt = uint104(3);
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
            p1CommitSig,
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

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        // Valid committer sig, but garbage revealer sig.
        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, 0);
        bytes memory invalidSignature = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

        vm.startPrank(p0);
        vm.expectRevert();
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            uint104(0),
            0,
            p0CommitSig,
            invalidSignature
        );
    }

    function test_revert_wrongSigner() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, 0);
        // p0 signs the revealer slot instead of p1 (wrong signer - should be revealer p1)
        bytes memory wrongSignature = _signDualReveal(
            P0_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            uint104(0),
            0,
            p0CommitSig,
            wrongSignature
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
        bytes memory turn0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, 0);
        bytes memory turn0Signature = _signDualReveal(
            P1_PK, battleKey, 0, p0MoveHash, NO_OP_MOVE_INDEX, uint104(0), 0
        );

        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            NO_OP_MOVE_INDEX,
            p0Salt,
            0,
            NO_OP_MOVE_INDEX,
            uint104(0),
            0,
            turn0CommitSig,
            turn0Signature
        );
    }

    function test_revert_replayAttack_differentBattle() public {
        bytes32 battleKey1 = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        // Both signatures bound to battle 1
        bytes memory battle1CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey1, 0);
        bytes memory battle1Signature = _signDualReveal(
            P1_PK, battleKey1, 0, p0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        // Start second battle and try to use battle 1's signatures
        bytes32 battleKey2 = _startBattleWith(address(signedCommitManager));

        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey2,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            uint104(0),
            0,
            battle1CommitSig,
            battle1Signature
        );
    }

    /// @notice Regression: a revealer alone (without an explicit committer signature) cannot
    /// inject a self-chosen committer preimage `P*`. Previously this was blocked only by the
    /// `msg.sender == committer` check; now both signatures are mandatory and bind each
    /// player independently, so the check holds even under a relayer model.
    function test_revert_executeWithDualSigned_unilateralRevealerAttack() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Attacker (p1, the revealer for turn 0) picks a preimage P* of their choosing for p0
        uint104 attackerCommitterSalt = uint104(0xdead);
        uint16 attackerCommitterExtraData = 0;
        uint8 attackerCommitterMoveIndex = SWITCH_MOVE_INDEX;
        bytes32 chosenCommitterMoveHash = keccak256(
            abi.encodePacked(attackerCommitterMoveIndex, attackerCommitterSalt, attackerCommitterExtraData)
        );

        // p1 signs the DualSignedReveal binding themselves to a chosen committer preimage
        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 0, chosenCommitterMoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        // Attacker forges a "committer signature" (signed by themselves, P1, over the same hash).
        bytes memory forgedCommitterSig = _signCommit(P1_PK, chosenCommitterMoveHash, battleKey, 0);

        // _startBattleWith leaves an active prank on p0; clear it.
        vm.stopPrank();

        // Submit (from any sender) — committer sig recover will return p1, not p0 → revert.
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            attackerCommitterMoveIndex,
            attackerCommitterSalt,
            attackerCommitterExtraData,
            SWITCH_MOVE_INDEX,
            uint104(0),
            0,
            forgedCommitterSig,
            p1Signature
        );
    }

    /// @notice Drops the old `msg.sender == committer` check: anyone can submit when both
    /// EIP-712 signatures are present and valid (relayer-friendly).
    function test_executeWithDualSigned_thirdPartyRelay_succeeds() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        uint104 p1Salt = uint104(2);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, 0);
        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, p1Salt, 0
        );

        // _startBattleWith leaves an active prank on p0; clear it before pranking the relayer.
        vm.stopPrank();

        // A random third party (neither p0 nor p1) can submit the bundle.
        address relayer = address(0xCAFE);
        vm.prank(relayer);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            p1Salt,
            0,
            p0CommitSig,
            p1Signature
        );

        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Turn should advance via relayer");
    }

    /// @notice Wrong committer signer (sig recovers to revealer's address, not committer's) reverts.
    function test_revert_executeWithDualSigned_wrongCommitterSigner() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        // p1 signs the SignedCommit instead of p0 → recovers to p1, not the committer p0.
        bytes memory wrongCommitSig = _signCommit(P1_PK, p0MoveHash, battleKey, 0);
        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            uint104(0),
            0,
            wrongCommitSig,
            p1Signature
        );
    }

    /// @notice Committer signature over a different `moveHash` than the submitted preimage
    /// reverts with InvalidSignature (the recovered hash differs from what the engine computes).
    function test_revert_executeWithDualSigned_committerSigForWrongHash() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        bytes32 p0DifferentMoveHash =
            keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p0Salt, uint16(0))); // committer signs over a different move

        bytes memory mismatchedCommitSig = _signCommit(P0_PK, p0DifferentMoveHash, battleKey, 0);
        // Revealer signs the same different hash so the revealer side would have validated
        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 0, p0DifferentMoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        // p0 submits with their REAL move data (SWITCH_MOVE_INDEX, p0Salt, 0). Engine recomputes
        // committerMoveHash from those fields → does not equal `p0DifferentMoveHash`. Committer sig
        // recovery against the recomputed hash returns a non-p0 address → InvalidSignature.
        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            uint104(0),
            0,
            mismatchedCommitSig,
            p1Signature
        );
    }

    // =========================================================================
    // Edge Case Tests
    // =========================================================================

    function test_revert_battleNotStarted() public {
        bytes32 fakeBattleKey = bytes32(uint256(123));

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, fakeBattleKey, 0);
        bytes memory p1Signature = _signDualReveal(
            P1_PK, fakeBattleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        vm.startPrank(p0);
        vm.expectRevert(Engine.BattleNotStarted.selector);
        signedCommitManager.executeWithDualSignedMoves(
            fakeBattleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            uint104(0),
            0,
            p0CommitSig,
            p1Signature
        );
    }

    function test_revert_replayPrevented_byTurnAdvancement() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // Execute turn 0 with dual-signed flow
        _completeTurnFast(battleKey, 0);

        // After turn 0, we're now on turn 1 where p1 is committer.
        // Try to replay with turn-0 signatures - fails because turnId in sigs (0) doesn't
        // match current turnId (1).
        uint104 p1Salt = uint104(99);
        bytes32 p1MoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, p1Salt, uint16(0)));

        // Both signatures are bound to turnId=0 (replay attempt)
        bytes memory p1CommitSig = _signCommit(P1_PK, p1MoveHash, battleKey, 0);
        bytes memory p0Signature = _signDualReveal(
            P0_PK, battleKey, 0, p1MoveHash, NO_OP_MOVE_INDEX, uint104(0), 0
        );

        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            NO_OP_MOVE_INDEX,
            p1Salt,
            0,
            NO_OP_MOVE_INDEX,
            uint104(0),
            0,
            p1CommitSig,
            p0Signature
        );
    }

    function test_revert_replayPrevented_sameBlockAttempt() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, 0);
        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        vm.startPrank(p0);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            uint104(0),
            0,
            p0CommitSig,
            p1Signature
        );

        // After execution, turn advances to 1. Replaying the same signatures (turnId=0) at
        // turnId=1 fails on the committer signature recovery — sig was bound to turn 0.
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            uint104(0),
            0,
            p0CommitSig,
            p1Signature
        );
    }

    function test_revert_hashMismatch() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        // p0's actual move data
        uint104 p0Salt = uint104(1);
        bytes32 p0RealMoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        // p0 signs the commitment for the REAL move hash (matches what they'll submit)
        bytes memory p0CommitSig = _signCommit(P0_PK, p0RealMoveHash, battleKey, 0);

        // p1 signs over a DIFFERENT hash than what p0 will submit
        bytes32 fakeP0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(999), uint16(0)));
        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 0, fakeP0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
        );

        // p0 tries to submit with their real move data: committer sig validates (matches
        // p0RealMoveHash), but revealer sig was over fakeP0MoveHash → revealer recovery fails.
        vm.startPrank(p0);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            SWITCH_MOVE_INDEX,
            p0Salt,
            0,
            SWITCH_MOVE_INDEX,
            uint104(0),
            0,
            p0CommitSig,
            p1Signature
        );
    }

    function test_revert_revealerMoveMismatch() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        uint104 p0Salt = uint104(1);
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, p0Salt, uint16(0)));

        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, 0);
        // p1 signs with SWITCH_MOVE_INDEX
        bytes memory p1Signature = _signDualReveal(
            P1_PK, battleKey, 0, p0MoveHash, SWITCH_MOVE_INDEX, uint104(0), 0
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
            uint104(0),
            0,
            p0CommitSig,
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
        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, 0);

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
        bytes memory p1CommitSig = _signCommit(P1_PK, p1MoveHash, battleKey, 1);

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

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(1), uint16(0)));

        // p1 signs instead of p0 (wrong signer)
        bytes memory wrongSig = _signCommit(P1_PK, p0MoveHash, battleKey, 0);

        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, wrongSig);
    }

    function test_commitWithSignature_revert_wrongTurn() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(1), uint16(0)));

        // p0 signs for turn 1 instead of turn 0
        bytes memory wrongTurnSig = _signCommit(P0_PK, p0MoveHash, battleKey, 1);

        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.commitWithSignature(battleKey, p0MoveHash, wrongTurnSig);
    }

    function test_commitWithSignature_revert_wrongBattle() public {
        bytes32 battleKey1 = _startBattleWith(address(signedCommitManager));
        bytes32 battleKey2 = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(1), uint16(0)));

        // p0 signs for battle 1
        bytes memory battle1Sig = _signCommit(P0_PK, p0MoveHash, battleKey1, 0);

        // Try to use on battle 2
        vm.startPrank(p1);
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        signedCommitManager.commitWithSignature(battleKey2, p0MoveHash, battle1Sig);
    }

    function test_commitWithSignature_revert_alreadyCommitted() public {
        bytes32 battleKey = _startBattleWith(address(signedCommitManager));

        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(1), uint16(0)));
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
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint104(1), uint16(0)));
        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, fakeBattleKey, 0);

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
        bytes memory p0CommitSig = _signCommit(P0_PK, p0MoveHash, battleKey, 0);
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
        bytes32 committerMoveHash =
            keccak256(abi.encodePacked(committerMoveIndex, committerSalt, committerExtraData));

        // Committer is p0 on even turns, p1 on odd turns.
        (uint256 committerPk, uint256 revealerPk, address committerAddr) =
            turnId % 2 == 0 ? (P0_PK, P1_PK, p0) : (P1_PK, P0_PK, p1);

        bytes memory committerSig = _signCommit(committerPk, committerMoveHash, battleKey, turnId);
        bytes memory revealerSig = _signDualReveal(
            revealerPk, battleKey, turnId, committerMoveHash, revealerMoveIndex, revealerSalt, revealerExtraData
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
            committerSig,
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
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp),
            p0HpBefore,
            "p0 HP unchanged"
        );
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp),
            p1HpBefore,
            "p1 HP unchanged"
        );
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
}
