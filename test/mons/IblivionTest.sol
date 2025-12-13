// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Structs.sol";
import {Test} from "forge-std/Test.sol";

import {DefaultCommitManager} from "../../src/DefaultCommitManager.sol";
import {Engine} from "../../src/Engine.sol";
import {MonStateIndexName, MoveClass, Type} from "../../src/Enums.sol";
import {DefaultValidator} from "../../src/DefaultValidator.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IAbility} from "../../src/abilities/IAbility.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {StatBoosts} from "../../src/effects/StatBoosts.sol";
import {IntrinsicValue} from "../../src/mons/iblivion/IntrinsicValue.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {StandardAttack} from "../../src/moves/StandardAttack.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";
import {BattleHelper} from "../abstract/BattleHelper.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {StatBoostsMove} from "../mocks/StatBoostsMove.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {Baselight} from "../../src/mons/iblivion/Baselight.sol";
import {Brightback} from "../../src/mons/iblivion/Brightback.sol";
import {FirstResort} from "../../src/mons/iblivion/FirstResort.sol";
import {Loop} from "../../src/mons/iblivion/Loop.sol";

contract IblivionTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultValidator validator;
    IntrinsicValue intrinsicValue;
    Baselight baselight;
    Loop loop;
    StatBoosts statBoost;
    StatBoostsMove statBoostMove;
    StandardAttackFactory attackFactory;
    DefaultMatchmaker matchmaker;

    // Helper to pack StatBoostsMove extraData: lower 60 bits = playerIndex, next 60 bits = monIndex, next 60 bits = statIndex, upper 60 bits = boostAmount
    function _packStatBoost(uint256 playerIndex, uint256 monIndex, uint256 statIndex, int32 boostAmount) internal pure returns (uint240) {
        return uint240(playerIndex | (monIndex << 60) | (statIndex << 120) | (uint256(uint32(boostAmount)) << 180));
    }

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine();
        validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        statBoost = new StatBoosts(IEngine(address(engine)));
        baselight = new Baselight(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        loop = new Loop(IEngine(address(engine)));
        intrinsicValue = new IntrinsicValue(IEngine(address(engine)), baselight, statBoost);
        statBoostMove = new StatBoostsMove(IEngine(address(engine)), statBoost);
        attackFactory = new StandardAttackFactory(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        matchmaker = new DefaultMatchmaker(engine);
    }

    /*
    function test_intrinsicValueResetsDebuffsAndIncreasesBaselightLevel() public {
        // Test all stat types
        _testStatDebuffReset(MonStateIndexName.Attack);
        _testStatDebuffReset(MonStateIndexName.Defense);
        _testStatDebuffReset(MonStateIndexName.SpecialAttack);
        _testStatDebuffReset(MonStateIndexName.SpecialDefense);
        _testStatDebuffReset(MonStateIndexName.Speed);
    }
    */

    function _testStatDebuffReset(MonStateIndexName statType) internal {
        // Create a team with a mon that has IntrinsicValue ability and Baselight move
        IMoveSet[] memory aliceMoves = new IMoveSet[](1);
        aliceMoves[0] = baselight;

        Mon memory aliceMon = Mon({
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
            moves: aliceMoves,
            ability: IAbility(address(intrinsicValue))
        });

        // Create a StandardAttack that applies any debuff
        IMoveSet[] memory bobMoves = new IMoveSet[](1);
        bobMoves[0] = statBoostMove;

        Mon memory bobMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 10,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: bobMoves,
            ability: IAbility(address(0)) // No ability
        });

        // Set up teams
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;

        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Check that Alice's mon has the IntrinsicValue effect
        (EffectInstance[] memory aliceEffects, ) = engine.getEffects(battleKey, 0, 0);
        bool hasIntrinsicValueEffect = false;
        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (aliceEffects[i].effect == IEffect(address(intrinsicValue))) {
                hasIntrinsicValueEffect = true;
                break;
            }
        }
        assertTrue(hasIntrinsicValueEffect, "Alice's mon should have IntrinsicValue effect");

        // Get initial stat value
        int32 statBefore = engine.getMonStateForBattle(battleKey, 0, 0, statType);

        // Get initial Baselight level
        uint256 baselightLevelBefore = baselight.getBaselightLevel(battleKey, 0, 0);

        // Bob uses debuff attack on Alice's mon
        // The debuff applies -1% to the specified stat, which then gets reset at end of round
        uint240 debuffData = _packStatBoost(0, 0, uint256(statType), int32(-1));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, debuffData);

        // Check that Alice's mon's stat debuff has been reset
        int32 statAfterReset = engine.getMonStateForBattle(battleKey, 0, 0, statType);
        assertEq(
            statAfterReset,
            statBefore,
            string(abi.encodePacked("Stat debuff for ", _getStatName(statType), " should be reset"))
        );

        // Check that Baselight level has been increased
        uint256 baselightLevelAfter = baselight.getBaselightLevel(battleKey, 0, 0);
        assertEq(
            baselightLevelAfter,
            baselightLevelBefore + 1,
            string(
                abi.encodePacked(
                    "Baselight level should be increased by 1 after resetting ", _getStatName(statType), " debuff"
                )
            )
        );
    }

    // Helper function to get stat name for better error messages
    function _getStatName(MonStateIndexName statType) internal pure returns (string memory) {
        if (statType == MonStateIndexName.Attack) return "Attack";
        if (statType == MonStateIndexName.Defense) return "Defense";
        if (statType == MonStateIndexName.SpecialAttack) return "SpecialAttack";
        if (statType == MonStateIndexName.SpecialDefense) return "SpecialDefense";
        if (statType == MonStateIndexName.Speed) return "Speed";
        return "Unknown";
    }

    function test_baselightSequentialUse() public {
        // Create a team with a mon that has Baselight move and high HP
        IMoveSet[] memory aliceMoves = new IMoveSet[](1);
        aliceMoves[0] = baselight;

        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 10,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: aliceMoves,
            ability: IAbility(address(0))
        });

        // Create a mon with high HP to receive damage
        IMoveSet[] memory bobMoves = new IMoveSet[](1);
        bobMoves[0] = statBoostMove; // Just a placeholder move

        Mon memory bobMon = Mon({
            stats: MonStats({
                hp: 10000,
                stamina: 20,
                speed: 5, // Lower speed so Alice goes first
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: bobMoves,
            ability: IAbility(address(0)) // No ability
        });

        // Set up teams
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;

        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Use Baselight sequentially and verify damage and stamina cost
        for (uint256 i = 0; i < baselight.MAX_BASELIGHT_LEVEL(); i++) {
            // Get current Baselight level before the move
            uint256 currentBaselightLevel = baselight.getBaselightLevel(battleKey, 0, 0);
            assertEq(
                currentBaselightLevel,
                i,
                string(abi.encodePacked("Baselight level should be ", vm.toString(i), " before move"))
            );

            // Get current stamina before the move
            int32 aliceStaminaBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);

            // Get Bob's HP before the move
            int32 bobHpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

            // Alice uses Baselight, Bob uses NO_OP
            _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

            // Get new Baselight level after the move
            uint256 newBaselightLevel = baselight.getBaselightLevel(battleKey, 0, 0);
            assertEq(
                newBaselightLevel,
                i + 1,
                string(abi.encodePacked("Baselight level should be ", vm.toString(i + 1), " after move"))
            );

            // Get stamina after the move
            int32 aliceStaminaAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);

            // Verify stamina cost (should be equal to the Baselight level before the move)
            int32 expectedStaminaCost = int32(int256(currentBaselightLevel));
            assertEq(
                aliceStaminaBefore - aliceStaminaAfter,
                expectedStaminaCost,
                string(
                    abi.encodePacked(
                        "Stamina cost should be ",
                        vm.toString(uint256(uint32(expectedStaminaCost))),
                        " at level ",
                        vm.toString(currentBaselightLevel)
                    )
                )
            );

            // Get Bob's HP after the move
            int32 bobHpAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
            uint32 expectedBasePower =
                baselight.BASE_POWER() + (uint32(currentBaselightLevel) * baselight.BASELIGHT_LEVEL_BOOST());
            uint32 damageDealt = uint32(bobHpBefore - bobHpAfter);
            assertApproxEqRel(
                damageDealt,
                expectedBasePower,
                2e17,
                string(
                    abi.encodePacked(
                        "Damage dealt should be ",
                        vm.toString(expectedBasePower),
                        " at level ",
                        vm.toString(currentBaselightLevel)
                    )
                )
            );
        }

        // Do it one more time and verify that Baselight does not go up more
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        uint256 finalBaselightLevel = baselight.getBaselightLevel(battleKey, 0, 0);
        assertEq(finalBaselightLevel, baselight.MAX_BASELIGHT_LEVEL(), "Baselight level should not exceed max level");
    }

    function test_loop() public {
        // Create a new validator with 2 moves per mon
        DefaultValidator twoMovesValidator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        // Create a StandardAttack with 5 stamina cost but 0 damage
        StandardAttack highStaminaAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0, // No damage
                STAMINA_COST: 5, // High stamina cost
                ACCURACY: 100,
                PRIORITY: 0,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Stamina Drain",
                EFFECT: IEffect(address(0))
            })
        );

        // Create a team with a mon that has Loop move and the high stamina cost attack
        IMoveSet[] memory aliceMoves = new IMoveSet[](2);
        aliceMoves[0] = highStaminaAttack;
        aliceMoves[1] = loop;

        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 6,
                speed: 10,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: aliceMoves,
            ability: IAbility(address(0))
        });

        // Create a mon for Bob
        IMoveSet[] memory bobMoves = new IMoveSet[](2);
        bobMoves[0] = statBoostMove; // Just a placeholder move
        bobMoves[1] = statBoostMove; // Just a placeholder move

        Mon memory bobMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 5, // Lower speed so Alice goes first
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: bobMoves,
            ability: IAbility(address(0)) // No ability
        });

        // Set up teams
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;

        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(twoMovesValidator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses high stamina cost attack, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Get the stamina delta (staminaDelta is stored in the Stamina field)
        int32 staminaDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        assertEq(staminaDelta, -5, "Stamina should be 0 after using high stamina cost attack");

        // Alice uses Loop, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, 0, 0);

        // Check that Alice's mon's stamina delta is reset
        int32 staminaDeltaAfterLoop = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        assertEq(staminaDeltaAfterLoop, 0, "Stamina delta should be reset to 0 after using Loop");
    }

    function test_firstResort() public {
        // Create a new validator with 2 moves per mon
        DefaultValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        // Deploy First Resort
        FirstResort firstResort = new FirstResort(engine, typeCalc, baselight);

        // Set up moves array
        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = baselight;
        moves[1] = firstResort;

        Mon memory firstResortMon = Mon({
            stats: MonStats({
                hp: 1,
                stamina: 6,
                speed: 10,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });
        Mon memory fastMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 6,
                speed: 100, // Much faster than alice
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = firstResortMon;
        team[1] = firstResortMon;
        Mon[] memory fastTeam = new Mon[](2);
        fastTeam[0] = fastMon;
        fastTeam[1] = fastMon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, fastTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice chooses move index 1 (First Resort), Bob chooses move index 0 (Baselight)
        // Bob should move first and KO Alice's mon index 0 without taking damage
        // (even though both choose to attack)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 0, uint240(0), uint240(0));

        // Assert Bob's mon index 0's HP delta is also 0 (Bob took no damage)
        int32 hpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(hpDelta, 0, "Bob should have taken zero damage");

        // Alice swaps in mon index 1
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(1), true);

        // Alice levels up Baselight to level 2, Bob does nothing
        for (uint256 i; i < firstResort.BASELIGHT_THRESHOLD(); i++) {
            _commitRevealExecuteForAliceAndBob(
                engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
            );
        }

        // Assert that Bob has taken damage
        hpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertGt(0, hpDelta, "Bob should have taken damage now");
    }

    function test_brightback() public {
        // Create a new validator with 2 moves per mon
        DefaultValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        Brightback brightback = new Brightback(engine, typeCalc, baselight);

        // Set up moves array
        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = baselight;
        moves[1] = brightback;

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 6,
                speed: 10,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        // Start a battle
        bytes32 battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Bob deals damage to Alice, Alice does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 1, uint240(0), uint240(0)
        );

        // Alice does Brightback, no hp should be regained
        int32 aliceDamageBefore = -1 * engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );
        int32 aliceDamageAfter = -1 * engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(aliceDamageBefore, aliceDamageAfter, "No healing yet, Baselight is lv 0");

        // Alice levels up Baselight, Bob does nothing
        for (uint256 i; i < brightback.BASELIGHT_THRESHOLD(); i++) {
            _commitRevealExecuteForAliceAndBob(
                engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
            );
        }

        // Get hp beforehand
        aliceDamageBefore = -1 * engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);

        // Alice uses Brightback, should heal some HP, Bob does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );
        aliceDamageAfter = -1 * engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertGt(aliceDamageBefore, aliceDamageAfter, "Alice should have healed");
    }
}
