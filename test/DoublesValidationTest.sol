// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {BaseCommitManager} from "../src/BaseCommitManager.sol";
import {DoublesCommitManager} from "../src/DoublesCommitManager.sol";
import {DefaultCommitManager} from "../src/DefaultCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {DoublesTargetedAttack} from "./mocks/DoublesTargetedAttack.sol";
import {ForceSwitchMove} from "./mocks/ForceSwitchMove.sol";
import {DoublesForceSwitchMove} from "./mocks/DoublesForceSwitchMove.sol";
import {DoublesEffectAttack} from "./mocks/DoublesEffectAttack.sol";
import {InstantDeathEffect} from "./mocks/InstantDeathEffect.sol";
import {MonIndexTrackingEffect} from "./mocks/MonIndexTrackingEffect.sol";
import {AfterDamageReboundEffect} from "./mocks/AfterDamageReboundEffect.sol";
import {EffectApplyingAttack} from "./mocks/EffectApplyingAttack.sol";
import {IEffect} from "../src/effects/IEffect.sol";

/**
 * @title DoublesValidationTest
 * @notice Tests for doubles battle validation boundary conditions
 * @dev Tests scenarios:
 *      - One player has 1 KO'd mon (with/without valid switch targets)
 *      - Both players have 1 KO'd mon each (various combinations)
 *      - Switch target validation (can't switch to other slot's active mon)
 *      - NO_OP allowed only when no valid switch targets
 */
