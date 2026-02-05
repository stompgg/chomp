// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultCommitManager} from "../src/DefaultCommitManager.sol";
import {FastCommitManager} from "../src/FastCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {IEngine} from "../src/IEngine.sol";
import {IValidator} from "../src/IValidator.sol";
import {IAbility} from "../src/abilities/IAbility.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";
import {SignedCommitLib} from "../src/lib/SignedCommitLib.sol";

contract FastCommitManagerTest is Test, BattleHelper {
    Engine engine;
    FastCommitManager fastCommitManager;
    DefaultCommitManager defaultCommitManager;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    IValidator validator;
    DefaultMatchmaker matchmaker;

    // Private keys for signing
    uint256 constant ALICE_PK = 0xA11CE;
    uint256 constant BOB_PK = 0xB0B;

    // Domain separator components
    bytes32 constant DOMAIN_TYPEHASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    function setUp() public {
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine();
        validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 100})
        );
        fastCommitManager = new FastCommitManager(IEngine(address(engine)));
        defaultCommitManager = new DefaultCommitManager(IEngine(address(engine)));
        matchmaker = new DefaultMatchmaker(engine);

        // Set up teams for both players
        _setupTeams();
    }

    function _setupTeams() internal {
        Mon[] memory team = new Mon[](2);
        team[0] = _createTestMon();
        team[1] = _createTestMon();

        // Use derived addresses from private keys
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        defaultRegistry.setTeam(alice, team);
        defaultRegistry.setTeam(bob, team);

        // Set indices for team hash computation
        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;
        defaultRegistry.setIndices(indices);
    }

    function _createTestMon() internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: 100,
                stamina: 100,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: new IMoveSet[](0),
            ability: IAbility(address(0))
        });
    }

    function _startBattleWithFastCommitManager() internal returns (bytes32) {
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // Both players authorize the matchmaker
        vm.startPrank(alice);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        vm.startPrank(bob);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        // Compute p0 team hash
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = defaultRegistry.getMonRegistryIndicesForTeam(alice, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        // Create proposal
        ProposedBattle memory proposal = ProposedBattle({
            p0: alice,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: bob,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: mockOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(fastCommitManager),
            matchmaker: matchmaker
        });

        // Propose battle
        vm.startPrank(alice);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        // Accept battle
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(bob);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);

        // Confirm and start battle
        vm.startPrank(alice);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);

        return battleKey;
    }

    function _signCommit(
        uint256 privateKey,
        bytes32 moveHash,
        bytes32 battleKey,
        uint64 turnId
    ) internal view returns (bytes memory) {
        // Build EIP-712 digest
        bytes32 domainSeparator = _buildDomainSeparator();

        SignedCommitLib.SignedCommit memory commit = SignedCommitLib.SignedCommit({
            moveHash: moveHash,
            battleKey: battleKey,
            turnId: turnId
        });

        bytes32 structHash = SignedCommitLib.hashSignedCommit(commit);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256("FastCommitManager"),
                keccak256("1"),
                block.chainid,
                address(fastCommitManager)
            )
        );
    }

    // =========================================================================
    // Happy Path Tests
    // =========================================================================

    function test_revealWithSignedCommit_turn0() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // Turn 0: Alice is committer (p0), Bob is revealer (p1)
        uint64 turnId = 0;

        // Alice creates and signs her commitment off-chain
        bytes32 aliceSalt = bytes32(uint256(1));
        uint8 aliceMoveIndex = NO_OP_MOVE_INDEX;
        uint240 aliceExtraData = 0;
        bytes32 aliceMoveHash = keccak256(abi.encodePacked(aliceMoveIndex, aliceSalt, aliceExtraData));
        bytes memory aliceSignature = _signCommit(ALICE_PK, aliceMoveHash, battleKey, turnId);

        // Bob reveals with Alice's signed commit
        vm.startPrank(bob);
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey,
            aliceMoveHash,
            aliceSignature,
            NO_OP_MOVE_INDEX, // Bob's move
            bytes32(0), // Bob's salt
            0, // Bob's extraData
            false
        );

        // Verify Alice's commitment was stored
        (bytes32 storedHash, uint256 storedTurnId) = fastCommitManager.getCommitment(battleKey, alice);
        assertEq(storedHash, aliceMoveHash, "Alice's move hash not stored");
        assertEq(storedTurnId, turnId, "Turn ID not stored correctly");

        // Verify Bob's reveal was recorded
        uint256 bobMoveCount = fastCommitManager.getMoveCountForBattleState(battleKey, bob);
        assertEq(bobMoveCount, 1, "Bob's move count should be 1");

        // Alice can now reveal normally
        vm.startPrank(alice);
        fastCommitManager.revealMove(battleKey, aliceMoveIndex, aliceSalt, aliceExtraData, true);

        // Verify turn advanced (execute was called)
        uint64 newTurnId = engine.getTurnIdForBattleState(battleKey);
        assertEq(newTurnId, 1, "Turn should have advanced to 1");
    }

    function test_revealWithSignedCommit_turn1() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // Complete turn 0 using normal flow to get to turn 1
        _completeTurn0Normal(battleKey);

        // Turn 1: Bob is committer (p1), Alice is revealer (p0)
        uint64 turnId = 1;

        // Bob creates and signs his commitment off-chain
        bytes32 bobSalt = bytes32(uint256(2));
        uint8 bobMoveIndex = NO_OP_MOVE_INDEX;
        uint240 bobExtraData = 0;
        bytes32 bobMoveHash = keccak256(abi.encodePacked(bobMoveIndex, bobSalt, bobExtraData));
        bytes memory bobSignature = _signCommit(BOB_PK, bobMoveHash, battleKey, turnId);

        // Alice reveals with Bob's signed commit
        vm.startPrank(alice);
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey,
            bobMoveHash,
            bobSignature,
            NO_OP_MOVE_INDEX, // Alice's move
            bytes32(0), // Alice's salt
            0, // Alice's extraData
            false
        );

        // Verify Bob's commitment was stored
        (bytes32 storedHash, uint256 storedTurnId) = fastCommitManager.getCommitment(battleKey, bob);
        assertEq(storedHash, bobMoveHash, "Bob's move hash not stored");
        assertEq(storedTurnId, turnId, "Turn ID not stored correctly");

        // Bob can now reveal normally
        vm.startPrank(bob);
        fastCommitManager.revealMove(battleKey, bobMoveIndex, bobSalt, bobExtraData, true);

        // Verify turn advanced
        uint64 newTurnId = engine.getTurnIdForBattleState(battleKey);
        assertEq(newTurnId, 2, "Turn should have advanced to 2");
    }

    function test_fullBattle_withSignedCommits() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // Turn 0: Fast flow (Alice commits via signature, Bob reveals)
        {
            bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
            bytes memory aliceSignature = _signCommit(ALICE_PK, aliceMoveHash, battleKey, 0);

            vm.startPrank(bob);
            fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
                battleKey, aliceMoveHash, aliceSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
            );

            vm.startPrank(alice);
            fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(1)), 0, true);
        }

        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Should be turn 1");

        // Turn 1: Fast flow (Bob commits via signature, Alice reveals)
        {
            bytes32 bobMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(2)), uint240(0)));
            bytes memory bobSignature = _signCommit(BOB_PK, bobMoveHash, battleKey, 1);

            vm.startPrank(alice);
            fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
                battleKey, bobMoveHash, bobSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
            );

            vm.startPrank(bob);
            fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(2)), 0, true);
        }

        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "Should be turn 2");
    }

    function test_mixedFlow_someSignedSomeNormal() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // Turn 0: Normal flow
        _completeTurn0Normal(battleKey);
        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Should be turn 1");

        // Turn 1: Fast flow
        {
            bytes32 bobMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(2)), uint240(0)));
            bytes memory bobSignature = _signCommit(BOB_PK, bobMoveHash, battleKey, 1);

            vm.startPrank(alice);
            fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
                battleKey, bobMoveHash, bobSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
            );

            vm.startPrank(bob);
            fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(2)), 0, true);
        }

        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "Should be turn 2");

        // Turn 2: Normal flow again
        {
            bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(3)), uint240(0)));

            vm.startPrank(alice);
            fastCommitManager.commitMove(battleKey, aliceMoveHash);

            vm.startPrank(bob);
            fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(0), 0, false);

            vm.startPrank(alice);
            fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(3)), 0, true);
        }

        assertEq(engine.getTurnIdForBattleState(battleKey), 3, "Should be turn 3");
    }

    // =========================================================================
    // Fallback Tests
    // =========================================================================

    function test_fallbackToNormalCommit_afterSignedCommitNotUsed() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // Alice signs a commit but Bob never uses it
        // Alice falls back to normal commit flow

        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

        // Alice commits normally (fallback)
        vm.startPrank(alice);
        fastCommitManager.commitMove(battleKey, aliceMoveHash);

        // Verify commitment stored
        (bytes32 storedHash,) = fastCommitManager.getCommitment(battleKey, alice);
        assertEq(storedHash, aliceMoveHash, "Alice's commitment should be stored");

        // Bob reveals normally
        vm.startPrank(bob);
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(0), 0, false);

        // Alice reveals and executes
        vm.startPrank(alice);
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(1)), 0, true);

        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Should be turn 1");
    }

    function test_revealWithSignedCommit_whenAlreadyCommitted() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // Alice commits on-chain normally
        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        vm.startPrank(alice);
        fastCommitManager.commitMove(battleKey, aliceMoveHash);

        // Bob tries to use revealWithSignedCommit with a different hash
        // The signature should be ignored and normal reveal should happen
        bytes32 fakeMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(999)), uint240(0)));
        bytes memory fakeSignature = _signCommit(ALICE_PK, fakeMoveHash, battleKey, 0);

        vm.startPrank(bob);
        // This should work - the signed commit is ignored because Alice already committed on-chain
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, fakeMoveHash, fakeSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );

        // The original on-chain commitment should still be stored (not the fake one)
        (bytes32 storedHash,) = fastCommitManager.getCommitment(battleKey, alice);
        assertEq(storedHash, aliceMoveHash, "Original commitment should remain");

        // Alice can reveal with her original preimage
        vm.startPrank(alice);
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(1)), 0, true);

        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "Should be turn 1");
    }

    // =========================================================================
    // Timeout Compatibility Tests
    // =========================================================================

    function test_timeout_committerTimesOut_afterSignedCommitPublished() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // Bob publishes Alice's signed commit
        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory aliceSignature = _signCommit(ALICE_PK, aliceMoveHash, battleKey, 0);

        vm.startPrank(bob);
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, aliceMoveHash, aliceSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );

        // Alice doesn't reveal in time
        vm.warp(block.timestamp + 101); // Past timeout

        // Check Alice times out
        address loser = DefaultValidator(address(validator)).validateTimeout(battleKey, 0);
        assertEq(loser, alice, "Alice should timeout");
    }

    function test_timeout_worksNormally_withSignedCommitFlow() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // At the start, no one has timed out
        address loser = DefaultValidator(address(validator)).validateTimeout(battleKey, 0);
        assertEq(loser, address(0), "No one should timeout yet");

        // Fast forward past the commit timeout (2x timeout duration from battle start)
        vm.warp(block.timestamp + 201);

        // Alice (committer) should timeout for not committing
        loser = DefaultValidator(address(validator)).validateTimeout(battleKey, 0);
        assertEq(loser, alice, "Alice should timeout for not committing");
    }

    // =========================================================================
    // Signature Security Tests
    // =========================================================================

    function test_revert_invalidSignature() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address bob = vm.addr(BOB_PK);

        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

        // Create an invalid signature (random bytes)
        bytes memory invalidSignature = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

        vm.startPrank(bob);
        vm.expectRevert(); // ECDSA.InvalidSignature or FastCommitManager.InvalidCommitSignature
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, aliceMoveHash, invalidSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    function test_revert_wrongSigner() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address bob = vm.addr(BOB_PK);

        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

        // Bob signs instead of Alice (wrong signer)
        bytes memory bobSignature = _signCommit(BOB_PK, aliceMoveHash, battleKey, 0);

        vm.startPrank(bob);
        vm.expectRevert(FastCommitManager.InvalidCommitSignature.selector);
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, aliceMoveHash, bobSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    function test_revert_replayAttack_differentTurn() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // Complete turn 0 normally
        _completeTurn0Normal(battleKey);

        // Complete turn 1 normally
        _completeTurn1Normal(battleKey);

        // Now on turn 2, Alice is committer again
        // Try to replay Alice's turn 0 signature
        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory turn0Signature = _signCommit(ALICE_PK, aliceMoveHash, battleKey, 0); // Signed for turn 0

        vm.startPrank(bob);
        vm.expectRevert(FastCommitManager.InvalidCommitSignature.selector);
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, aliceMoveHash, turn0Signature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    function test_revert_replayAttack_differentBattle() public {
        // Start first battle
        bytes32 battleKey1 = _startBattleWithFastCommitManager();
        address bob = vm.addr(BOB_PK);

        // Get Alice's signature for battle 1
        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory battle1Signature = _signCommit(ALICE_PK, aliceMoveHash, battleKey1, 0);

        // Start second battle
        bytes32 battleKey2 = _startBattleWithFastCommitManager();

        // Try to use battle 1's signature in battle 2
        vm.startPrank(bob);
        vm.expectRevert(FastCommitManager.InvalidCommitSignature.selector);
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey2, aliceMoveHash, battle1Signature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    function test_revert_callerNotRevealer() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address alice = vm.addr(ALICE_PK);

        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory aliceSignature = _signCommit(ALICE_PK, aliceMoveHash, battleKey, 0);

        // Alice (committer) tries to call revealWithSignedCommit - should fail
        vm.startPrank(alice);
        vm.expectRevert(FastCommitManager.CallerNotRevealer.selector);
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, aliceMoveHash, aliceSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    // =========================================================================
    // Edge Case Tests
    // =========================================================================

    function test_turn0_edgeCase_moveHashZeroCheck() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // Turn 0 has special handling for checking if committed (uses moveHash != 0 instead of turnId)
        // This test verifies that works correctly with signed commits

        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory aliceSignature = _signCommit(ALICE_PK, aliceMoveHash, battleKey, 0);

        // Before signed commit, commitment should be empty
        (bytes32 storedHash, uint256 storedTurnId) = fastCommitManager.getCommitment(battleKey, alice);
        assertEq(storedHash, bytes32(0), "Hash should be 0 before commit");
        assertEq(storedTurnId, 0, "Turn ID should be 0");

        vm.startPrank(bob);
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, aliceMoveHash, aliceSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );

        // After signed commit, commitment should be stored
        (storedHash, storedTurnId) = fastCommitManager.getCommitment(battleKey, alice);
        assertEq(storedHash, aliceMoveHash, "Hash should be stored after signed commit");
        assertEq(storedTurnId, 0, "Turn ID should still be 0");
    }

    function test_revert_battleNotStarted() public {
        // Don't start a battle
        bytes32 fakeBattleKey = bytes32(uint256(123));
        address bob = vm.addr(BOB_PK);

        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory aliceSignature = _signCommit(ALICE_PK, aliceMoveHash, fakeBattleKey, 0);

        vm.startPrank(bob);
        vm.expectRevert(DefaultCommitManager.BattleNotYetStarted.selector);
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            fakeBattleKey, aliceMoveHash, aliceSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    function test_revert_doubleReveal() public {
        bytes32 battleKey = _startBattleWithFastCommitManager();
        address bob = vm.addr(BOB_PK);

        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory aliceSignature = _signCommit(ALICE_PK, aliceMoveHash, battleKey, 0);

        vm.startPrank(bob);
        // First reveal
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, aliceMoveHash, aliceSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );

        // Try to reveal again
        vm.expectRevert(DefaultCommitManager.AlreadyRevealed.selector);
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, aliceMoveHash, aliceSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    function _completeTurn0Normal(bytes32 battleKey) internal {
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

        vm.startPrank(alice);
        fastCommitManager.commitMove(battleKey, aliceMoveHash);

        vm.startPrank(bob);
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(0), 0, false);

        vm.startPrank(alice);
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(1)), 0, true);
    }

    function _completeTurn1Normal(bytes32 battleKey) internal {
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        bytes32 bobMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(2)), uint240(0)));

        vm.startPrank(bob);
        fastCommitManager.commitMove(battleKey, bobMoveHash);

        vm.startPrank(alice);
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(0), 0, false);

        vm.startPrank(bob);
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(2)), 0, true);
    }
}

