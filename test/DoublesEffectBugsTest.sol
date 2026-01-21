// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DoublesCommitManager} from "../src/DoublesCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {DefaultRuleset} from "../src/DefaultRuleset.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {StaminaRegen} from "../src/effects/StaminaRegen.sol";
import {Overclock} from "../src/effects/battlefield/Overclock.sol";
import {StatBoosts} from "../src/effects/StatBoosts.sol";
import {IEngine} from "../src/IEngine.sol";

/**
 * @title DoublesEffectBugsTest
 * @notice Tests to validate bugs in global effects that don't handle doubles slots correctly
 */
contract DoublesEffectBugsTest is Test {
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);

    DoublesCommitManager commitManager;
    Engine engine;
    DefaultValidator validator;
    ITypeCalculator typeCalc;
    DefaultRandomnessOracle defaultOracle;
    DefaultMatchmaker matchmaker;
    TestTeamRegistry defaultRegistry;
    CustomAttack highStaminaCostAttack;

    uint256 constant TIMEOUT_DURATION = 100;

    function setUp() public {
        engine = new Engine();
        typeCalc = new TestTypeCalculator();
        defaultOracle = new DefaultRandomnessOracle();
        validator = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 3, MOVES_PER_MON: 4, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );
        matchmaker = new DefaultMatchmaker(engine);
        commitManager = new DoublesCommitManager(engine);
        defaultRegistry = new TestTeamRegistry();

        // Attack with high stamina cost to easily see stamina changes
        highStaminaCostAttack = new CustomAttack(
            engine, typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 5, PRIORITY: 0})
        );

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

    function _createMon(uint32 hp, uint32 speed, uint32 stamina, IMoveSet[] memory moves) internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: hp,
                stamina: stamina,
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

    function _startDoublesBattleWithRuleset(IRuleset ruleset) internal returns (bytes32 battleKey) {
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
            ruleset: ruleset,
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
    // StaminaRegen Bug Test
    // =========================================

    /**
     * @notice Test that StaminaRegen regenerates stamina for BOTH slots in doubles
     * @dev BUG: StaminaRegen.onRoundEnd() uses getActiveMonIndexForBattleState() which
     *      only returns slot 0 mons, so slot 1 mons never get stamina regen.
     *
     *      This test SHOULD PASS but currently FAILS due to the bug.
     */
    function test_staminaRegenAffectsBothSlotsInDoubles() public {
        // Create StaminaRegen effect and ruleset
        StaminaRegen staminaRegen = new StaminaRegen(engine);
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        DefaultRuleset ruleset = new DefaultRuleset(engine, effects);

        // Create teams with high stamina cost moves
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = highStaminaCostAttack;  // 5 stamina cost
        moves[1] = highStaminaCostAttack;
        moves[2] = highStaminaCostAttack;
        moves[3] = highStaminaCostAttack;

        Mon[] memory team = new Mon[](3);
        team[0] = _createMon(100, 10, 50, moves);  // Mon 0: slot 0
        team[1] = _createMon(100, 8, 50, moves);   // Mon 1: slot 1
        team[2] = _createMon(100, 6, 50, moves);   // Mon 2: reserve

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startDoublesBattleWithRuleset(ruleset);
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Both Alice's slots attack (each costs 5 stamina)
        _doublesCommitRevealExecute(
            battleKey,
            0, 0,                      // Alice slot 0: attack (costs 5 stamina)
            0, 0,                      // Alice slot 1: attack (costs 5 stamina)
            NO_OP_MOVE_INDEX, 0,       // Bob slot 0: no-op
            NO_OP_MOVE_INDEX, 0        // Bob slot 1: no-op
        );

        // After attack: both mons should have -5 stamina delta
        // After StaminaRegen: both mons should have -4 stamina delta (regen +1)

        int32 aliceSlot0Stamina = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        int32 aliceSlot1Stamina = engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Stamina);

        // Both slots should have received stamina regen
        // Expected: -5 (attack cost) + 1 (regen) = -4
        assertEq(aliceSlot0Stamina, -4, "Slot 0 should have -4 stamina (attack -5, regen +1)");

        // BUG: This assertion will FAIL because slot 1 doesn't get stamina regen
        // Slot 1 will have -5 instead of -4
        assertEq(aliceSlot1Stamina, -4, "Slot 1 should have -4 stamina (attack -5, regen +1) - BUG: slot 1 doesn't get regen!");
    }

    // =========================================
    // Overclock Bug Test
    // =========================================

    /**
     * @notice Test that Overclock applies stat changes to BOTH slots in doubles
     * @dev BUG: Overclock.onApply() uses getActiveMonIndexForBattleState()[playerIndex] which
     *      only returns slot 0's mon, so slot 1's mon never gets the stat boost.
     *
     *      This test SHOULD PASS but currently FAILS due to the bug.
     */
    function test_overclockAffectsBothSlotsInDoubles() public {
        // Create StatBoosts and Overclock
        StatBoosts statBoosts = new StatBoosts(engine);
        Overclock overclock = new Overclock(engine, statBoosts);

        // Create a move that triggers Overclock when used
        // We'll use a custom attack that calls overclock.applyOverclock
        OverclockTriggerAttack overclockAttack = new OverclockTriggerAttack(engine, typeCalc, overclock);

        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = overclockAttack;
        moves[1] = highStaminaCostAttack;
        moves[2] = highStaminaCostAttack;
        moves[3] = highStaminaCostAttack;

        // Create mons with known base speed for easy verification
        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 50,
                speed: 100,  // Base speed 100 for slot 0
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 100,  // Base spdef 100
                type1: Type.Fire,
                type2: Type.None
            }),
            ability: IAbility(address(0)),
            moves: moves
        });
        aliceTeam[1] = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 50,
                speed: 100,  // Base speed 100 for slot 1
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 100,  // Base spdef 100
                type1: Type.Fire,
                type2: Type.None
            }),
            ability: IAbility(address(0)),
            moves: moves
        });
        aliceTeam[2] = _createMon(100, 50, 50, moves);

        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = _createMon(100, 10, 50, moves);
        bobTeam[1] = _createMon(100, 8, 50, moves);
        bobTeam[2] = _createMon(100, 6, 50, moves);

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startDoublesBattleWithRuleset(IRuleset(address(0)));
        vm.warp(block.timestamp + 1);
        _doInitialSwitch(battleKey);

        // Turn 1: Alice slot 0 uses Overclock attack (triggers overclock for Alice's team)
        _doublesCommitRevealExecute(
            battleKey,
            0, 0,                      // Alice slot 0: overclock attack
            NO_OP_MOVE_INDEX, 0,       // Alice slot 1: no-op
            NO_OP_MOVE_INDEX, 0,       // Bob slot 0: no-op
            NO_OP_MOVE_INDEX, 0        // Bob slot 1: no-op
        );

        // After Overclock is applied, both of Alice's active mons should have:
        // - Speed boosted by 25% (100 -> 125, so delta = +25)
        // - SpDef reduced by 25% (100 -> 75, so delta = -25)

        int32 aliceSlot0SpeedDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Speed);
        int32 aliceSlot1SpeedDelta = engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Speed);

        // Slot 0 should have speed boost
        assertEq(aliceSlot0SpeedDelta, 25, "Slot 0 should have +25 speed from Overclock");

        // BUG: This assertion will FAIL because Overclock only applies to slot 0
        // Slot 1 will have 0 speed delta instead of +25
        assertEq(aliceSlot1SpeedDelta, 25, "Slot 1 should have +25 speed from Overclock - BUG: slot 1 doesn't get boost!");
    }
}

/**
 * @title OverclockTriggerAttack
 * @notice A mock attack that triggers Overclock when used
 */
contract OverclockTriggerAttack is IMoveSet {
    IEngine public immutable ENGINE;
    ITypeCalculator public immutable TYPE_CALCULATOR;
    Overclock public immutable OVERCLOCK;

    constructor(IEngine engine, ITypeCalculator typeCalc, Overclock overclock) {
        ENGINE = engine;
        TYPE_CALCULATOR = typeCalc;
        OVERCLOCK = overclock;
    }

    function move(bytes32, uint256 attackerPlayerIndex, uint240, uint256) external {
        // Apply Overclock to the attacker's team
        OVERCLOCK.applyOverclock(attackerPlayerIndex);
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return 0;
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 1;
    }

    function moveType(bytes32) external pure returns (Type) {
        return Type.Fire;
    }

    function moveClass(bytes32) external pure returns (MoveClass) {
        return MoveClass.Other;
    }

    function name() external pure returns (string memory) {
        return "OverclockTrigger";
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}
