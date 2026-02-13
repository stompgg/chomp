// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Engine} from "../../src/Engine.sol";
import {MoveClass, Type} from "../../src/Enums.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {StandardAttack} from "../../src/moves/StandardAttack.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";
import {TypeCalculator} from "../../src/types/TypeCalculator.sol";
import {Test} from "forge-std/Test.sol";

contract StandardAttackFactoryTest is Test {
    StandardAttackFactory public factory;
    Engine public engine;
    TypeCalculator public typeCalc;
    bytes32 constant TEST_BATTLE_KEY = bytes32(uint256(1));

    function setUp() public {
        engine = new Engine();
        typeCalc = new TypeCalculator();
        factory = new StandardAttackFactory(engine, typeCalc);
    }

    function test_CreateAttackWithAllParameters() public {
        // Define test parameters
        uint32 basePower = 80;
        uint32 staminaCost = 2;
        uint32 accuracy = 95;
        uint32 priority = 3;
        Type moveType = Type.Fire;
        uint32 effectAccuracy = 100;
        MoveClass moveClass = MoveClass.Physical;
        uint32 critRate = 10;
        uint32 volatility = 5;
        string memory name = "Flame strike";
        IEffect effect = IEffect(address(0x123)); // Mock effect address

        // Create attack using factory
        StandardAttack attack = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: basePower,
                STAMINA_COST: staminaCost,
                ACCURACY: accuracy,
                PRIORITY: priority,
                MOVE_TYPE: moveType,
                EFFECT_ACCURACY: effectAccuracy,
                MOVE_CLASS: moveClass,
                CRIT_RATE: critRate,
                VOLATILITY: volatility,
                NAME: name,
                EFFECT: effect
            })
        );

        // Verify all parameters were set correctly using the actual function names
        assertEq(attack.basePower(TEST_BATTLE_KEY), basePower, "Base power mismatch");
        assertEq(attack.stamina(TEST_BATTLE_KEY, 0, 0), staminaCost, "Stamina cost mismatch");
        assertEq(attack.accuracy(TEST_BATTLE_KEY), accuracy, "Crit rate mismatch");
        assertEq(attack.priority(TEST_BATTLE_KEY, 0), priority, "Priority mismatch");
        assertEq(uint32(attack.moveType(TEST_BATTLE_KEY)), uint32(moveType), "Move type mismatch");
        assertEq(attack.effectAccuracy(TEST_BATTLE_KEY), effectAccuracy, "Effect accuracy mismatch");
        assertEq(uint32(attack.moveClass(TEST_BATTLE_KEY)), uint32(moveClass), "Move class mismatch");
        assertEq(attack.critRate(TEST_BATTLE_KEY), critRate, "Crit rate mismatch");
        assertEq(attack.volatility(TEST_BATTLE_KEY), volatility, "Volatility mismatch");
        assertEq(sha256(bytes(attack.name())), sha256(bytes(name)), "Name mismatch");
        assertEq(address(attack.effect(TEST_BATTLE_KEY)), address(effect), "Effect address mismatch");
    }

    function test_CreateAttackEmitsEvent() public {
        // Create basic attack parameters
        ATTACK_PARAMS memory params = ATTACK_PARAMS({
            BASE_POWER: 1,
            STAMINA_COST: 1,
            ACCURACY: 100,
            PRIORITY: 0,
            MOVE_TYPE: Type.Fire,
            EFFECT_ACCURACY: 100,
            MOVE_CLASS: MoveClass.Physical,
            CRIT_RATE: 0,
            VOLATILITY: 0,
            NAME: "Test Attack",
            EFFECT: IEffect(address(0))
        });

        // Expect the StandardAttackCreated event to be emitted
        vm.expectEmit(true, false, false, false);
        emit StandardAttackFactory.StandardAttackCreated(address(0)); // address will be different but we only check first topic

        // Create the attack
        factory.createAttack(params);
    }

    function test_CreateMultipleAttacks() public {
        // Create first attack
        StandardAttack attack1 = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 80,
                STAMINA_COST: 2,
                ACCURACY: 95,
                PRIORITY: 3,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 10,
                VOLATILITY: 5,
                NAME: "Fire Attack",
                EFFECT: IEffect(address(0))
            })
        );

        // Create second attack with different parameters
        StandardAttack attack2 = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 60,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Liquid,
                EFFECT_ACCURACY: 50,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 15,
                VOLATILITY: 3,
                NAME: "Liquid Attack",
                EFFECT: IEffect(address(0))
            })
        );

        // Verify attacks are different and have correct parameters
        assertFalse(address(attack1) == address(attack2), "Attacks should have different addresses");
        assertEq(attack1.basePower(TEST_BATTLE_KEY), 80, "Attack1 base power mismatch");
        assertEq(attack2.basePower(TEST_BATTLE_KEY), 60, "Attack2 base power mismatch");
        assertEq(uint32(attack1.moveType(TEST_BATTLE_KEY)), uint32(Type.Fire), "Attack1 type mismatch");
        assertEq(uint32(attack2.moveType(TEST_BATTLE_KEY)), uint32(Type.Liquid), "Attack2 type mismatch");
    }

    function test_onlyOwnerCanSetEngineAndCalcOnFactory() public {
        vm.startPrank(address(0x123));
        vm.expectRevert();
        factory.setEngine(Engine(address(0)));
        vm.expectRevert();
        factory.setTypeCalculator(TypeCalculator(address(0)));

        // Now set the owner to the current caller (calls should succeed)
        vm.startPrank(address(this));
        factory.setEngine(Engine(address(0)));
        factory.setTypeCalculator(TypeCalculator(address(0)));
    }

}