/// @title Gas Benchmark Tests for FastCommitManager
/// @notice Compares gas usage between normal and fast commit flows
/// @dev Tests both cold (first access) and warm (subsequent access) storage patterns
contract FastCommitManagerGasBenchmarkTest is Test, BattleHelper {
    Engine engine;
    FastCommitManager fastCommitManager;
    DefaultCommitManager defaultCommitManager;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    IValidator validator;
    DefaultMatchmaker matchmaker;

    uint256 constant ALICE_PK = 0xA11CE;
    uint256 constant BOB_PK = 0xB0B;
    bytes32 constant DOMAIN_TYPEHASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

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

    function setUp() public {
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine();
        validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 100})
        );
        fastCommitManager = new FastCommitManager(IEngine(address(engine)));
        defaultCommitManager = new DefaultCommitManager(IEngine(address(engine)));
        matchmaker = new DefaultMatchmaker(engine);

        _setupTeams();
    }

    function _setupTeams() internal {
        Mon[] memory team = new Mon[](2);
        team[0] = _createTestMon();
        team[1] = _createTestMon();

        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        defaultRegistry.setTeam(alice, team);
        defaultRegistry.setTeam(bob, team);

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;
        defaultRegistry.setIndices(indices);
    }

    function _createTestMon() internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: 100,
                stamina: 100,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: new IMoveSet[](0),
            ability: IAbility(address(0))
        });
    }

    function _startBattleWithCommitManager(address commitManager) internal returns (bytes32) {
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        vm.startPrank(alice);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        vm.startPrank(bob);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = defaultRegistry.getMonRegistryIndicesForTeam(alice, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: alice,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: bob,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: mockOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: commitManager,
            matchmaker: matchmaker
        });

        vm.startPrank(alice);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(bob);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);

        vm.startPrank(alice);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);

        return battleKey;
    }

    function _signCommit(
        uint256 privateKey,
        bytes32 moveHash,
        bytes32 battleKey,
        uint64 turnId
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256("FastCommitManager"),
                keccak256("1"),
                block.chainid,
                address(fastCommitManager)
            )
        );

        SignedCommitLib.SignedCommit memory commit = SignedCommitLib.SignedCommit({
            moveHash: moveHash,
            battleKey: battleKey,
            turnId: turnId
        });

        bytes32 structHash = SignedCommitLib.hashSignedCommit(commit);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Benchmark: Normal flow - COLD storage access (Turn 0)
    /// @dev Cold access = first time writing to storage slots for this battle
    function test_gasBenchmark_normalFlow_cold() public {
        bytes32 battleKey = _startBattleWithCommitManager(address(fastCommitManager));
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

        // Measure commit gas (cold)
        vm.startPrank(alice);
        uint256 gasBefore = gasleft();
        fastCommitManager.commitMove(battleKey, aliceMoveHash);
        gasUsed_normalFlow_cold_commit = gasBefore - gasleft();

        // Measure reveal 1 gas (cold for Bob)
        vm.startPrank(bob);
        gasBefore = gasleft();
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(0), 0, false);
        gasUsed_normalFlow_cold_reveal1 = gasBefore - gasleft();

        // Measure reveal 2 gas (warm for Alice - already wrote in commit)
        vm.startPrank(alice);
        gasBefore = gasleft();
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(1)), 0, true);
        gasUsed_normalFlow_cold_reveal2 = gasBefore - gasleft();

        emit log_named_uint("Normal Flow (Cold) - Commit", gasUsed_normalFlow_cold_commit);
        emit log_named_uint("Normal Flow (Cold) - Reveal 1 (Bob)", gasUsed_normalFlow_cold_reveal1);
        emit log_named_uint("Normal Flow (Cold) - Reveal 2 (Alice)", gasUsed_normalFlow_cold_reveal2);
        emit log_named_uint("Normal Flow (Cold) - TOTAL",
            gasUsed_normalFlow_cold_commit + gasUsed_normalFlow_cold_reveal1 + gasUsed_normalFlow_cold_reveal2);
    }

    /// @notice Benchmark: Fast flow - COLD storage access (Turn 0)
    function test_gasBenchmark_fastFlow_cold() public {
        bytes32 battleKey = _startBattleWithCommitManager(address(fastCommitManager));
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
        bytes memory aliceSignature = _signCommit(ALICE_PK, aliceMoveHash, battleKey, 0);

        // Measure signed commit + reveal gas (cold for both Alice and Bob storage)
        vm.startPrank(bob);
        uint256 gasBefore = gasleft();
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, aliceMoveHash, aliceSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
        gasUsed_fastFlow_cold_signedCommitReveal = gasBefore - gasleft();

        // Measure Alice's reveal (warm - her storage was written in previous call)
        vm.startPrank(alice);
        gasBefore = gasleft();
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(uint256(1)), 0, true);
        gasUsed_fastFlow_cold_reveal = gasBefore - gasleft();

        emit log_named_uint("Fast Flow (Cold) - SignedCommit+Reveal", gasUsed_fastFlow_cold_signedCommitReveal);
        emit log_named_uint("Fast Flow (Cold) - Reveal (Alice)", gasUsed_fastFlow_cold_reveal);
        emit log_named_uint("Fast Flow (Cold) - TOTAL",
            gasUsed_fastFlow_cold_signedCommitReveal + gasUsed_fastFlow_cold_reveal);
    }

    /// @notice Benchmark: Normal flow - WARM storage access (Turn 2+)
    /// @dev Warm access = storage slots already initialized from previous turns
    function test_gasBenchmark_normalFlow_warm() public {
        bytes32 battleKey = _startBattleWithCommitManager(address(fastCommitManager));
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // Complete turns 0 and 1 to warm up storage
        _completeTurnNormal(battleKey, 0);
        _completeTurnNormal(battleKey, 1);

        // Now measure turn 2 (warm storage - Alice commits again)
        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(100)), uint240(0)));

        vm.startPrank(alice);
        uint256 gasBefore = gasleft();
        fastCommitManager.commitMove(battleKey, aliceMoveHash);
        gasUsed_normalFlow_warm_commit = gasBefore - gasleft();

        vm.startPrank(bob);
        gasBefore = gasleft();
        fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(0), 0, false);
        gasUsed_normalFlow_warm_reveal1 = gasBefore - gasleft();

        vm.startPrank(alice);
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
        bytes32 battleKey = _startBattleWithCommitManager(address(fastCommitManager));
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // Complete turns 0 and 1 to warm up storage
        _completeTurnNormal(battleKey, 0);
        _completeTurnNormal(battleKey, 1);

        // Now measure turn 2 with fast flow (warm storage)
        bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(100)), uint240(0)));
        bytes memory aliceSignature = _signCommit(ALICE_PK, aliceMoveHash, battleKey, 2);

        vm.startPrank(bob);
        uint256 gasBefore = gasleft();
        fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
            battleKey, aliceMoveHash, aliceSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
        );
        gasUsed_fastFlow_warm_signedCommitReveal = gasBefore - gasleft();

        vm.startPrank(alice);
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
        // Run all benchmarks and compare
        bytes32 battleKey1 = _startBattleWithCommitManager(address(fastCommitManager));
        bytes32 battleKey2 = _startBattleWithCommitManager(address(fastCommitManager));

        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        // === COLD BENCHMARKS ===

        // Normal flow cold
        {
            bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));

            vm.startPrank(alice);
            uint256 gasBefore = gasleft();
            fastCommitManager.commitMove(battleKey1, aliceMoveHash);
            gasUsed_normalFlow_cold_commit = gasBefore - gasleft();

            vm.startPrank(bob);
            gasBefore = gasleft();
            fastCommitManager.revealMove(battleKey1, NO_OP_MOVE_INDEX, bytes32(0), 0, false);
            gasUsed_normalFlow_cold_reveal1 = gasBefore - gasleft();

            vm.startPrank(alice);
            gasBefore = gasleft();
            fastCommitManager.revealMove(battleKey1, NO_OP_MOVE_INDEX, bytes32(uint256(1)), 0, true);
            gasUsed_normalFlow_cold_reveal2 = gasBefore - gasleft();
        }

        // Fast flow cold
        {
            bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(1)), uint240(0)));
            bytes memory aliceSignature = _signCommit(ALICE_PK, aliceMoveHash, battleKey2, 0);

            vm.startPrank(bob);
            uint256 gasBefore = gasleft();
            fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
                battleKey2, aliceMoveHash, aliceSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
            );
            gasUsed_fastFlow_cold_signedCommitReveal = gasBefore - gasleft();

            vm.startPrank(alice);
            gasBefore = gasleft();
            fastCommitManager.revealMove(battleKey2, NO_OP_MOVE_INDEX, bytes32(uint256(1)), 0, true);
            gasUsed_fastFlow_cold_reveal = gasBefore - gasleft();
        }

        // === WARM BENCHMARKS ===

        // Complete turn 1 for both battles
        _completeTurnNormal(battleKey1, 1);
        _completeTurnFast(battleKey2, 1);

        // Normal flow warm (turn 2)
        {
            bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(100)), uint240(0)));

            vm.startPrank(alice);
            uint256 gasBefore = gasleft();
            fastCommitManager.commitMove(battleKey1, aliceMoveHash);
            gasUsed_normalFlow_warm_commit = gasBefore - gasleft();

            vm.startPrank(bob);
            gasBefore = gasleft();
            fastCommitManager.revealMove(battleKey1, NO_OP_MOVE_INDEX, bytes32(0), 0, false);
            gasUsed_normalFlow_warm_reveal1 = gasBefore - gasleft();

            vm.startPrank(alice);
            gasBefore = gasleft();
            fastCommitManager.revealMove(battleKey1, NO_OP_MOVE_INDEX, bytes32(uint256(100)), 0, true);
            gasUsed_normalFlow_warm_reveal2 = gasBefore - gasleft();
        }

        // Fast flow warm (turn 2)
        {
            bytes32 aliceMoveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, bytes32(uint256(100)), uint240(0)));
            bytes memory aliceSignature = _signCommit(ALICE_PK, aliceMoveHash, battleKey2, 2);

            vm.startPrank(bob);
            uint256 gasBefore = gasleft();
            fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
                battleKey2, aliceMoveHash, aliceSignature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
            );
            gasUsed_fastFlow_warm_signedCommitReveal = gasBefore - gasleft();

            vm.startPrank(alice);
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

    function _completeTurnNormal(bytes32 battleKey, uint256 turnId) internal {
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        bytes32 salt = bytes32(turnId + 1);
        bytes32 moveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, salt, uint240(0)));

        if (turnId % 2 == 0) {
            // Alice commits
            vm.startPrank(alice);
            fastCommitManager.commitMove(battleKey, moveHash);
            vm.startPrank(bob);
            fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(0), 0, false);
            vm.startPrank(alice);
            fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, salt, 0, true);
        } else {
            // Bob commits
            vm.startPrank(bob);
            fastCommitManager.commitMove(battleKey, moveHash);
            vm.startPrank(alice);
            fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(0), 0, false);
            vm.startPrank(bob);
            fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, salt, 0, true);
        }
    }

    function _completeTurnFast(bytes32 battleKey, uint256 turnId) internal {
        address alice = vm.addr(ALICE_PK);
        address bob = vm.addr(BOB_PK);

        bytes32 salt = bytes32(turnId + 1);
        bytes32 moveHash = keccak256(abi.encodePacked(NO_OP_MOVE_INDEX, salt, uint240(0)));

        if (turnId % 2 == 0) {
            // Alice commits via signature
            bytes memory signature = _signCommit(ALICE_PK, moveHash, battleKey, uint64(turnId));
            vm.startPrank(bob);
            fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
                battleKey, moveHash, signature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
            );
            vm.startPrank(alice);
            fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, salt, 0, true);
        } else {
            // Bob commits via signature
            bytes memory signature = _signCommit(BOB_PK, moveHash, battleKey, uint64(turnId));
            vm.startPrank(alice);
            fastCommitManager.revealMoveWithOtherPlayerSignedCommit(
                battleKey, moveHash, signature, NO_OP_MOVE_INDEX, bytes32(0), 0, false
            );
            vm.startPrank(bob);
            fastCommitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, salt, 0, true);
        }
    }
}