contract DoublesValidationTest is Test {
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);

    DoublesCommitManager commitManager;
    Engine engine;
    DefaultValidator validator;
    ITypeCalculator typeCalc;
    DefaultRandomnessOracle defaultOracle;
    DefaultMatchmaker matchmaker;
    TestTeamRegistry defaultRegistry;
    CustomAttack customAttack;
    CustomAttack strongAttack;
    DoublesTargetedAttack targetedStrongAttack;

    uint256 constant TIMEOUT_DURATION = 100;

    function setUp() public {
        engine = new Engine();
        typeCalc = new TestTypeCalculator();
        defaultOracle = new DefaultRandomnessOracle();
        // Use 3 mons per team to test switch target scenarios
        validator = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 3, MOVES_PER_MON: 4, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );
        matchmaker = new DefaultMatchmaker(engine);
        commitManager = new DoublesCommitManager(engine);
        defaultRegistry = new TestTeamRegistry();

        customAttack = new CustomAttack(
            engine, typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 0})
        );
        strongAttack = new CustomAttack(
            engine, typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 200, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 0})
        );
        targetedStrongAttack = new DoublesTargetedAttack(
            engine, typeCalc, DoublesTargetedAttack.Args({TYPE: Type.Fire, BASE_POWER: 200, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 0})
        );

        // Register teams for Alice and Bob (3 mons for doubles with switch options)
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = customAttack;
        moves[1] = customAttack;
        moves[2] = customAttack;
        moves[3] = customAttack;

        Mon[] memory team = new Mon[](3);
        team[0] = _createMon(100, 10, moves);  // Mon 0: 100 HP, speed 10
        team[1] = _createMon(100, 8, moves);   // Mon 1: 100 HP, speed 8
        team[2] = _createMon(100, 6, moves);   // Mon 2: 100 HP, speed 6 (reserve)

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        // Authorize matchmaker
        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.stopPrank();

        vm.startPrank(BOB);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.stopPrank();
    }

    function _createMon(uint32 hp, uint32 speed, IMoveSet[] memory moves) internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: hp,
                stamina: 50,
                speed: speed,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            ability: IAbility(address(0)),
            moves: moves
        });
    }

    function _startDoublesBattle() internal returns (bytes32 battleKey) {
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = defaultRegistry.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker,
            gameMode: GameMode.Doubles
        });

        vm.startPrank(ALICE);
        battleKey = matchmaker.proposeBattle(proposal);

        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(BOB);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);

        vm.startPrank(ALICE);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);
        vm.stopPrank();
    }

    function _doublesCommitRevealExecute(
        bytes32 battleKey,
        uint8 aliceMove0, uint240 aliceExtra0,
        uint8 aliceMove1, uint240 aliceExtra1,
        uint8 bobMove0, uint240 bobExtra0,
        uint8 bobMove1, uint240 bobExtra1
    ) internal {
        uint256 turnId = engine.getTurnIdForBattleState(battleKey);
        bytes32 aliceSalt = bytes32("alicesalt");
        bytes32 bobSalt = bytes32("bobsalt");

        if (turnId % 2 == 0) {
            bytes32 aliceHash = keccak256(abi.encodePacked(aliceMove0, aliceExtra0, aliceMove1, aliceExtra1, aliceSalt));
            vm.startPrank(ALICE);
            commitManager.commitMoves(battleKey, aliceHash);
            vm.stopPrank();

            vm.startPrank(BOB);
            commitManager.revealMoves(battleKey, bobMove0, bobExtra0, bobMove1, bobExtra1, bobSalt, false);
            vm.stopPrank();

            vm.startPrank(ALICE);
            commitManager.revealMoves(battleKey, aliceMove0, aliceExtra0, aliceMove1, aliceExtra1, aliceSalt, false);
            vm.stopPrank();
        } else {
            bytes32 bobHash = keccak256(abi.encodePacked(bobMove0, bobExtra0, bobMove1, bobExtra1, bobSalt));
            vm.startPrank(BOB);
            commitManager.commitMoves(battleKey, bobHash);
            vm.stopPrank();

            vm.startPrank(ALICE);
            commitManager.revealMoves(battleKey, aliceMove0, aliceExtra0, aliceMove1, aliceExtra1, aliceSalt, false);
            vm.stopPrank();

            vm.startPrank(BOB);
            commitManager.revealMoves(battleKey, bobMove0, bobExtra0, bobMove1, bobExtra1, bobSalt, false);
            vm.stopPrank();
        }

        engine.execute(battleKey);
    }

    function _doInitialSwitch(bytes32 battleKey) internal {
        _doublesCommitRevealExecute(
            battleKey,
            SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1,
            SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1
        );
    }

    // =========================================
    // Direct Validator Tests
    // =========================================

    /**
     * @notice Test that on turn 0, only SWITCH_MOVE_INDEX is valid for all slots
     */
    function test_turn0_onlySwitchAllowed() public {
        bytes32 battleKey = _startDoublesBattle();

        // Turn 0: validatePlayerMoveForSlot should only accept SWITCH_MOVE_INDEX
        // Test slot 0
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 0), "SWITCH should be valid on turn 0");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, 0, 0, 0, 0), "Attack should be invalid on turn 0");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 0, 0), "NO_OP should be invalid on turn 0 (valid targets exist)");

        // Test slot 1
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 1, 1), "SWITCH should be valid on turn 0 slot 1");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, 0, 0, 1, 0), "Attack should be invalid on turn 0 slot 1");
    }

    /**
     * @notice Test that after initial switch, attacks are valid for non-KO'd mons
     */
    function test_afterTurn0_attacksAllowed() public {
        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Attacks should be valid
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, 0, 0, 0, 0), "Attack should be valid after turn 0");
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, 0, 0, 1, 0), "Attack should be valid for slot 1");
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 0, 0), "NO_OP should be valid");

        // Switch should also still be valid (to mon index 2, the reserve)
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 2), "Switch to reserve should be valid");
    }

    /**
     * @notice Test that switch to same mon is invalid (except turn 0)
     */
    function test_switchToSameMonInvalid() public {
        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Trying to switch slot 0 (which has mon 0) to mon 0 should fail
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 0), "Switch to same mon should be invalid");

        // Trying to switch slot 1 (which has mon 1) to mon 1 should fail
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 1, 1), "Switch to same mon should be invalid for slot 1");
    }

    /**
     * @notice Test that switch to mon active in other slot is invalid
     */
    function test_switchToOtherSlotActiveMonInvalid() public {
        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // After initial switch: slot 0 has mon 0, slot 1 has mon 1
        // Trying to switch slot 0 to mon 1 (active in slot 1) should fail
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 1), "Switch to other slot's active mon should be invalid");

        // Trying to switch slot 1 to mon 0 (active in slot 0) should fail
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 1, 0), "Switch to other slot's active mon should be invalid");

        // But switch to reserve mon (index 2) should be valid
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 2), "Switch to reserve should be valid");
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 1, 2), "Switch to reserve from slot 1 should be valid");
    }

    // =========================================
    // One Player Has 1 KO'd Mon Tests
    // =========================================

    /**
     * @notice Setup: Alice's slot 0 mon is KO'd, but she has a reserve mon to switch to
     *         Expected: Alice must switch slot 0, can use any move for slot 1
     */
    function test_onePlayerOneKO_withValidTarget() public {
        // Create teams where Alice's mon 0 has very low HP
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = strongAttack;
        moves[1] = strongAttack;
        moves[2] = strongAttack;
        moves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(1, 10, moves);   // Will be KO'd easily
        aliceTeam[1] = _createMon(100, 8, moves);
        aliceTeam[2] = _createMon(100, 6, moves);  // Reserve

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 20, moves);   // Faster to attack first
        bobTeam[1] = _createMon(100, 18, moves);
        bobTeam[2] = _createMon(100, 16, moves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Bob attacks Alice's slot 0, KO'ing it
        _doublesCommitRevealExecute(
            battleKey,
            0, 0, NO_OP_MOVE_INDEX, 0,  // Alice: slot 0 attacks, slot 1 no-op
            0, 0, NO_OP_MOVE_INDEX, 0   // Bob: slot 0 attacks (will KO Alice slot 0), slot 1 no-op
        );

        // Verify Alice's slot 0 mon is KO'd
        int32 isKO = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut);
        assertEq(isKO, 1, "Alice's mon 0 should be KO'd");

        // Now validate: Alice slot 0 must switch (to reserve mon 2)
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, 0, 0, 0, 0), "Attack should be invalid for KO'd slot");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 0, 0), "NO_OP should be invalid when valid switch exists");
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 2), "Switch to reserve should be valid");

        // Alice slot 1 can use any move (not KO'd)
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, 0, 0, 1, 0), "Attack should be valid for non-KO'd slot");
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 1, 0), "NO_OP should be valid for non-KO'd slot");

        // Bob's slots should be able to use any move
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, 0, 1, 0, 0), "Bob slot 0 attack should be valid");
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, 0, 1, 1, 0), "Bob slot 1 attack should be valid");
    }

    /**
     * @notice Setup: Alice's slot 0 mon is KO'd, and her only other mon is in slot 1 (no reserve)
     *         Expected: Alice can use NO_OP for slot 0 since no valid switch target
     */
    function test_onePlayerOneKO_noValidTarget() public {
        // Use only 2 mons per team for this test
        DefaultValidator validator2Mon = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 4, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );
        DoublesCommitManager commitManager2 = new DoublesCommitManager(engine);
        TestTeamRegistry registry2 = new TestTeamRegistry();

        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = strongAttack;
        moves[1] = strongAttack;
        moves[2] = strongAttack;
        moves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = _createMon(1, 10, moves);   // Will be KO'd
        aliceTeam[1] = _createMon(100, 8, moves);  // Active in slot 1

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = _createMon(100, 20, moves);
        bobTeam[1] = _createMon(100, 18, moves);

        registry2.setTeam(ALICE, aliceTeam);
        registry2.setTeam(BOB, bobTeam);

        // Start battle with 2-mon validator
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = registry2.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: registry2,
            validator: validator2Mon,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager2),
            matchmaker: matchmaker,
            gameMode: GameMode.Doubles
        });

        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(BOB);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);
        vm.startPrank(ALICE);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        // Turn 0: Initial switch
        {
            uint256 turnId = engine.getTurnIdForBattleState(battleKey);
            bytes32 aliceSalt = bytes32("alicesalt");
            bytes32 bobSalt = bytes32("bobsalt");
            bytes32 aliceHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint240(0), SWITCH_MOVE_INDEX, uint240(1), aliceSalt));
            vm.startPrank(ALICE);
            commitManager2.commitMoves(battleKey, aliceHash);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager2.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, bobSalt, false);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager2.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, aliceSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Turn 1: Bob KOs Alice's slot 0
        {
            bytes32 aliceSalt = bytes32("alicesalt2");
            bytes32 bobSalt = bytes32("bobsalt2");
            bytes32 bobHash = keccak256(abi.encodePacked(uint8(0), uint240(0), uint8(NO_OP_MOVE_INDEX), uint240(0), bobSalt));
            vm.startPrank(BOB);
            commitManager2.commitMoves(battleKey, bobHash);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager2.revealMoves(battleKey, uint8(0), 0, uint8(NO_OP_MOVE_INDEX), 0, aliceSalt, false);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager2.revealMoves(battleKey, uint8(0), 0, uint8(NO_OP_MOVE_INDEX), 0, bobSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Verify Alice's mon 0 is KO'd
        int32 isKO = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut);
        assertEq(isKO, 1, "Alice's mon 0 should be KO'd");

        // Now Alice's slot 0 is KO'd, and slot 1 has mon 1
        // There's no valid switch target (mon 0 is KO'd, mon 1 is in other slot)
        // Therefore NO_OP should be valid
        assertTrue(validator2Mon.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 0, 0), "NO_OP should be valid when no switch targets");
        assertFalse(validator2Mon.validatePlayerMoveForSlot(battleKey, 0, 0, 0, 0), "Attack should be invalid for KO'd slot");
        assertFalse(validator2Mon.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 1), "Can't switch to other slot's mon");
    }

    // =========================================
    // Both Players Have 1 KO'd Mon Tests
    // =========================================

    /**
     * @notice Setup: Both Alice and Bob have their slot 0 mons KO'd, both have reserves
     *         Expected: Both must switch their slot 0
     */
    function test_bothPlayersOneKO_bothHaveValidTargets() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = strongAttack;
        moves[1] = strongAttack;
        moves[2] = strongAttack;
        moves[3] = strongAttack;

        // Both teams have weak slot 0 mons, and fast slot 1 mons that will KO opponent's slot 0
        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(1, 5, moves);     // Weak, slow - will be KO'd
        aliceTeam[1] = _createMon(100, 20, moves);  // Fast - attacks first
        aliceTeam[2] = _createMon(100, 6, moves);   // Reserve

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(1, 5, moves);       // Weak, slow - will be KO'd
        bobTeam[1] = _createMon(100, 18, moves);    // Fast - attacks second
        bobTeam[2] = _createMon(100, 6, moves);     // Reserve

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Slot 1 mons attack opponent's slot 0 (default targeting), KO'ing both slot 0s
        // Order: Alice slot 1 (speed 20) → Bob slot 1 (speed 18) → both slot 0s too slow to matter
        _doublesCommitRevealExecute(
            battleKey,
            NO_OP_MOVE_INDEX, 0, 0, 0,  // Alice: slot 0 no-op, slot 1 attacks
            NO_OP_MOVE_INDEX, 0, 0, 0   // Bob: slot 0 no-op, slot 1 attacks
        );

        // Verify both slot 0 mons are KO'd
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 1, "Bob mon 0 KO'd");

        // Both must switch slot 0 to reserve (mon 2)
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 2), "Alice must switch to reserve");
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 1, 0, 2), "Bob must switch to reserve");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, 0, 0, 0, 0), "Alice attack invalid");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, 0, 1, 0, 0), "Bob attack invalid");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 0, 0), "Alice NO_OP invalid (has target)");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 1, 0, 0), "Bob NO_OP invalid (has target)");

        // Slot 1 for both can use any move
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, 0, 0, 1, 0), "Alice slot 1 attack valid");
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, 0, 1, 1, 0), "Bob slot 1 attack valid");
    }

    /**
     * @notice Setup: Both players have slot 0 KO'd, only 2 mons per team (no reserve)
     *         Expected: Both can use NO_OP for slot 0
     */
    function test_bothPlayersOneKO_neitherHasValidTarget() public {
        // Use 2-mon teams
        DefaultValidator validator2Mon = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 4, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );
        DoublesCommitManager commitManager2 = new DoublesCommitManager(engine);
        TestTeamRegistry registry2 = new TestTeamRegistry();

        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = strongAttack;
        moves[1] = strongAttack;
        moves[2] = strongAttack;
        moves[3] = strongAttack;

        // Both teams: weak slot 0, fast slot 1 that will KO opponent's slot 0
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = _createMon(1, 5, moves);     // Will be KO'd
        aliceTeam[1] = _createMon(100, 20, moves);  // Fast, attacks first

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = _createMon(1, 5, moves);       // Will be KO'd
        bobTeam[1] = _createMon(100, 18, moves);    // Fast, attacks second

        registry2.setTeam(ALICE, aliceTeam);
        registry2.setTeam(BOB, bobTeam);

        // Start battle
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = registry2.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: registry2,
            validator: validator2Mon,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager2),
            matchmaker: matchmaker,
            gameMode: GameMode.Doubles
        });

        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(BOB);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);
        vm.startPrank(ALICE);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        // Turn 0: Initial switch
        {
            bytes32 aliceSalt = bytes32("as");
            bytes32 bobSalt = bytes32("bs");
            bytes32 aliceHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint240(0), SWITCH_MOVE_INDEX, uint240(1), aliceSalt));
            vm.startPrank(ALICE);
            commitManager2.commitMoves(battleKey, aliceHash);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager2.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, bobSalt, false);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager2.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, aliceSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Turn 1: Both slot 1 mons attack opponent's slot 0, KO'ing both
        {
            bytes32 aliceSalt = bytes32("as2");
            bytes32 bobSalt = bytes32("bs2");
            bytes32 bobHash = keccak256(abi.encodePacked(uint8(NO_OP_MOVE_INDEX), uint240(0), uint8(0), uint240(0), bobSalt));
            vm.startPrank(BOB);
            commitManager2.commitMoves(battleKey, bobHash);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager2.revealMoves(battleKey, uint8(NO_OP_MOVE_INDEX), 0, uint8(0), 0, aliceSalt, false);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager2.revealMoves(battleKey, uint8(NO_OP_MOVE_INDEX), 0, uint8(0), 0, bobSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Verify both slot 0 mons KO'd
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 1, "Bob mon 0 KO'd");

        // Both should be able to NO_OP slot 0 (no valid switch targets)
        assertTrue(validator2Mon.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 0, 0), "Alice NO_OP valid");
        assertTrue(validator2Mon.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 1, 0, 0), "Bob NO_OP valid");

        // Attacks still invalid for KO'd slot
        assertFalse(validator2Mon.validatePlayerMoveForSlot(battleKey, 0, 0, 0, 0), "Alice attack invalid");
        assertFalse(validator2Mon.validatePlayerMoveForSlot(battleKey, 0, 1, 0, 0), "Bob attack invalid");

        // Can't switch to other slot's mon
        assertFalse(validator2Mon.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 1), "Alice can't switch to slot 1 mon");
        assertFalse(validator2Mon.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 1, 0, 1), "Bob can't switch to slot 1 mon");

        // Slot 1 can still attack
        assertTrue(validator2Mon.validatePlayerMoveForSlot(battleKey, 0, 0, 1, 0), "Alice slot 1 attack valid");
        assertTrue(validator2Mon.validatePlayerMoveForSlot(battleKey, 0, 1, 1, 0), "Bob slot 1 attack valid");
    }

    // =========================================
    // Integration Test: Full Flow with KO and Forced Switch
    // =========================================

    /**
     * @notice Full integration test: Verify validation rejects attack for KO'd slot with valid targets
     *         And accepts switch to reserve
     */
    function test_fullFlow_KOAndForcedSwitch() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = strongAttack;
        moves[1] = strongAttack;
        moves[2] = strongAttack;
        moves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(1, 5, moves);     // Will be KO'd (slow)
        aliceTeam[1] = _createMon(100, 8, moves);
        aliceTeam[2] = _createMon(100, 6, moves);   // Reserve

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 20, moves);    // Fast - attacks first
        bobTeam[1] = _createMon(100, 18, moves);
        bobTeam[2] = _createMon(100, 16, moves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);

        // Turn 0: Initial switch
        _doInitialSwitch(battleKey);
        assertEq(engine.getTurnIdForBattleState(battleKey), 1);

        // Turn 1: Bob KOs Alice's slot 0
        _doublesCommitRevealExecute(
            battleKey,
            NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0,  // Alice: both no-op
            0, 0, NO_OP_MOVE_INDEX, 0                   // Bob: slot 0 attacks Alice's slot 0
        );

        // Verify turn advanced and mon is KO'd
        assertEq(engine.getTurnIdForBattleState(battleKey), 2);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");

        // Verify validation state after KO:
        // - Alice slot 0: must switch (attack invalid, NO_OP invalid since reserve exists)
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, 0, 0, 0, 0), "Attack invalid for KO'd slot");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 0, 0), "NO_OP invalid (reserve exists)");
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 2), "Switch to reserve valid");

        // - Alice slot 1: can use any move
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, 0, 0, 1, 0), "Alice slot 1 attack valid");

        // - Bob: both slots can use any move
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, 0, 1, 0, 0), "Bob slot 0 attack valid");
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, 0, 1, 1, 0), "Bob slot 1 attack valid");

        // Game should still be ongoing
        assertEq(engine.getWinner(battleKey), address(0));
    }

    /**
     * @notice Test that reveal fails when trying to use attack for KO'd slot with valid targets
     * @dev After KO with valid switch target, it's a single-player switch turn (Alice only)
     */
    function test_revealFailsForInvalidMoveOnKOdSlot() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = strongAttack;
        moves[1] = strongAttack;
        moves[2] = strongAttack;
        moves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(1, 5, moves);     // Slow, will be KO'd
        aliceTeam[1] = _createMon(100, 8, moves);
        aliceTeam[2] = _createMon(100, 6, moves);   // Reserve

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 20, moves);    // Fast, attacks first
        bobTeam[1] = _createMon(100, 18, moves);
        bobTeam[2] = _createMon(100, 16, moves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Bob KOs Alice's slot 0
        _doublesCommitRevealExecute(
            battleKey,
            NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0,  // Alice: both no-op
            0, 0, NO_OP_MOVE_INDEX, 0                   // Bob: slot 0 attacks
        );

        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");

        // Verify it's a single-player switch turn (playerSwitchForTurnFlag = 0 for Alice only)
        BattleContext memory ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 0, "Should be Alice-only switch turn");

        // Turn 2: Single-player switch turn - only Alice acts (no commits needed)
        // Alice tries to reveal with attack for KO'd slot 0 - should fail with InvalidMove
        bytes32 aliceSalt = bytes32("alicesalt");

        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DoublesCommitManager.InvalidMove.selector, ALICE, 0));
        commitManager.revealMoves(battleKey, uint8(0), 0, uint8(NO_OP_MOVE_INDEX), 0, aliceSalt, false);
        vm.stopPrank();
    }

    /**
     * @notice Test single-player switch turn: only the player with KO'd mon acts
     */
    function test_singlePlayerSwitchTurn() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = strongAttack;
        moves[1] = strongAttack;
        moves[2] = strongAttack;
        moves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(1, 5, moves);     // Slow, will be KO'd
        aliceTeam[1] = _createMon(100, 8, moves);
        aliceTeam[2] = _createMon(100, 6, moves);   // Reserve

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 20, moves);    // Fast
        bobTeam[1] = _createMon(100, 18, moves);
        bobTeam[2] = _createMon(100, 16, moves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Bob KOs Alice's slot 0
        _doublesCommitRevealExecute(
            battleKey,
            NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0,
            0, 0, NO_OP_MOVE_INDEX, 0
        );

        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");

        // Verify it's a single-player switch turn
        BattleContext memory ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 0, "Should be Alice-only switch turn");

        // Bob should NOT be able to commit (it's not his turn)
        vm.startPrank(BOB);
        bytes32 bobHash = keccak256(abi.encodePacked(uint8(0), uint240(0), uint8(0), uint240(0), bytes32("bobsalt")));
        vm.expectRevert(BaseCommitManager.PlayerNotAllowed.selector);
        commitManager.commitMoves(battleKey, bobHash);
        vm.stopPrank();

        // Alice reveals her switch (no commit needed for single-player turns)
        bytes32 aliceSalt = bytes32("alicesalt");
        vm.startPrank(ALICE);
        commitManager.revealMoves(battleKey, SWITCH_MOVE_INDEX, 2, NO_OP_MOVE_INDEX, 0, aliceSalt, true);
        vm.stopPrank();

        // Verify switch happened and turn advanced
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 0), 2, "Alice slot 0 should now have mon 2");
        assertEq(engine.getTurnIdForBattleState(battleKey), 3);

        // Next turn should be normal (both players act)
        ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 2, "Should be normal turn now");
    }

    /**
     * @notice Test mixed switch + attack during single-player switch turn
     * @dev When slot 0 is KO'd, slot 1 can attack while slot 0 switches
     */
    function test_singlePlayerSwitchTurn_withAttack() public {
        // Use targeted attack for slot 1 so we can target specific opponent slot
        IMoveSet[] memory aliceMoves = new IMoveSet[](4);
        aliceMoves[0] = targetedStrongAttack;
        aliceMoves[1] = targetedStrongAttack;
        aliceMoves[2] = targetedStrongAttack;
        aliceMoves[3] = targetedStrongAttack;

        IMoveSet[] memory bobMoves = new IMoveSet[](4);
        bobMoves[0] = strongAttack;
        bobMoves[1] = strongAttack;
        bobMoves[2] = strongAttack;
        bobMoves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(1, 5, aliceMoves);     // Slow, will be KO'd
        aliceTeam[1] = _createMon(100, 15, aliceMoves);  // Alive, can attack with targeted move
        aliceTeam[2] = _createMon(100, 6, aliceMoves);   // Reserve

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 20, bobMoves);    // Fast, KOs Alice slot 0
        bobTeam[1] = _createMon(500, 18, bobMoves);    // High HP - will take damage but survive
        bobTeam[2] = _createMon(100, 16, bobMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Bob KOs Alice's slot 0
        _doublesCommitRevealExecute(
            battleKey,
            NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0,
            0, 0, NO_OP_MOVE_INDEX, 0
        );

        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");

        // Verify it's a single-player switch turn
        BattleContext memory ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 0, "Should be Alice-only switch turn");

        // Record Bob's slot 1 HP before Alice's attack
        int32 bobSlot1HpBefore = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp);

        // Alice: slot 0 switches to reserve (mon 2), slot 1 attacks Bob's slot 1
        // For DoublesTargetedAttack, extraData=1 means target opponent slot 1
        bytes32 aliceSalt = bytes32("alicesalt");
        vm.startPrank(ALICE);
        commitManager.revealMoves(battleKey, SWITCH_MOVE_INDEX, 2, 0, 1, aliceSalt, true);
        vm.stopPrank();

        // Verify switch happened
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 0), 2, "Alice slot 0 should now have mon 2");

        // Verify attack dealt damage to Bob's slot 1
        int32 bobSlot1HpAfter = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp);
        assertTrue(bobSlot1HpAfter < bobSlot1HpBefore, "Bob slot 1 should have taken damage from Alice's attack");

        // Turn advanced
        assertEq(engine.getTurnIdForBattleState(battleKey), 3);

        // Next turn should be normal
        ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 2, "Should be normal turn now");
    }

    // =========================================
    // P1-Only Switch Turn Tests (mirrors of P0)
    // =========================================

    /**
     * @notice Test P1-only switch turn: Bob's slot 0 KO'd with valid target
     * @dev Mirror of test_singlePlayerSwitchTurn but for P1
     */
    function test_p1OnlySwitchTurn_slot0KOWithValidTarget() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = strongAttack;
        moves[1] = strongAttack;
        moves[2] = strongAttack;
        moves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(100, 20, moves);   // Fast, attacks first
        aliceTeam[1] = _createMon(100, 18, moves);
        aliceTeam[2] = _createMon(100, 16, moves);

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(1, 5, moves);        // Slow, will be KO'd
        bobTeam[1] = _createMon(100, 8, moves);
        bobTeam[2] = _createMon(100, 6, moves);      // Reserve

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Alice KOs Bob's slot 0
        _doublesCommitRevealExecute(
            battleKey,
            0, 0, NO_OP_MOVE_INDEX, 0,              // Alice: slot 0 attacks Bob's slot 0
            NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0 // Bob: both no-op
        );

        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 1, "Bob mon 0 KO'd");

        // Verify it's a P1-only switch turn (flag=1)
        BattleContext memory ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 1, "Should be Bob-only switch turn");

        // Alice should NOT be able to commit (it's not her turn)
        vm.startPrank(ALICE);
        bytes32 aliceHash = keccak256(abi.encodePacked(uint8(0), uint240(0), uint8(0), uint240(0), bytes32("alicesalt")));
        vm.expectRevert(BaseCommitManager.PlayerNotAllowed.selector);
        commitManager.commitMoves(battleKey, aliceHash);
        vm.stopPrank();

        // Bob reveals his switch (no commit needed for single-player turns)
        bytes32 bobSalt = bytes32("bobsalt");
        vm.startPrank(BOB);
        commitManager.revealMoves(battleKey, SWITCH_MOVE_INDEX, 2, NO_OP_MOVE_INDEX, 0, bobSalt, true);
        vm.stopPrank();

        // Verify switch happened
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 1, 0), 2, "Bob slot 0 should now have mon 2");

        // Next turn should be normal
        ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 2, "Should be normal turn now");
    }

    /**
     * @notice Test P1 slot 0 KO'd without valid target (2-mon team)
     * @dev Mirror of test_onePlayerOneKO_noValidTarget but for P1
     */
    function test_p1OneKO_noValidTarget() public {
        // Use 2-mon teams
        DefaultValidator validator2Mon = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 4, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );
        DoublesCommitManager commitManager2 = new DoublesCommitManager(engine);
        TestTeamRegistry registry2 = new TestTeamRegistry();

        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = strongAttack;
        moves[1] = strongAttack;
        moves[2] = strongAttack;
        moves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = _createMon(100, 20, moves);   // Fast, attacks first
        aliceTeam[1] = _createMon(100, 18, moves);

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = _createMon(1, 5, moves);        // Will be KO'd
        bobTeam[1] = _createMon(100, 8, moves);      // Active in slot 1

        registry2.setTeam(ALICE, aliceTeam);
        registry2.setTeam(BOB, bobTeam);

        // Start battle
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = registry2.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: registry2,
            validator: validator2Mon,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager2),
            matchmaker: matchmaker,
            gameMode: GameMode.Doubles
        });

        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(BOB);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);
        vm.startPrank(ALICE);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        // Turn 0: Initial switch
        {
            bytes32 aliceSalt = bytes32("as");
            bytes32 bobSalt = bytes32("bs");
            bytes32 aliceHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint240(0), SWITCH_MOVE_INDEX, uint240(1), aliceSalt));
            vm.startPrank(ALICE);
            commitManager2.commitMoves(battleKey, aliceHash);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager2.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, bobSalt, false);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager2.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, aliceSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Turn 1: Alice KOs Bob's slot 0
        {
            bytes32 aliceSalt = bytes32("as2");
            bytes32 bobSalt = bytes32("bs2");
            bytes32 bobHash = keccak256(abi.encodePacked(uint8(NO_OP_MOVE_INDEX), uint240(0), uint8(NO_OP_MOVE_INDEX), uint240(0), bobSalt));
            vm.startPrank(BOB);
            commitManager2.commitMoves(battleKey, bobHash);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager2.revealMoves(battleKey, uint8(0), 0, uint8(NO_OP_MOVE_INDEX), 0, aliceSalt, false);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager2.revealMoves(battleKey, uint8(NO_OP_MOVE_INDEX), 0, uint8(NO_OP_MOVE_INDEX), 0, bobSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Verify Bob's mon 0 is KO'd
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 1, "Bob mon 0 KO'd");

        // Bob has no valid switch target (mon 1 is in slot 1, mon 0 is KO'd)
        // So NO_OP should be valid for Bob's slot 0, and it's a normal turn
        BattleContext memory ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 2, "Should be normal turn (Bob has no valid target)");

        assertTrue(validator2Mon.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 1, 0, 0), "Bob NO_OP valid for KO'd slot");
        assertFalse(validator2Mon.validatePlayerMoveForSlot(battleKey, 0, 1, 0, 0), "Bob attack invalid for KO'd slot");
        assertTrue(validator2Mon.validatePlayerMoveForSlot(battleKey, 0, 1, 1, 0), "Bob slot 1 attack valid");
    }

    // =========================================
    // Asymmetric Switch Target Tests
    // =========================================

    /**
     * @notice Test: P0 has KO'd slot WITH valid target, P1 has KO'd slot WITHOUT valid target
     * @dev Uses 3-mon teams for both, but KOs P1's reserve first so P1 has no valid target
     *      when the asymmetric situation occurs
     */
    function test_asymmetric_p0HasTarget_p1NoTarget() public {
        // Use targeted attacks
        IMoveSet[] memory targetedMoves = new IMoveSet[](4);
        targetedMoves[0] = targetedStrongAttack;
        targetedMoves[1] = targetedStrongAttack;
        targetedMoves[2] = targetedStrongAttack;
        targetedMoves[3] = targetedStrongAttack;

        IMoveSet[] memory regularMoves = new IMoveSet[](4);
        regularMoves[0] = strongAttack;
        regularMoves[1] = strongAttack;
        regularMoves[2] = strongAttack;
        regularMoves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(1, 5, regularMoves);      // Weak - will be KO'd on turn 2
        aliceTeam[1] = _createMon(100, 30, targetedMoves);  // Very fast, with targeting
        aliceTeam[2] = _createMon(100, 6, regularMoves);    // Reserve

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 5, regularMoves);      // Slow but sturdy
        bobTeam[1] = _createMon(100, 25, targetedMoves);    // Fast, with targeting
        bobTeam[2] = _createMon(1, 1, regularMoves);        // Weak reserve - will be KO'd first

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Alice slot 1 KOs Bob slot 0
        _doublesCommitRevealExecute(
            battleKey,
            NO_OP_MOVE_INDEX, 0, 0, 0,  // Alice: slot 0 no-op, slot 1 attacks Bob slot 0
            NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0   // Bob: both no-op
        );

        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 1, "Bob mon 0 KO'd");

        // Bob-only switch turn (he has reserve mon 2)
        BattleContext memory ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 1, "Should be Bob-only switch turn");

        // Bob switches to reserve
        vm.startPrank(BOB);
        commitManager.revealMoves(battleKey, SWITCH_MOVE_INDEX, 2, NO_OP_MOVE_INDEX, 0, bytes32("bobsalt"), true);
        vm.stopPrank();

        // Now Bob slot 0 = mon 2 (weak reserve)
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 1, 0), 2, "Bob slot 0 should have mon 2");

        // Turn 2: Alice KOs Bob's mon 2 (slot 0), Bob slot 1 KOs Alice's mon 0 (slot 0)
        // Bob slot 1 (speed 25) is faster than Bob slot 0 (mon 2, speed 1)
        // So Bob slot 1 should attack Alice slot 0 before Bob slot 0 is KO'd
        _doublesCommitRevealExecute(
            battleKey,
            NO_OP_MOVE_INDEX, 0, 0, 0,  // Alice: slot 0 no-op, slot 1 attacks Bob slot 0
            NO_OP_MOVE_INDEX, 0, 0, 0   // Bob: slot 0 no-op, slot 1 attacks Alice slot 0
        );

        // Check KOs
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 2, MonStateIndexName.IsKnockedOut), 1, "Bob mon 2 KO'd");

        // Now the state is:
        // Alice: slot 0 has mon 0 (KO'd), slot 1 has mon 1 (alive), reserve mon 2 (alive) -> CAN switch
        // Bob: slot 0 has mon 2 (KO'd), slot 1 has mon 1 (alive), mon 0 (KO'd) -> CANNOT switch

        // Should be P0-only switch turn
        ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 0, "Should be Alice-only switch turn (Bob has no valid target)");

        // Verify Bob can NO_OP his KO'd slot
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 1, 0, 0), "Bob NO_OP valid for KO'd slot");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 1, 0, 1), "Bob can't switch to slot 1's mon");

        // Alice must switch
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 2), "Alice must switch to reserve");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 0, 0), "Alice NO_OP invalid (has target)");
    }

    /**
     * @notice Test: P0 has KO'd slot WITHOUT valid target, P1 has KO'd slot WITH valid target
     * @dev Mirror of above - should be P1-only switch turn
     */
    function test_asymmetric_p0NoTarget_p1HasTarget() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = strongAttack;
        moves[1] = strongAttack;
        moves[2] = strongAttack;
        moves[3] = strongAttack;

        // Mirror setup: Alice has weak reserve, Bob has strong reserve
        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(100, 5, moves);    // Slow but sturdy
        aliceTeam[1] = _createMon(100, 25, moves);   // Fast
        aliceTeam[2] = _createMon(1, 1, moves);      // Weak reserve - will be KO'd first

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(1, 5, moves);        // Weak - will be KO'd on turn 2
        bobTeam[1] = _createMon(100, 30, moves);     // Very fast
        bobTeam[2] = _createMon(100, 6, moves);      // Reserve

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Bob slot 1 KOs Alice slot 0
        _doublesCommitRevealExecute(
            battleKey,
            NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0,
            NO_OP_MOVE_INDEX, 0, 0, 0   // Bob slot 1 attacks Alice slot 0
        );

        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");

        // Alice-only switch turn (she has reserve mon 2)
        BattleContext memory ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 0, "Should be Alice-only switch turn");

        // Alice switches to reserve
        vm.startPrank(ALICE);
        commitManager.revealMoves(battleKey, SWITCH_MOVE_INDEX, 2, NO_OP_MOVE_INDEX, 0, bytes32("alicesalt"), true);
        vm.stopPrank();

        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 0), 2, "Alice slot 0 should have mon 2");

        // Turn 2: Bob KOs Alice's mon 2 (now in slot 0), Alice KOs Bob's mon 0
        _doublesCommitRevealExecute(
            battleKey,
            NO_OP_MOVE_INDEX, 0, 0, 0,  // Alice: slot 0 no-op, slot 1 attacks Bob slot 0
            NO_OP_MOVE_INDEX, 0, 0, 0   // Bob: slot 0 no-op, slot 1 attacks Alice slot 0
        );

        // Check KOs
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 1, "Bob mon 0 KO'd");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 2, MonStateIndexName.IsKnockedOut), 1, "Alice mon 2 KO'd");

        // Now:
        // Alice: slot 0 has mon 2 (KO'd), slot 1 has mon 1 (alive), mon 0 (KO'd) -> CANNOT switch
        // Bob: slot 0 has mon 0 (KO'd), slot 1 has mon 1 (alive), reserve mon 2 (alive) -> CAN switch

        // Should be P1-only switch turn
        ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 1, "Should be Bob-only switch turn (Alice has no valid target)");

        // Verify Alice can NO_OP her KO'd slot
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 0, 0), "Alice NO_OP valid for KO'd slot");

        // Bob must switch
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 1, 0, 2), "Bob must switch to reserve");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 1, 0, 0), "Bob NO_OP invalid (has target)");
    }

    // =========================================
    // Slot 1 KO'd Tests
    // =========================================

    /**
     * @notice Test: P0 slot 1 KO'd (slot 0 alive) with valid target
     * @dev Verifies slot 1 KO handling works the same as slot 0
     */
    function test_slot1KO_withValidTarget() public {
        // Use targeted attack for Bob so he can hit slot 1
        IMoveSet[] memory targetedMoves = new IMoveSet[](4);
        targetedMoves[0] = targetedStrongAttack;
        targetedMoves[1] = targetedStrongAttack;
        targetedMoves[2] = targetedStrongAttack;
        targetedMoves[3] = targetedStrongAttack;

        IMoveSet[] memory regularMoves = new IMoveSet[](4);
        regularMoves[0] = strongAttack;
        regularMoves[1] = strongAttack;
        regularMoves[2] = strongAttack;
        regularMoves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(100, 10, regularMoves);   // Healthy
        aliceTeam[1] = _createMon(1, 5, regularMoves);      // Weak - will be KO'd
        aliceTeam[2] = _createMon(100, 6, regularMoves);    // Reserve

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 20, targetedMoves);    // Fast, with targeted attack
        bobTeam[1] = _createMon(100, 25, targetedMoves);    // Faster
        bobTeam[2] = _createMon(100, 16, targetedMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Bob slot 0 attacks Alice slot 1 (extraData=1 for target slot 1)
        _doublesCommitRevealExecute(
            battleKey,
            NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0,  // Alice: both no-op
            0, 1, NO_OP_MOVE_INDEX, 0                   // Bob: slot 0 attacks Alice slot 1 (extraData=1)
        );

        // Check if Alice slot 1 is KO'd
        assertEq(engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.IsKnockedOut), 1, "Alice mon 1 (slot 1) KO'd");

        // Should be Alice-only switch turn
        BattleContext memory ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 0, "Should be Alice-only switch turn");

        // Alice must switch slot 1 to reserve
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 1, 2), "Alice must switch slot 1 to reserve");
        assertFalse(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 1, 0), "Alice NO_OP invalid for slot 1 (has target)");

        // Alice slot 0 can do anything (not KO'd)
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, 0, 0, 0, 0), "Alice slot 0 can attack");
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 0, 0), "Alice slot 0 can NO_OP");
    }

    // =========================================
    // Both Slots KO'd Tests
    // =========================================

    /**
     * @notice Test: P0 both slots KO'd with only one reserve (3-mon team)
     * @dev When both slots try to switch to same mon, second switch becomes NO_OP.
     *      Slot 0 switches to mon 2, slot 1 keeps KO'd mon 1 (plays with one mon).
     */
    function test_bothSlotsKO_oneReserve() public {
        // Use targeted attacks for Bob
        IMoveSet[] memory targetedMoves = new IMoveSet[](4);
        targetedMoves[0] = targetedStrongAttack;
        targetedMoves[1] = targetedStrongAttack;
        targetedMoves[2] = targetedStrongAttack;
        targetedMoves[3] = targetedStrongAttack;

        IMoveSet[] memory regularMoves = new IMoveSet[](4);
        regularMoves[0] = strongAttack;
        regularMoves[1] = strongAttack;
        regularMoves[2] = strongAttack;
        regularMoves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(1, 5, regularMoves);      // Weak - will be KO'd
        aliceTeam[1] = _createMon(1, 4, regularMoves);      // Weak - will be KO'd
        aliceTeam[2] = _createMon(100, 6, regularMoves);    // Reserve

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 20, targetedMoves);    // Fast - attacks Alice slot 0
        bobTeam[1] = _createMon(100, 25, targetedMoves);    // Faster - attacks Alice slot 1
        bobTeam[2] = _createMon(100, 16, targetedMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Bob KOs both of Alice's active mons
        // Bob slot 0 attacks Alice slot 0 (extraData=0), Bob slot 1 attacks Alice slot 1 (extraData=1)
        _doublesCommitRevealExecute(
            battleKey,
            0, 0, 0, 0,  // Alice: both attack (can't NO_OP while alive)
            0, 0, 0, 1   // Bob: slot 0 attacks Alice slot 0, slot 1 attacks Alice slot 1
        );

        // Both Alice mons should be KO'd
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.IsKnockedOut), 1, "Alice mon 1 KO'd");

        // Key assertion: Alice should get a switch turn (she has at least one valid target)
        BattleContext memory ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 0, "Should be Alice-only switch turn");

        // Both slots see mon 2 as a valid switch target at validation time (individually)
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 2), "Alice slot 0 can switch to reserve");
        assertTrue(validator.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 1, 2), "Alice slot 1 can switch to reserve");

        // But both slots CANNOT switch to the same mon in the same reveal
        // Alice reveals: slot 0 switches to mon 2, slot 1 NO_OPs (no other valid target)
        vm.startPrank(ALICE);
        commitManager.revealMoves(battleKey, SWITCH_MOVE_INDEX, 2, NO_OP_MOVE_INDEX, 0, bytes32("alicesalt"), true);
        vm.stopPrank();

        // Slot 0 switches to mon 2
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 0), 2, "Alice slot 0 should have mon 2");

        // Slot 1 keeps its KO'd mon (mon 1) - no valid switch target after slot 0 takes the reserve
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 1), 1, "Alice slot 1 should keep mon 1 (NO_OP)");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.IsKnockedOut), 1, "Alice slot 1 mon is still KO'd");

        // Game continues - Alice plays with just one mon in slot 0
        ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 2, "Should be normal turn now");
    }

    /**
     * @notice Test: P0 both slots KO'd with 2 reserves (4-mon team)
     * @dev Both slots can switch to different reserves
     */
    function test_bothSlotsKO_twoReserves() public {
        // Need 4-mon validator
        DefaultValidator validator4Mon = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 4, MOVES_PER_MON: 4, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );
        DoublesCommitManager commitManager4 = new DoublesCommitManager(engine);
        TestTeamRegistry registry4 = new TestTeamRegistry();

        // Use targeted attacks for Bob
        IMoveSet[] memory targetedMoves = new IMoveSet[](4);
        targetedMoves[0] = targetedStrongAttack;
        targetedMoves[1] = targetedStrongAttack;
        targetedMoves[2] = targetedStrongAttack;
        targetedMoves[3] = targetedStrongAttack;

        IMoveSet[] memory regularMoves = new IMoveSet[](4);
        regularMoves[0] = strongAttack;
        regularMoves[1] = strongAttack;
        regularMoves[2] = strongAttack;
        regularMoves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](4);
        aliceTeam[0] = _createMon(1, 5, regularMoves);      // Weak - will be KO'd
        aliceTeam[1] = _createMon(1, 4, regularMoves);      // Weak - will be KO'd
        aliceTeam[2] = _createMon(100, 6, regularMoves);    // Reserve 1
        aliceTeam[3] = _createMon(100, 7, regularMoves);    // Reserve 2

        Mon[] memory bobTeam = new Mon[](4);
        bobTeam[0] = _createMon(100, 20, targetedMoves);
        bobTeam[1] = _createMon(100, 25, targetedMoves);
        bobTeam[2] = _createMon(100, 16, targetedMoves);
        bobTeam[3] = _createMon(100, 15, targetedMoves);

        registry4.setTeam(ALICE, aliceTeam);
        registry4.setTeam(BOB, bobTeam);

        // Start battle with 4-mon validator
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = registry4.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: registry4,
            validator: validator4Mon,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager4),
            matchmaker: matchmaker,
            gameMode: GameMode.Doubles
        });

        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(BOB);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);
        vm.startPrank(ALICE);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        // Turn 0: Initial switch
        {
            bytes32 aliceSalt = bytes32("as");
            bytes32 bobSalt = bytes32("bs");
            bytes32 aliceHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint240(0), SWITCH_MOVE_INDEX, uint240(1), aliceSalt));
            vm.startPrank(ALICE);
            commitManager4.commitMoves(battleKey, aliceHash);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager4.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, bobSalt, false);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager4.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, aliceSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Turn 1: Bob KOs both of Alice's active mons
        {
            bytes32 aliceSalt = bytes32("as2");
            bytes32 bobSalt = bytes32("bs2");
            bytes32 bobHash = keccak256(abi.encodePacked(uint8(0), uint240(0), uint8(0), uint240(1), bobSalt));
            vm.startPrank(BOB);
            commitManager4.commitMoves(battleKey, bobHash);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager4.revealMoves(battleKey, uint8(NO_OP_MOVE_INDEX), 0, uint8(NO_OP_MOVE_INDEX), 0, aliceSalt, false);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager4.revealMoves(battleKey, uint8(0), 0, uint8(0), 1, bobSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Both Alice mons should be KO'd
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.IsKnockedOut), 1, "Alice mon 1 KO'd");

        // Alice has 2 reserves, so both slots can switch
        BattleContext memory ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 0, "Should be Alice-only switch turn");

        // Both slots can switch to either reserve
        assertTrue(validator4Mon.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 2), "Slot 0 can switch to mon 2");
        assertTrue(validator4Mon.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 0, 3), "Slot 0 can switch to mon 3");
        assertTrue(validator4Mon.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 1, 2), "Slot 1 can switch to mon 2");
        assertTrue(validator4Mon.validatePlayerMoveForSlot(battleKey, SWITCH_MOVE_INDEX, 0, 1, 3), "Slot 1 can switch to mon 3");

        // Alice switches both slots to different reserves
        vm.startPrank(ALICE);
        commitManager4.revealMoves(battleKey, SWITCH_MOVE_INDEX, 2, SWITCH_MOVE_INDEX, 3, bytes32("alicesalt3"), true);
        vm.stopPrank();

        // Verify both slots switched
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 0), 2, "Alice slot 0 should have mon 2");
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 1), 3, "Alice slot 1 should have mon 3");

        // Normal turn resumes
        ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 2, "Should be normal turn now");
    }

    /**
     * @notice Test: Both slots KO'd, no reserves = Game Over
     */
    function test_bothSlotsKO_noReserves_gameOver() public {
        // Use 2-mon teams - if both are KO'd, game over
        DefaultValidator validator2Mon = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 4, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );
        DoublesCommitManager commitManager2 = new DoublesCommitManager(engine);
        TestTeamRegistry registry2 = new TestTeamRegistry();

        // Use targeted attacks for Bob
        IMoveSet[] memory targetedMoves = new IMoveSet[](4);
        targetedMoves[0] = targetedStrongAttack;
        targetedMoves[1] = targetedStrongAttack;
        targetedMoves[2] = targetedStrongAttack;
        targetedMoves[3] = targetedStrongAttack;

        IMoveSet[] memory regularMoves = new IMoveSet[](4);
        regularMoves[0] = strongAttack;
        regularMoves[1] = strongAttack;
        regularMoves[2] = strongAttack;
        regularMoves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = _createMon(1, 5, regularMoves);      // Weak - will be KO'd
        aliceTeam[1] = _createMon(1, 4, regularMoves);      // Weak - will be KO'd

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = _createMon(100, 20, targetedMoves);
        bobTeam[1] = _createMon(100, 25, targetedMoves);

        registry2.setTeam(ALICE, aliceTeam);
        registry2.setTeam(BOB, bobTeam);

        // Start battle
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = registry2.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: registry2,
            validator: validator2Mon,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager2),
            matchmaker: matchmaker,
            gameMode: GameMode.Doubles
        });

        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(BOB);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);
        vm.startPrank(ALICE);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        // Turn 0: Initial switch
        {
            bytes32 aliceSalt = bytes32("as");
            bytes32 bobSalt = bytes32("bs");
            bytes32 aliceHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint240(0), SWITCH_MOVE_INDEX, uint240(1), aliceSalt));
            vm.startPrank(ALICE);
            commitManager2.commitMoves(battleKey, aliceHash);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager2.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, bobSalt, false);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager2.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, aliceSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Turn 1: Bob KOs both of Alice's mons - game should end
        {
            bytes32 aliceSalt = bytes32("as2");
            bytes32 bobSalt = bytes32("bs2");
            bytes32 bobHash = keccak256(abi.encodePacked(uint8(0), uint240(0), uint8(0), uint240(1), bobSalt));
            vm.startPrank(BOB);
            commitManager2.commitMoves(battleKey, bobHash);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager2.revealMoves(battleKey, uint8(NO_OP_MOVE_INDEX), 0, uint8(NO_OP_MOVE_INDEX), 0, aliceSalt, false);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager2.revealMoves(battleKey, uint8(0), 0, uint8(0), 1, bobSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Game should be over, Bob wins
        assertEq(engine.getWinner(battleKey), BOB, "Bob should win");
    }

    /**
     * @notice Test: Continuing with one mon after slot is KO'd with no valid target
     * @dev Player should be able to keep playing with their remaining alive mon
     */
    function test_continueWithOneMon_afterKONoTarget() public {
        // Use 2-mon teams
        DefaultValidator validator2Mon = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 4, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );
        DoublesCommitManager commitManager2 = new DoublesCommitManager(engine);
        TestTeamRegistry registry2 = new TestTeamRegistry();

        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = strongAttack;
        moves[1] = strongAttack;
        moves[2] = strongAttack;
        moves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = _createMon(1, 5, moves);      // Weak - will be KO'd
        aliceTeam[1] = _createMon(100, 30, moves);   // Strong and fast

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = _createMon(100, 20, moves);
        bobTeam[1] = _createMon(100, 18, moves);

        registry2.setTeam(ALICE, aliceTeam);
        registry2.setTeam(BOB, bobTeam);

        // Start battle
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = registry2.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: registry2,
            validator: validator2Mon,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager2),
            matchmaker: matchmaker,
            gameMode: GameMode.Doubles
        });

        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(BOB);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);
        vm.startPrank(ALICE);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        // Turn 0: Initial switch
        {
            bytes32 aliceSalt = bytes32("as");
            bytes32 bobSalt = bytes32("bs");
            bytes32 aliceHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint240(0), SWITCH_MOVE_INDEX, uint240(1), aliceSalt));
            vm.startPrank(ALICE);
            commitManager2.commitMoves(battleKey, aliceHash);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager2.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, bobSalt, false);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager2.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, aliceSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Turn 1: Bob KOs Alice's slot 0
        {
            bytes32 aliceSalt = bytes32("as2");
            bytes32 bobSalt = bytes32("bs2");
            bytes32 bobHash = keccak256(abi.encodePacked(uint8(0), uint240(0), uint8(NO_OP_MOVE_INDEX), uint240(0), bobSalt));
            vm.startPrank(BOB);
            commitManager2.commitMoves(battleKey, bobHash);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager2.revealMoves(battleKey, uint8(NO_OP_MOVE_INDEX), 0, uint8(NO_OP_MOVE_INDEX), 0, aliceSalt, false);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager2.revealMoves(battleKey, uint8(0), 0, uint8(NO_OP_MOVE_INDEX), 0, bobSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Alice's mon 0 is KO'd, no valid switch target
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");

        // Should be normal turn (Alice has no valid switch target)
        BattleContext memory ctx = engine.getBattleContext(battleKey);
        assertEq(ctx.playerSwitchForTurnFlag, 2, "Should be normal turn");

        // Game should continue
        assertEq(engine.getWinner(battleKey), address(0), "Game should not be over");

        // Alice slot 0: must NO_OP (KO'd, no target)
        assertTrue(validator2Mon.validatePlayerMoveForSlot(battleKey, NO_OP_MOVE_INDEX, 0, 0, 0), "Alice slot 0 NO_OP valid");
        assertFalse(validator2Mon.validatePlayerMoveForSlot(battleKey, 0, 0, 0, 0), "Alice slot 0 attack invalid");

        // Alice slot 1: can attack normally
        assertTrue(validator2Mon.validatePlayerMoveForSlot(battleKey, 0, 0, 1, 0), "Alice slot 1 can attack");

        // Turn 2: Alice attacks with slot 1, Bob attacks
        {
            bytes32 aliceSalt = bytes32("as3");
            bytes32 bobSalt = bytes32("bs3");
            bytes32 aliceHash = keccak256(abi.encodePacked(uint8(NO_OP_MOVE_INDEX), uint240(0), uint8(0), uint240(0), aliceSalt));
            vm.startPrank(ALICE);
            commitManager2.commitMoves(battleKey, aliceHash);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager2.revealMoves(battleKey, uint8(0), 0, uint8(0), 0, bobSalt, false);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager2.revealMoves(battleKey, uint8(NO_OP_MOVE_INDEX), 0, uint8(0), 0, aliceSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Game should still be ongoing (Alice's slot 1 mon is strong)
        assertEq(engine.getWinner(battleKey), address(0), "Game should still be ongoing");

        // Verify Alice's slot 1 mon is still alive
        assertEq(engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.IsKnockedOut), 0, "Alice mon 1 should be alive");
    }

    // =========================================
    // Forced Switch Move Tests (Doubles)
    // =========================================

    /**
     * @notice Test: Force switch move cannot switch to mon already active in other slot
     * @dev Uses validateSwitch which should check both slots in doubles mode
     */
    function test_forceSwitchMove_cannotSwitchToOtherSlotActiveMon() public {
        // Create force switch move
        ForceSwitchMove forceSwitchMove = new ForceSwitchMove(
            engine, ForceSwitchMove.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 0})
        );

        IMoveSet[] memory movesWithForceSwitch = new IMoveSet[](4);
        movesWithForceSwitch[0] = forceSwitchMove;
        movesWithForceSwitch[1] = customAttack;
        movesWithForceSwitch[2] = customAttack;
        movesWithForceSwitch[3] = customAttack;

        IMoveSet[] memory regularMoves = new IMoveSet[](4);
        regularMoves[0] = customAttack;
        regularMoves[1] = customAttack;
        regularMoves[2] = customAttack;
        regularMoves[3] = customAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(100, 10, movesWithForceSwitch);  // Has force switch move
        aliceTeam[1] = _createMon(100, 10, regularMoves);
        aliceTeam[2] = _createMon(100, 10, regularMoves);          // Reserve

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 10, regularMoves);
        bobTeam[1] = _createMon(100, 10, regularMoves);
        bobTeam[2] = _createMon(100, 10, regularMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // After initial switch: Alice has mon 0 in slot 0, mon 1 in slot 1
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 0), 0, "Alice slot 0 has mon 0");
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 1), 1, "Alice slot 1 has mon 1");

        // validateSwitch should reject switching to mon 1 (already in slot 1)
        assertFalse(validator.validateSwitch(battleKey, 0, 1), "Should not allow switching to mon already in slot 1");

        // validateSwitch should allow switching to mon 2 (reserve)
        assertTrue(validator.validateSwitch(battleKey, 0, 2), "Should allow switching to reserve mon 2");
    }

    /**
     * @notice Test: validateSwitch rejects switching to slot 0's active mon
     * @dev Tests the other direction - can't switch to mon that's in slot 0
     */
    function test_forceSwitchMove_cannotSwitchToSlot0ActiveMon() public {
        IMoveSet[] memory regularMoves = new IMoveSet[](4);
        regularMoves[0] = customAttack;
        regularMoves[1] = customAttack;
        regularMoves[2] = customAttack;
        regularMoves[3] = customAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(100, 10, regularMoves);
        aliceTeam[1] = _createMon(100, 10, regularMoves);
        aliceTeam[2] = _createMon(100, 10, regularMoves);

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 10, regularMoves);
        bobTeam[1] = _createMon(100, 10, regularMoves);
        bobTeam[2] = _createMon(100, 10, regularMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // After initial switch: Alice has mon 0 in slot 0, mon 1 in slot 1
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 0), 0, "Alice slot 0 has mon 0");
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 1), 1, "Alice slot 1 has mon 1");

        // validateSwitch should reject switching to mon 0 (already in slot 0)
        assertFalse(validator.validateSwitch(battleKey, 0, 0), "Should not allow switching to mon already in slot 0");

        // validateSwitch should allow switching to mon 2 (reserve)
        assertTrue(validator.validateSwitch(battleKey, 0, 2), "Should allow switching to reserve mon 2");
    }

    /**
     * @notice Test: validateSwitch allows KO'd mon even if active (for replacement)
     * @dev When a slot's mon is KO'd, it's still in that slot but should be switchable away from
     */
    function test_validateSwitch_allowsKOdMonReplacement() public {
        // Use targeted attacks for Bob to KO Alice slot 0
        IMoveSet[] memory targetedMoves = new IMoveSet[](4);
        targetedMoves[0] = targetedStrongAttack;
        targetedMoves[1] = targetedStrongAttack;
        targetedMoves[2] = targetedStrongAttack;
        targetedMoves[3] = targetedStrongAttack;

        IMoveSet[] memory regularMoves = new IMoveSet[](4);
        regularMoves[0] = strongAttack;
        regularMoves[1] = strongAttack;
        regularMoves[2] = strongAttack;
        regularMoves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(1, 5, regularMoves);       // Weak - will be KO'd
        aliceTeam[1] = _createMon(100, 10, regularMoves);
        aliceTeam[2] = _createMon(100, 10, regularMoves);

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 20, targetedMoves);     // Fast - KOs Alice slot 0
        bobTeam[1] = _createMon(100, 10, targetedMoves);
        bobTeam[2] = _createMon(100, 10, targetedMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Bob KOs Alice's slot 0
        _doublesCommitRevealExecute(
            battleKey,
            0, 0, 0, 0,  // Alice: both attack
            0, 0, 0, 0   // Bob: slot 0 attacks Alice slot 0
        );

        // Alice mon 0 should be KO'd
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");

        // validateSwitch should NOT allow switching to KO'd mon 0
        assertFalse(validator.validateSwitch(battleKey, 0, 0), "Should not allow switching to KO'd mon");

        // validateSwitch should allow switching to reserve mon 2
        assertTrue(validator.validateSwitch(battleKey, 0, 2), "Should allow switching to reserve");
    }

    // =========================================
    // Force Switch Tests (switchActiveMonForSlot)
    // =========================================

    /**
     * @notice Test: switchActiveMonForSlot correctly switches a specific slot in doubles
     * @dev Verifies the new slot-aware switch function doesn't corrupt storage
     */
    function test_switchActiveMonForSlot_correctlyUpdatesSingleSlot() public {
        // Create a move set with the doubles force switch move
        DoublesForceSwitchMove forceSwitchMove = new DoublesForceSwitchMove(engine);

        IMoveSet[] memory aliceMoves = new IMoveSet[](4);
        aliceMoves[0] = forceSwitchMove;  // Force switch move
        aliceMoves[1] = targetedStrongAttack;
        aliceMoves[2] = targetedStrongAttack;
        aliceMoves[3] = targetedStrongAttack;

        IMoveSet[] memory bobMoves = new IMoveSet[](4);
        bobMoves[0] = targetedStrongAttack;
        bobMoves[1] = targetedStrongAttack;
        bobMoves[2] = targetedStrongAttack;
        bobMoves[3] = targetedStrongAttack;

        // Create teams - Alice will force Bob's slot 0 to switch to mon 2
        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(100, 20, aliceMoves);  // Fastest - uses force switch
        aliceTeam[1] = _createMon(100, 15, aliceMoves);
        aliceTeam[2] = _createMon(100, 10, aliceMoves);

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 5, bobMoves);  // Will be force-switched
        bobTeam[1] = _createMon(100, 4, bobMoves);
        bobTeam[2] = _createMon(100, 3, bobMoves);  // Reserve - will be switched in

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Verify initial state: Bob slot 0 = mon 0, slot 1 = mon 1
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 1, 0), 0, "Bob slot 0 should be mon 0");
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 1, 1), 1, "Bob slot 1 should be mon 1");

        // Turn 1: Alice slot 0 uses force switch on Bob slot 0, forcing switch to mon 2
        // extraData format: lower 4 bits = target slot (0), next 4 bits = mon to switch to (2)
        uint240 forceSlot0ToMon2 = 0 | (2 << 4);  // target slot 0, switch to mon 2

        _doublesCommitRevealExecute(
            battleKey,
            0, forceSlot0ToMon2, NO_OP_MOVE_INDEX, 0,  // Alice: slot 0 force-switch, slot 1 no-op
            NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0   // Bob: both no-op (won't matter, Alice is faster)
        );

        // Verify: Bob slot 0 should now be mon 2, slot 1 should still be mon 1
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 1, 0), 2, "Bob slot 0 should now be mon 2");
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 1, 1), 1, "Bob slot 1 should still be mon 1");

        // Verify Alice's slots are unchanged
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 0), 0, "Alice slot 0 should still be mon 0");
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 0, 1), 1, "Alice slot 1 should still be mon 1");
    }

    /**
     * @notice Test: switchActiveMonForSlot on slot 1 doesn't affect slot 0
     * @dev Ensures slot isolation in force-switch operations
     */
    function test_switchActiveMonForSlot_slot1_doesNotAffectSlot0() public {
        DoublesForceSwitchMove forceSwitchMove = new DoublesForceSwitchMove(engine);

        IMoveSet[] memory aliceMoves = new IMoveSet[](4);
        aliceMoves[0] = forceSwitchMove;
        aliceMoves[1] = targetedStrongAttack;
        aliceMoves[2] = targetedStrongAttack;
        aliceMoves[3] = targetedStrongAttack;

        IMoveSet[] memory bobMoves = new IMoveSet[](4);
        bobMoves[0] = targetedStrongAttack;
        bobMoves[1] = targetedStrongAttack;
        bobMoves[2] = targetedStrongAttack;
        bobMoves[3] = targetedStrongAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(100, 20, aliceMoves);
        aliceTeam[1] = _createMon(100, 15, aliceMoves);
        aliceTeam[2] = _createMon(100, 10, aliceMoves);

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 5, bobMoves);
        bobTeam[1] = _createMon(100, 4, bobMoves);
        bobTeam[2] = _createMon(100, 3, bobMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Force Bob slot 1 to switch to mon 2
        // extraData: target slot 1, switch to mon 2
        uint240 forceSlot1ToMon2 = 1 | (2 << 4);

        _doublesCommitRevealExecute(
            battleKey,
            0, forceSlot1ToMon2, NO_OP_MOVE_INDEX, 0,
            NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0
        );

        // Bob slot 1 should now be mon 2, slot 0 should still be mon 0
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 1, 0), 0, "Bob slot 0 should still be mon 0");
        assertEq(engine.getActiveMonIndexForSlot(battleKey, 1, 1), 2, "Bob slot 1 should now be mon 2");
    }

    // =========================================
    // Simultaneous Switch Validation Tests
    // =========================================

    /**
     * @notice Test: Both slots cannot switch to the same reserve mon during reveal
     * @dev When both slots are KO'd and try to switch to the same reserve, validation should fail
     */
    function test_bothSlotsSwitchToSameMon_reverts() public {
        // Need 4-mon validator (2 active + 2 reserves)
        DefaultValidator validator4Mon = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 4, MOVES_PER_MON: 4, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );
        DoublesCommitManager commitManager4 = new DoublesCommitManager(engine);
        TestTeamRegistry registry4 = new TestTeamRegistry();

        IMoveSet[] memory targetedMoves = new IMoveSet[](4);
        targetedMoves[0] = targetedStrongAttack;
        targetedMoves[1] = targetedStrongAttack;
        targetedMoves[2] = targetedStrongAttack;
        targetedMoves[3] = targetedStrongAttack;

        IMoveSet[] memory regularMoves = new IMoveSet[](4);
        regularMoves[0] = strongAttack;
        regularMoves[1] = strongAttack;
        regularMoves[2] = strongAttack;
        regularMoves[3] = strongAttack;

        Mon[] memory aliceTeam = new Mon[](4);
        aliceTeam[0] = _createMon(1, 5, regularMoves);      // Weak - will be KO'd
        aliceTeam[1] = _createMon(1, 4, regularMoves);      // Weak - will be KO'd
        aliceTeam[2] = _createMon(100, 6, regularMoves);    // Reserve 1
        aliceTeam[3] = _createMon(100, 7, regularMoves);    // Reserve 2

        Mon[] memory bobTeam = new Mon[](4);
        bobTeam[0] = _createMon(100, 20, targetedMoves);
        bobTeam[1] = _createMon(100, 25, targetedMoves);
        bobTeam[2] = _createMon(100, 16, targetedMoves);
        bobTeam[3] = _createMon(100, 15, targetedMoves);

        registry4.setTeam(ALICE, aliceTeam);
        registry4.setTeam(BOB, bobTeam);

        // Start battle with 4-mon validator
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = registry4.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: registry4,
            validator: validator4Mon,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager4),
            matchmaker: matchmaker,
            gameMode: GameMode.Doubles
        });

        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(BOB);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);
        vm.startPrank(ALICE);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        // Turn 0: Initial switch
        {
            bytes32 aliceSalt = bytes32("as");
            bytes32 bobSalt = bytes32("bs");
            bytes32 aliceHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, uint240(0), SWITCH_MOVE_INDEX, uint240(1), aliceSalt));
            vm.startPrank(ALICE);
            commitManager4.commitMoves(battleKey, aliceHash);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager4.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, bobSalt, false);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager4.revealMoves(battleKey, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, aliceSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Turn 1: Bob KOs both of Alice's active mons
        {
            bytes32 aliceSalt = bytes32("as2");
            bytes32 bobSalt = bytes32("bs2");
            bytes32 bobHash = keccak256(abi.encodePacked(uint8(0), uint240(0), uint8(0), uint240(1), bobSalt));
            vm.startPrank(BOB);
            commitManager4.commitMoves(battleKey, bobHash);
            vm.stopPrank();
            vm.startPrank(ALICE);
            commitManager4.revealMoves(battleKey, uint8(NO_OP_MOVE_INDEX), 0, uint8(NO_OP_MOVE_INDEX), 0, aliceSalt, false);
            vm.stopPrank();
            vm.startPrank(BOB);
            commitManager4.revealMoves(battleKey, uint8(0), 0, uint8(0), 1, bobSalt, false);
            vm.stopPrank();
            engine.execute(battleKey);
        }

        // Both Alice mons should be KO'd
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.IsKnockedOut), 1, "Alice mon 1 KO'd");

        // Alice tries to switch BOTH slots to the SAME reserve (mon 2) - should revert
        vm.startPrank(ALICE);
        vm.expectRevert(); // Should revert because both slots can't switch to same mon
        commitManager4.revealMoves(battleKey, SWITCH_MOVE_INDEX, 2, SWITCH_MOVE_INDEX, 2, bytes32("alicesalt3"), true);
        vm.stopPrank();
    }

    // =========================================
    // Move Execution Order Tests
    // =========================================

    /**
     * @notice Test: A KO'd mon's move doesn't execute in doubles
     * @dev Verifies that if a mon is KO'd before its turn, its attack doesn't deal damage
     */
    function test_KOdMonMoveDoesNotExecute() public {
        IMoveSet[] memory targetedMoves = new IMoveSet[](4);
        targetedMoves[0] = targetedStrongAttack;
        targetedMoves[1] = targetedStrongAttack;
        targetedMoves[2] = targetedStrongAttack;
        targetedMoves[3] = targetedStrongAttack;

        // Alice: slot 0 is slow and weak (will be KO'd before attacking)
        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(1, 1, targetedMoves);    // Very slow, 1 HP - will be KO'd
        aliceTeam[1] = _createMon(300, 20, targetedMoves); // Fast, strong
        aliceTeam[2] = _createMon(100, 10, targetedMoves);

        // Bob: slot 0 is fast and will KO Alice slot 0 before it can attack
        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(300, 30, targetedMoves);  // Fastest - will KO Alice slot 0
        bobTeam[1] = _createMon(300, 5, targetedMoves);   // Slow
        bobTeam[2] = _createMon(100, 3, targetedMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Record Bob's HP before the turn
        int256 bobSlot0HpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        // Turn 1:
        // - Alice slot 0 (speed 1) targets Bob slot 0
        // - Alice slot 1 (speed 20) does NO_OP to avoid complications
        // - Bob slot 0 (speed 30) targets Alice slot 0 - will KO it first
        // - Bob slot 1 (speed 5) does NO_OP
        // Order: Bob slot 0 (30) > Alice slot 1 (NO_OP) > Bob slot 1 (NO_OP) > Alice slot 0 (1, but KO'd)
        _doublesCommitRevealExecute(
            battleKey,
            0, 0, NO_OP_MOVE_INDEX, 0,  // Alice: slot 0 attacks Bob slot 0, slot 1 no-op
            0, 0, NO_OP_MOVE_INDEX, 0   // Bob: slot 0 attacks Alice slot 0 (default), slot 1 no-op
        );

        // Verify Alice slot 0 is KO'd
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice slot 0 should be KO'd");

        // Bob slot 0 should NOT have taken damage from Alice slot 0 (move didn't execute)
        int256 bobSlot0HpAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(bobSlot0HpAfter, bobSlot0HpBefore, "Bob slot 0 should not have taken damage from KO'd Alice");
    }

    /**
     * @notice Test: Both opponent slots KO'd mid-turn, remaining moves don't target them
     * @dev If both opponent mons are KO'd, remaining moves that targeted them shouldn't crash
     */
    function test_bothOpponentSlotsKOd_remainingMovesHandled() public {
        IMoveSet[] memory targetedMoves = new IMoveSet[](4);
        targetedMoves[0] = targetedStrongAttack;
        targetedMoves[1] = targetedStrongAttack;
        targetedMoves[2] = targetedStrongAttack;
        targetedMoves[3] = targetedStrongAttack;

        // Alice: Both slots are very fast and strong
        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(300, 50, targetedMoves);  // Fastest
        aliceTeam[1] = _createMon(300, 45, targetedMoves);  // Second fastest
        aliceTeam[2] = _createMon(100, 10, targetedMoves);

        // Bob: Both slots are slow and weak (will be KO'd)
        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(1, 5, targetedMoves);   // Slow, weak - will be KO'd
        bobTeam[1] = _createMon(1, 4, targetedMoves);   // Slower, weak - will be KO'd
        bobTeam[2] = _createMon(100, 3, targetedMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1:
        // Alice slot 0 (speed 50) attacks Bob slot 0 -> KO
        // Alice slot 1 (speed 45) attacks Bob slot 1 -> KO
        // Bob slot 0 (speed 5) - KO'd, shouldn't execute
        // Bob slot 1 (speed 4) - KO'd, shouldn't execute
        _doublesCommitRevealExecute(
            battleKey,
            0, 0, 0, 1,  // Alice: slot 0 attacks Bob slot 0, slot 1 attacks Bob slot 1
            0, 0, 0, 1   // Bob: both attack (won't execute - they'll be KO'd)
        );

        // Both Bob slots should be KO'd
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 1, "Bob slot 0 should be KO'd");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.IsKnockedOut), 1, "Bob slot 1 should be KO'd");

        // Alice should NOT have taken any damage (Bob's moves didn't execute)
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), 0, "Alice slot 0 should have no damage");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Hp), 0, "Alice slot 1 should have no damage");
    }

    // =========================================
    // Battle Transition Tests (Doubles <-> Singles)
    // =========================================

    /**
     * @notice Test: Doubles battle completes, then singles battle reuses storage correctly
     * @dev Verifies storage reuse between game modes with actual damage/effects
     */
    function test_doublesThenSingles_storageReuse() public {
        // Create singles commit manager
        DefaultCommitManager singlesCommitManager = new DefaultCommitManager(engine);

        IMoveSet[] memory targetedMoves = new IMoveSet[](4);
        targetedMoves[0] = targetedStrongAttack;
        targetedMoves[1] = targetedStrongAttack;
        targetedMoves[2] = targetedStrongAttack;
        targetedMoves[3] = targetedStrongAttack;

        // Alice with weak slot 0 mon for quick KO
        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(1, 5, targetedMoves);   // Will be KO'd quickly
        aliceTeam[1] = _createMon(1, 4, targetedMoves);   // Will be KO'd
        aliceTeam[2] = _createMon(1, 3, targetedMoves);   // Reserve, also weak

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 20, targetedMoves);
        bobTeam[1] = _createMon(100, 18, targetedMoves);
        bobTeam[2] = _createMon(100, 16, targetedMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // ---- DOUBLES BATTLE ----
        bytes32 doublesBattleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(doublesBattleKey);

        assertEq(uint8(engine.getGameMode(doublesBattleKey)), uint8(GameMode.Doubles), "Should be doubles mode");

        // Turn 1: Bob KOs only Alice slot 0 (mon 0), keeps slot 1 alive
        // Alice does NO_OP with both slots to avoid counter-attacking Bob
        _doublesCommitRevealExecute(
            doublesBattleKey,
            NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0,  // Alice: both no-op
            0, 0, NO_OP_MOVE_INDEX, 0                   // Bob: slot 0 attacks Alice slot 0 (default target), slot 1 no-op
        );

        // Alice slot 0 KO'd, needs to switch
        assertEq(engine.getMonStateForBattle(doublesBattleKey, 0, 0, MonStateIndexName.IsKnockedOut), 1, "Alice mon 0 KO'd");

        // Alice single-player switch turn: switch slot 0 to reserve (mon 2)
        vm.startPrank(ALICE);
        commitManager.revealMoves(doublesBattleKey, SWITCH_MOVE_INDEX, 2, NO_OP_MOVE_INDEX, 0, bytes32("as"), true);
        vm.stopPrank();

        // Verify switch happened
        assertEq(engine.getActiveMonIndexForSlot(doublesBattleKey, 0, 0), 2, "Alice slot 0 now has mon 2");

        // Turn 2: Bob KOs both remaining Alice mons (slot 0 has mon 2, slot 1 has mon 1)
        _doublesCommitRevealExecute(
            doublesBattleKey,
            0, 0, 0, 0,
            0, 0, 0, 1  // Bob: slot 0 attacks default (Alice slot 0), slot 1 attacks Alice slot 1
        );

        // All Alice mons KO'd, Bob wins
        assertEq(engine.getWinner(doublesBattleKey), BOB, "Bob should win doubles");

        // Record free keys
        bytes32[] memory freeKeysBefore = engine.getFreeStorageKeys();
        assertGt(freeKeysBefore.length, 0, "Should have free storage key");

        // ---- SINGLES BATTLE (reuses storage) ----
        vm.warp(block.timestamp + 2);

        // Fresh teams for singles - HP 300 to survive one hit (attack does ~200 damage)
        Mon[] memory aliceSingles = new Mon[](3);
        aliceSingles[0] = _createMon(300, 15, targetedMoves);
        aliceSingles[1] = _createMon(300, 12, targetedMoves);
        aliceSingles[2] = _createMon(300, 10, targetedMoves);

        Mon[] memory bobSingles = new Mon[](3);
        bobSingles[0] = _createMon(300, 14, targetedMoves);
        bobSingles[1] = _createMon(300, 11, targetedMoves);
        bobSingles[2] = _createMon(300, 9, targetedMoves);

        defaultRegistry.setTeam(ALICE, aliceSingles);
        defaultRegistry.setTeam(BOB, bobSingles);

        bytes32 singlesBattleKey = _startSinglesBattle(singlesCommitManager);
        vm.warp(block.timestamp + 1);

        assertEq(uint8(engine.getGameMode(singlesBattleKey)), uint8(GameMode.Singles), "Should be singles mode");

        // Verify storage reused
        bytes32[] memory freeKeysAfter = engine.getFreeStorageKeys();
        assertEq(freeKeysAfter.length, freeKeysBefore.length - 1, "Should have used free storage key");

        // Turn 0: Initial switch (P0 commits, P1 reveals first, P0 reveals second)
        _singlesInitialSwitch(singlesBattleKey, singlesCommitManager);

        // Verify active mons
        uint256[] memory activeIndices = engine.getActiveMonIndexForBattleState(singlesBattleKey);
        assertEq(activeIndices[0], 0, "Alice active mon 0");
        assertEq(activeIndices[1], 0, "Bob active mon 0");

        // Turn 1: Both attack (P1 commits, P0 reveals first, P1 reveals second)
        _singlesCommitRevealExecute(singlesBattleKey, singlesCommitManager, 0, 0, 0, 0);

        // Verify damage dealt
        int256 aliceHp = engine.getMonStateForBattle(singlesBattleKey, 0, 0, MonStateIndexName.Hp);
        int256 bobHp = engine.getMonStateForBattle(singlesBattleKey, 1, 0, MonStateIndexName.Hp);
        assertTrue(aliceHp < 0, "Alice took damage");
        assertTrue(bobHp < 0, "Bob took damage");

        assertEq(engine.getWinner(singlesBattleKey), address(0), "Singles battle ongoing");
    }

    /**
     * @notice Test: Singles battle completes, then doubles battle reuses storage correctly
     * @dev Verifies storage reuse from singles to doubles with actual damage/effects
     */
    function test_singlesThenDoubles_storageReuse() public {
        DefaultCommitManager singlesCommitManager = new DefaultCommitManager(engine);

        IMoveSet[] memory targetedMoves = new IMoveSet[](4);
        targetedMoves[0] = targetedStrongAttack;
        targetedMoves[1] = targetedStrongAttack;
        targetedMoves[2] = targetedStrongAttack;
        targetedMoves[3] = targetedStrongAttack;

        // Weak Alice for quick singles defeat
        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(1, 5, targetedMoves);
        aliceTeam[1] = _createMon(1, 4, targetedMoves);
        aliceTeam[2] = _createMon(1, 3, targetedMoves);

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 20, targetedMoves);
        bobTeam[1] = _createMon(100, 18, targetedMoves);
        bobTeam[2] = _createMon(100, 16, targetedMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // ---- SINGLES BATTLE ----
        bytes32 singlesBattleKey = _startSinglesBattle(singlesCommitManager);
        vm.warp(block.timestamp + 1);

        assertEq(uint8(engine.getGameMode(singlesBattleKey)), uint8(GameMode.Singles), "Should be singles mode");

        // Turn 0: Initial switch
        _singlesInitialSwitch(singlesBattleKey, singlesCommitManager);

        // Turn 1: Bob KOs Alice mon 0
        _singlesCommitRevealExecute(singlesBattleKey, singlesCommitManager, 0, 0, 0, 0);

        // Alice switch turn (playerSwitchForTurnFlag = 0)
        _singlesSwitchTurn(singlesBattleKey, singlesCommitManager, 1);

        // Turn 2: Bob KOs Alice mon 1
        _singlesCommitRevealExecute(singlesBattleKey, singlesCommitManager, 0, 0, 0, 0);

        // Alice switch turn
        _singlesSwitchTurn(singlesBattleKey, singlesCommitManager, 2);

        // Turn 3: Bob KOs Alice's last mon
        _singlesCommitRevealExecute(singlesBattleKey, singlesCommitManager, 0, 0, 0, 0);

        assertEq(engine.getWinner(singlesBattleKey), BOB, "Bob should win singles");

        // Record free keys
        bytes32[] memory freeKeysBefore = engine.getFreeStorageKeys();
        assertGt(freeKeysBefore.length, 0, "Should have free storage key");

        // ---- DOUBLES BATTLE (reuses storage) ----
        vm.warp(block.timestamp + 2);

        // Fresh teams for doubles - HP 300 to survive attacks (~200 damage each)
        Mon[] memory aliceDoubles = new Mon[](3);
        aliceDoubles[0] = _createMon(300, 15, targetedMoves);
        aliceDoubles[1] = _createMon(300, 12, targetedMoves);
        aliceDoubles[2] = _createMon(300, 10, targetedMoves);

        Mon[] memory bobDoubles = new Mon[](3);
        bobDoubles[0] = _createMon(300, 14, targetedMoves);
        bobDoubles[1] = _createMon(300, 11, targetedMoves);
        bobDoubles[2] = _createMon(300, 9, targetedMoves);

        defaultRegistry.setTeam(ALICE, aliceDoubles);
        defaultRegistry.setTeam(BOB, bobDoubles);

        bytes32 doublesBattleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);

        assertEq(uint8(engine.getGameMode(doublesBattleKey)), uint8(GameMode.Doubles), "Should be doubles mode");

        // Verify storage reused
        bytes32[] memory freeKeysAfter = engine.getFreeStorageKeys();
        assertEq(freeKeysAfter.length, freeKeysBefore.length - 1, "Should have used free storage key");

        // Initial switch for doubles
        _doInitialSwitch(doublesBattleKey);

        // Verify all 4 slots set correctly
        assertEq(engine.getActiveMonIndexForSlot(doublesBattleKey, 0, 0), 0, "Alice slot 0 = mon 0");
        assertEq(engine.getActiveMonIndexForSlot(doublesBattleKey, 0, 1), 1, "Alice slot 1 = mon 1");
        assertEq(engine.getActiveMonIndexForSlot(doublesBattleKey, 1, 0), 0, "Bob slot 0 = mon 0");
        assertEq(engine.getActiveMonIndexForSlot(doublesBattleKey, 1, 1), 1, "Bob slot 1 = mon 1");

        // Turn 1: Both sides attack (dealing real damage)
        _doublesCommitRevealExecute(doublesBattleKey, 0, 0, 0, 0, 0, 0, 0, 1);

        // Verify damage to correct targets
        int256 alice0Hp = engine.getMonStateForBattle(doublesBattleKey, 0, 0, MonStateIndexName.Hp);
        int256 alice1Hp = engine.getMonStateForBattle(doublesBattleKey, 0, 1, MonStateIndexName.Hp);
        assertTrue(alice0Hp < 0, "Alice mon 0 took damage");
        assertTrue(alice1Hp < 0, "Alice mon 1 took damage");

        assertEq(engine.getWinner(doublesBattleKey), address(0), "Doubles battle ongoing");
    }

    // =========================================
    // Singles Helper Functions
    // =========================================

    function _startSinglesBattle(DefaultCommitManager scm) internal returns (bytes32 battleKey) {
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = defaultRegistry.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(scm),
            matchmaker: matchmaker,
            gameMode: GameMode.Singles
        });

        vm.startPrank(ALICE);
        battleKey = matchmaker.proposeBattle(proposal);

        bytes32 integrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(BOB);
        matchmaker.acceptBattle(battleKey, 0, integrityHash);

        vm.startPrank(ALICE);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);
        vm.stopPrank();
    }

    // Turn 0 initial switch for singles: P0 commits, P1 reveals, P0 reveals
    function _singlesInitialSwitch(bytes32 battleKey, DefaultCommitManager scm) internal {
        bytes32 aliceSalt = bytes32("alice_init");
        bytes32 bobSalt = bytes32("bob_init");

        // P0 (Alice) commits on even turn
        bytes32 aliceHash = keccak256(abi.encodePacked(uint8(SWITCH_MOVE_INDEX), aliceSalt, uint240(0)));
        vm.prank(ALICE);
        scm.commitMove(battleKey, aliceHash);

        // P1 (Bob) reveals first (no commit needed on even turn)
        vm.prank(BOB);
        scm.revealMove(battleKey, SWITCH_MOVE_INDEX, bobSalt, 0, false);

        // P0 (Alice) reveals second
        vm.prank(ALICE);
        scm.revealMove(battleKey, SWITCH_MOVE_INDEX, aliceSalt, 0, true);
    }

    // Normal turn commit/reveal for singles
    function _singlesCommitRevealExecute(
        bytes32 battleKey,
        DefaultCommitManager scm,
        uint8 aliceMove, uint240 aliceExtra,
        uint8 bobMove, uint240 bobExtra
    ) internal {
        uint256 turnId = engine.getTurnIdForBattleState(battleKey);
        bytes32 aliceSalt = keccak256(abi.encodePacked("alice", turnId));
        bytes32 bobSalt = keccak256(abi.encodePacked("bob", turnId));

        if (turnId % 2 == 0) {
            // Even turn: P0 commits, P1 reveals first, P0 reveals second
            bytes32 aliceHash = keccak256(abi.encodePacked(aliceMove, aliceSalt, aliceExtra));
            vm.prank(ALICE);
            scm.commitMove(battleKey, aliceHash);

            vm.prank(BOB);
            scm.revealMove(battleKey, bobMove, bobSalt, bobExtra, false);

            vm.prank(ALICE);
            scm.revealMove(battleKey, aliceMove, aliceSalt, aliceExtra, true);
        } else {
            // Odd turn: P1 commits, P0 reveals first, P1 reveals second
            bytes32 bobHash = keccak256(abi.encodePacked(bobMove, bobSalt, bobExtra));
            vm.prank(BOB);
            scm.commitMove(battleKey, bobHash);

            vm.prank(ALICE);
            scm.revealMove(battleKey, aliceMove, aliceSalt, aliceExtra, false);

            vm.prank(BOB);
            scm.revealMove(battleKey, bobMove, bobSalt, bobExtra, true);
        }
    }

    // Switch turn for singles (only switching player acts)
    function _singlesSwitchTurn(bytes32 battleKey, DefaultCommitManager scm, uint256 monIndex) internal {
        bytes32 salt = keccak256(abi.encodePacked("switch", engine.getTurnIdForBattleState(battleKey)));
        vm.prank(ALICE);
        scm.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, uint240(monIndex), true);
    }

    /**
     * @notice Test that effects run correctly for BOTH slots in doubles
     * @dev This test validates the fix for the _runEffectsForMon bug where
     *      effects on slot 1's mon would incorrectly be looked up for slot 0's mon.
     *
     *      Test setup:
     *      - Alice uses DoublesEffectAttack on both slots to apply InstantDeathEffect
     *        to Bob's slot 0 (mon 0) and slot 1 (mon 1)
     *      - At RoundEnd, both effects should run and KO both of Bob's mons
     *      - If the bug existed, only slot 0's mon would be KO'd
     */
    function test_effectsRunOnBothSlots() public {
        // Create InstantDeathEffect that KOs mon at RoundEnd
        InstantDeathEffect deathEffect = new InstantDeathEffect(engine);

        // Create DoublesEffectAttack that applies the effect to a target slot
        DoublesEffectAttack effectAttack = new DoublesEffectAttack(
            engine,
            IEffect(address(deathEffect)),
            DoublesEffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 0})
        );

        // Create teams where Alice has the effect attack
        IMoveSet[] memory aliceMoves = new IMoveSet[](4);
        aliceMoves[0] = effectAttack;  // Apply effect to target slot
        aliceMoves[1] = customAttack;
        aliceMoves[2] = customAttack;
        aliceMoves[3] = customAttack;

        IMoveSet[] memory bobMoves = new IMoveSet[](4);
        bobMoves[0] = customAttack;
        bobMoves[1] = customAttack;
        bobMoves[2] = customAttack;
        bobMoves[3] = customAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(100, 20, aliceMoves);  // Fast, will act first
        aliceTeam[1] = _createMon(100, 18, aliceMoves);
        aliceTeam[2] = _createMon(100, 16, aliceMoves);

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 5, bobMoves);   // Slot 0 - will receive death effect
        bobTeam[1] = _createMon(100, 4, bobMoves);   // Slot 1 - will receive death effect
        bobTeam[2] = _createMon(100, 3, bobMoves);   // Reserve

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Verify initial state: both of Bob's mons are alive
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 0, "Bob mon 0 should be alive");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.IsKnockedOut), 0, "Bob mon 1 should be alive");

        // Turn 1: Alice's slot 0 uses effectAttack targeting Bob's slot 0
        //         Alice's slot 1 uses effectAttack targeting Bob's slot 1
        // Both of Bob's mons will have InstantDeathEffect applied
        // At RoundEnd, both effects should run and KO both mons
        _doublesCommitRevealExecute(
            battleKey,
            0, 0,                      // Alice slot 0: move 0, target slot 0
            0, 1,                      // Alice slot 1: move 0, target slot 1
            NO_OP_MOVE_INDEX, 0,       // Bob slot 0: no-op
            NO_OP_MOVE_INDEX, 0        // Bob slot 1: no-op
        );

        // After the turn, both of Bob's mons should be KO'd by the InstantDeathEffect
        // If the bug existed (slot 1's effect running for slot 0's mon), only mon 0 would be KO'd
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut),
            1,
            "Bob mon 0 should be KO'd by InstantDeathEffect"
        );
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.IsKnockedOut),
            1,
            "Bob mon 1 should be KO'd by InstantDeathEffect (validates slot 1 effect runs correctly)"
        );
    }

    /**
     * @notice Test that AfterDamage effects run on the correct mon in doubles
     * @dev Validates fix for issue #3: AfterDamage effects running on wrong mon
     * This test uses an attack that applies an AfterDamage rebound effect to the target,
     * then another attack that triggers the effect. If the fix works correctly,
     * only the mon that has the effect (slot 1) should be healed.
     */
    function test_afterDamageEffectsRunOnCorrectMon() public {
        // Create the rebound effect that heals damage
        AfterDamageReboundEffect reboundEffect = new AfterDamageReboundEffect(engine);

        // Create an attack that applies the rebound effect to a target slot
        EffectApplyingAttack effectApplyAttack = new EffectApplyingAttack(
            engine,
            IEffect(address(reboundEffect)),
            EffectApplyingAttack.Args({STAMINA_COST: 1, PRIORITY: 10})  // High priority to apply effect first
        );

        // Create a targeted attack for dealing damage
        DoublesTargetedAttack targetedAttack = new DoublesTargetedAttack(
            engine, typeCalc, DoublesTargetedAttack.Args({TYPE: Type.Fire, BASE_POWER: 30, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 0})
        );

        // Create teams where Alice has both attacks
        IMoveSet[] memory aliceMoves = new IMoveSet[](4);
        aliceMoves[0] = effectApplyAttack;  // Apply rebound effect
        aliceMoves[1] = targetedAttack;      // Deal damage
        aliceMoves[2] = customAttack;
        aliceMoves[3] = customAttack;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(100, 20, aliceMoves);  // Fast
        aliceTeam[1] = _createMon(100, 18, aliceMoves);
        aliceTeam[2] = _createMon(100, 16, aliceMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Alice's slot 0 applies rebound effect to Bob's slot 1 (mon index 1)
        // Alice's slot 1 does nothing
        _doublesCommitRevealExecute(
            battleKey,
            0, 1,                      // Alice slot 0: apply effect to Bob's slot 1
            NO_OP_MOVE_INDEX, 0,       // Alice slot 1: no-op
            NO_OP_MOVE_INDEX, 0,       // Bob slot 0: no-op
            NO_OP_MOVE_INDEX, 0        // Bob slot 1: no-op
        );

        // Get HP deltas for both of Bob's mons after effect is applied
        int256 bobMon0HpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int256 bobMon1HpBefore = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp);

        // Turn 2: Alice attacks Bob's slot 1 (which has the rebound effect)
        // The rebound effect should heal the damage, but ONLY for mon 1
        _doublesCommitRevealExecute(
            battleKey,
            1, 1,                      // Alice slot 0: attack Bob's slot 1
            NO_OP_MOVE_INDEX, 0,       // Alice slot 1: no-op
            NO_OP_MOVE_INDEX, 0,       // Bob slot 0: no-op
            NO_OP_MOVE_INDEX, 0        // Bob slot 1: no-op
        );

        // Get HP deltas after attack
        int256 bobMon0HpAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int256 bobMon1HpAfter = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp);

        // Bob's mon 0 (slot 0) should NOT have been affected by the rebound effect
        assertEq(bobMon0HpAfter, bobMon0HpBefore, "Bob mon 0 HP should be unchanged");

        // Bob's mon 1 (slot 1) should have taken damage and then healed it back
        // With the rebound effect, the net HP delta should be 0 (or close to it)
        assertEq(bobMon1HpAfter, bobMon1HpBefore, "Bob mon 1 should be fully healed by rebound effect");
    }

    /**
     * @notice Test that move validation uses the correct slot's mon
     * @dev Validates fix for issue #2: move validation checking wrong mon's stamina
     * This test sets up a situation where slot 0 has low stamina and slot 1 has full stamina.
     * If the bug existed, slot 1's move would be incorrectly rejected due to slot 0's low stamina.
     */
    function test_moveValidationUsesCorrectSlotMon() public {
        // Create a high stamina cost attack
        CustomAttack highStaminaAttack = new CustomAttack(
            engine, typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 8, PRIORITY: 0})
        );

        // Create teams where Alice has the high stamina attack
        IMoveSet[] memory aliceMoves = new IMoveSet[](4);
        aliceMoves[0] = highStaminaAttack;  // 8 stamina cost
        aliceMoves[1] = customAttack;        // 1 stamina cost
        aliceMoves[2] = customAttack;
        aliceMoves[3] = customAttack;

        // Create mons with 10 stamina
        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = _createMon(100, 20, aliceMoves);  // This mon will use high stamina attack first
        aliceTeam[1] = _createMon(100, 18, aliceMoves);  // This mon still has full stamina
        aliceTeam[2] = _createMon(100, 16, aliceMoves);

        defaultRegistry.setTeam(ALICE, aliceTeam);

        bytes32 battleKey = _startDoublesBattle();
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Alice's slot 0 uses the high stamina attack (costs 8)
        // Alice's slot 1 does nothing (saves stamina)
        _doublesCommitRevealExecute(
            battleKey,
            0, 0,                      // Alice slot 0: high stamina attack
            NO_OP_MOVE_INDEX, 0,       // Alice slot 1: no-op
            NO_OP_MOVE_INDEX, 0,       // Bob slot 0: no-op
            NO_OP_MOVE_INDEX, 0        // Bob slot 1: no-op
        );

        // Now Alice's slot 0 has ~2 stamina (10 - 8), slot 1 has ~10 stamina
        // Turn 2: Alice's slot 1 should be able to use the high stamina attack
        // even though slot 0 doesn't have enough stamina
        // If the bug existed, this would fail validation
        _doublesCommitRevealExecute(
            battleKey,
            NO_OP_MOVE_INDEX, 0,       // Alice slot 0: no-op (not enough stamina)
            0, 0,                      // Alice slot 1: high stamina attack (should work!)
            NO_OP_MOVE_INDEX, 0,       // Bob slot 0: no-op
            NO_OP_MOVE_INDEX, 0        // Bob slot 1: no-op
        );

        // If we got here without revert, the validation correctly used slot 1's stamina
        // Let's also verify the stamina was actually deducted from slot 1's mon
        int256 aliceMon1Stamina = engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Stamina);
        // Mon 1 used high stamina attack (8 cost), so delta should be -8 (plus any regen)
        assertLt(aliceMon1Stamina, 0, "Alice mon 1 should have negative stamina delta from using attack");
    }
}

