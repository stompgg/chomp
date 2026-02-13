// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import {Engine} from "../../src/Engine.sol";
import { MoveClass, Type} from "../../src/Enums.sol";
import "../../src/Structs.sol";

import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";
import {DefaultValidator} from "../../src/DefaultValidator.sol";
import {IAbility} from "../../src/abilities/IAbility.sol";
import {AttackCalculator} from "../../src/moves/AttackCalculator.sol";

import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {TypeCalculator} from "../../src/types/TypeCalculator.sol";
import {BattleHelper} from "../abstract/BattleHelper.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {Test} from "forge-std/Test.sol";

contract AttackCalculatorTest is Test, BattleHelper {
    Engine engine;
    TypeCalculator typeCalc;
    MockRandomnessOracle defaultOracle;
    TestTeamRegistry defaultRegistry;
    MockRandomnessOracle mockOracle;
    DefaultCommitManager commitManager;
    DefaultValidator validator;
    DefaultMatchmaker matchmaker;

    bytes32 battleKey;

    function setUp() public {
        // Set up the core components
        engine = new Engine();
        typeCalc = new TypeCalculator();
        mockOracle = new MockRandomnessOracle();
        commitManager = new DefaultCommitManager(engine);
        validator =
            new DefaultValidator(engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10}));
        defaultRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);

        // Create a battle with two mons
        battleKey = _setupBattle();
    }

    function _setupBattle() internal returns (bytes32) {
        // Create a physical attacker mon
        Mon memory physicalMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 10,
                attack: 20, // High attack
                defense: 10,
                specialAttack: 5,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: [IMoveSet(address(0)), IMoveSet(address(0)), IMoveSet(address(0)), IMoveSet(address(0))],
            ability: IAbility(address(0))
        });

        // Create a special attacker mon
        Mon memory specialMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 10,
                attack: 5,
                defense: 10,
                specialAttack: 20, // High special attack
                specialDefense: 10,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: [IMoveSet(address(0)), IMoveSet(address(0)), IMoveSet(address(0)), IMoveSet(address(0))],
            ability: IAbility(address(0))
        });

        // Set up teams
        Mon[] memory aliceTeam = new Mon[](1);
        Mon[] memory bobTeam = new Mon[](1);
        aliceTeam[0] = physicalMon;
        bobTeam[0] = specialMon;
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start battle
        battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        return battleKey;
    }

    function test_physicalAttackDamageCalculation() public view {
        // Parameters for a physical attack
        uint32 basePower = 100;
        uint32 accuracy = 100; // Always hit
        uint256 volatility = 0; // No volatility
        Type attackType = Type.Fire;
        MoveClass attackSupertype = MoveClass.Physical;
        uint256 rng = 50; // Middle value
        uint256 critRate = 0; // No crits

        // Calculate damage (Alice attacking Bob)
        (int32 damage,) = AttackCalculator._calculateDamageView(
            engine,
            typeCalc,
            battleKey,
            0, // Alice's index
            1, // Bob's index
            basePower,
            accuracy,
            volatility,
            attackType,
            attackSupertype,
            rng,
            critRate
        );

        // Expected damage calculation:
        // damage = (basePower * attackStat) / defenseStat
        // For Fire vs Liquid (not effective): basePower is halved to 50
        // damage = (50 * 20) / 10 = 100
        assertEq(damage, 100, "Physical attack damage calculation incorrect");
    }

    function test_specialAttackDamageCalculation() public view {
        // Parameters for a special attack
        uint32 basePower = 100;
        uint32 accuracy = 100; // Always hit
        uint256 volatility = 0; // No volatility
        Type attackType = Type.Liquid;
        MoveClass attackSupertype = MoveClass.Special;
        uint256 rng = 50; // Middle value
        uint256 critRate = 0; // No crits

        // Calculate damage (Bob attacking Alice)
        (int32 damage,) = AttackCalculator._calculateDamageView(
            engine,
            typeCalc,
            battleKey,
            1, // Bob's index
            0, // ALice's index
            basePower,
            accuracy,
            volatility,
            attackType,
            attackSupertype,
            rng,
            critRate
        );

        // Expected damage calculation:
        // damage = (basePower * specialAttackStat) / specialDefenseStat
        // For Liquid vs Fire (super effective): basePower is doubled to 200
        // damage = (200 * 20) / 10 = 400
        assertEq(damage, 400, "Special attack damage calculation incorrect");
    }

    function test_accuracyCheck() public view {
        // Test that attacks miss when accuracy check fails
        uint32 basePower = 100;
        uint32 accuracy = 50; // 50% chance to hit
        uint256 volatility = 0;
        Type attackType = Type.Fire;
        MoveClass attackSupertype = MoveClass.Physical;
        uint256 critRate = 0;

        // With rng = 49, attack should hit (rng < accuracy)
        (int32 damage1,) = AttackCalculator._calculateDamageView(
            engine,
            typeCalc,
            battleKey,
            0,
            1,
            basePower,
            accuracy,
            volatility,
            attackType,
            attackSupertype,
            49,
            critRate
        );

        // With rng = 50, attack should miss (rng >= accuracy)
        (int32 damage2, bytes32 eventType) = AttackCalculator._calculateDamageView(
            engine,
            typeCalc,
            battleKey,
            0,
            1,
            basePower,
            accuracy,
            volatility,
            attackType,
            attackSupertype,
            50,
            critRate
        );
        assertEq(uint256(eventType), uint256(MOVE_MISS_EVENT_TYPE), "Should emit miss");

        assertGt(damage1, 0, "Attack should hit with rng < accuracy");
        assertEq(damage2, 0, "Attack should miss with rng >= accuracy");
    }

    function test_criticalHit() public view {
        // Test critical hit calculation
        uint32 basePower = 100;
        uint32 accuracy = 100;
        uint256 volatility = 0;
        Type attackType = Type.Fire;
        MoveClass attackSupertype = MoveClass.Physical;

        // Set up a deterministic RNG value for the accuracy check
        uint256 rng = 25; // Will hit (< accuracy)

        // For this test, we need to know what the second RNG value will be
        // It's calculated as uint256(keccak256(abi.encode(rng)))
        // For simplicity, we'll test both scenarios

        // First, force a non-crit by setting critRate to 0
        (int32 normalDamage,) = AttackCalculator._calculateDamageView(
            engine,
            typeCalc,
            battleKey,
            0,
            1,
            basePower,
            accuracy,
            volatility,
            attackType,
            attackSupertype,
            rng,
            0 // No crit chance
        );

        // Then, force a crit by setting critRate to 100
        (int32 critDamage, bytes32 eventType) = AttackCalculator._calculateDamageView(
            engine,
            typeCalc,
            battleKey,
            0,
            1,
            basePower,
            accuracy,
            volatility,
            attackType,
            attackSupertype,
            rng,
            100 // Always crit
        );

        // Critical hits should double the damage
        assertEq(critDamage, int32(CRIT_NUM) * normalDamage / int32(CRIT_DENOM), "Critical hit should deal more damage");
        assertEq(uint256(eventType), uint256(MOVE_CRIT_EVENT_TYPE), "Should emit crit");
    }

    function test_volatility() public view {
        // Test that volatility affects damage
        uint32 basePower = 100;
        uint32 accuracy = 100;
        uint256 volatility = 10; // Volatility of 10
        Type attackType = Type.Fire;
        MoveClass attackSupertype = MoveClass.Physical;
        uint256 critRate = 0;

        // With even RNG, damage should increase
        (int32 damageScaledUp,) = AttackCalculator._calculateDamageView(
            engine,
            typeCalc,
            battleKey,
            0,
            1,
            basePower,
            accuracy,
            volatility,
            attackType,
            attackSupertype,
            5, // Hashes to be 60,greater than 50, we scale up
            critRate
        );

        // With odd RNG, damage should decrease
        (int32 damageScaledDown,) = AttackCalculator._calculateDamageView(
            engine,
            typeCalc,
            battleKey,
            0,
            1,
            basePower,
            accuracy,
            volatility,
            attackType,
            attackSupertype,
            49, // Hashes to be 40, less than 50, we scale down
            critRate
        );

        // Reset volatility and get base damage
        (int32 baseDamage,) = AttackCalculator._calculateDamageView(
            engine,
            typeCalc,
            battleKey,
            0,
            1,
            basePower,
            accuracy,
            0, // No volatility
            attackType,
            attackSupertype,
            0, // Doesn't matter without volatility
            critRate
        );

        assertGt(damageScaledUp, baseDamage, "damage should be scaled up");
        assertLt(damageScaledDown, baseDamage, "damage should be scaled down");
    }
}
