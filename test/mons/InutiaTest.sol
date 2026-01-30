// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../lib/forge-std/src/Test.sol";

import "../../src/Constants.sol";
import {DefaultCommitManager} from "../../src/DefaultCommitManager.sol";
import {Engine} from "../../src/Engine.sol";
import {MonStateIndexName, MoveClass, Type} from "../../src/Enums.sol";
import {DefaultValidator} from "../../src/DefaultValidator.sol";
import {IEngine} from "../../src/IEngine.sol";
import "../../src/Structs.sol";
import {IAbility} from "../../src/abilities/IAbility.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {StatBoosts} from "../../src/effects/StatBoosts.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";
import {TypeCalculator} from "../../src/types/TypeCalculator.sol";
import {BattleHelper} from "../abstract/BattleHelper.sol";
import {EffectTestHelper} from "../abstract/EffectTestHelper.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {ChainExpansion} from "../../src/mons/inutia/ChainExpansion.sol";
import {Initialize} from "../../src/mons/inutia/Initialize.sol";
import {Interweaving} from "../../src/mons/inutia/Interweaving.sol";

contract InutiaTest is Test, BattleHelper, EffectTestHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    Interweaving interweaving;
    StatBoosts statBoost;
    StandardAttackFactory attackFactory;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine();
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        statBoost = StatBoosts(deployWithCorrectBitmap(new StatBoosts(IEngine(address(engine)))));
        interweaving = Interweaving(deployWithCorrectBitmap(new Interweaving(IEngine(address(engine)), statBoost)));
        attackFactory = new StandardAttackFactory(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        matchmaker = new DefaultMatchmaker(engine);
    }

    function test_interweaving() public {
        // Create a team with a mon that has Interweaving ability
        IMoveSet[] memory moves = new IMoveSet[](0);
        // Create a mon with Interweaving ability
        Mon memory interweavingMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 5,
                speed: 5,
                attack: 10,
                defense: 5,
                specialAttack: 10,
                specialDefense: 5,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(interweaving))
        });

        // Create a regular mon without the ability
        Mon memory regularMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 5,
                speed: 5,
                attack: 10,
                defense: 5,
                specialAttack: 10,
                specialDefense: 5,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        // Set up teams with two mons each
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = regularMon;
        aliceTeam[1] = interweavingMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = regularMon;
        bobTeam[1] = regularMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 0, TIMEOUT_DURATION: 10})
        );

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Store Bob's mon initial Attack stat
        int32 bobInitialAttack = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Attack);
        int32 bobInitialSpecialAttack = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.SpecialAttack);

        // First move: Alice switches to the mon with Interweaving ability, Bob switches to the other mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(1), uint240(0)
        );

        // Check that Bob's mon Attack stat has been decreased
        int32 bobAttackAfterSwapIn = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Attack);
        int32 expectedAttackDecrease = -1; // -1 * base Attack / DECREASE_DENOM
        assertEq(
            bobAttackAfterSwapIn, bobInitialAttack + expectedAttackDecrease, "Attack should be decreased after swap in"
        );

        // Alice switches back to the regular mon, Bob does a No-Op
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(0), 0
        );

        // Check that Bob's mon SpecialAttack stat has been decreased
        int32 bobSpecialAttackAfterSwapOut =
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.SpecialAttack);
        int32 expectedSpecialAttackDecrease = -1; // -1 * base SpecialAttack / DECREASE_DENOM
        assertEq(
            bobSpecialAttackAfterSwapOut,
            bobInitialSpecialAttack + expectedSpecialAttackDecrease,
            "SpecialAttack should be decreased after swap out"
        );
    }

    function test_initialize() public {
        Initialize initialize = Initialize(deployWithCorrectBitmap(new Initialize(engine, statBoost)));

        // Create a validator with 2 mons and 1 move per mon
        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = initialize;

        // Create mon with initialize
        Mon memory initializeMon = Mon({
            stats: MonStats({
                hp: 1,
                stamina: 10,
                speed: 1,
                attack: 64,
                defense: 1,
                specialAttack: 128,
                specialDefense: 1,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = initializeMon;
        team[1] = initializeMon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Send in mons
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Both players select move index 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Assert both mons have a sp atk / atk buff of 64 (half of 128) and 32 (half of 64)
        int32 aliceSpAtk = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        int32 aliceAtk = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        int32 bobSpAtk = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.SpecialAttack);
        int32 bobAtk = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Attack);
        assertEq(aliceSpAtk, 64);
        assertEq(bobSpAtk, 64);
        assertEq(aliceAtk, 32);
        assertEq(bobAtk, 32);

        // Both players select move index 0 again (nothing should happen)
        aliceSpAtk = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        aliceAtk = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        bobSpAtk = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.SpecialAttack);
        bobAtk = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Attack);
        assertEq(aliceSpAtk, 64);
        assertEq(bobSpAtk, 64);
        assertEq(aliceAtk, 32);
        assertEq(bobAtk, 32);

        // Now both players swap to mon index 1
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(1), uint240(1)
        );

        // The stat boost should carry over
        aliceSpAtk = engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.SpecialAttack);
        aliceAtk = engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Attack);
        bobSpAtk = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.SpecialAttack);
        bobAtk = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Attack);
        assertEq(aliceSpAtk, 64);
        assertEq(bobSpAtk, 64);
        assertEq(aliceAtk, 32);
        assertEq(bobAtk, 32);

        // Now both players swap back to mon index 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Both players select move index 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // It should do something again, as the global effect is cleared
        aliceSpAtk = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        aliceAtk = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        bobSpAtk = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.SpecialAttack);
        bobAtk = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Attack);
        assertEq(aliceSpAtk, 64);
        assertEq(bobSpAtk, 64);
        assertEq(aliceAtk, 32);
        assertEq(bobAtk, 32);
    }

    function test_chainExpansion() public {
        TypeCalculator tc = new TypeCalculator();
        ChainExpansion ce = ChainExpansion(deployWithCorrectBitmap(new ChainExpansion(engine, tc)));
        DefaultValidator v = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 3, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = ce;
        moves[1] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 64,
                STAMINA_COST: 0,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Damage Attack",
                EFFECT: IEffect(address(0))
            })
        );

        // 1/8 damage
        Mon memory m1 = Mon({
            stats: MonStats({
                hp: 1024,
                stamina: 100,
                speed: 1,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Metal,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        // 1/16 damage
        Mon memory m2 = Mon({
            stats: MonStats({
                hp: 1024,
                stamina: 100,
                speed: 1,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Nature,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        // 1/4 damage
        Mon memory m3 = Mon({
            stats: MonStats({
                hp: 1024,
                stamina: 100,
                speed: 1,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Yang,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        Mon[] memory team = new Mon[](3);
        team[0] = m1;
        team[1] = m2;
        team[2] = m3;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(v, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses CE, Bob does nothing (turn 1)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Using Chain Expansion twice will not lead to two global effects (turn 2)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, 2, 0);
        assertEq(effects.length, 1, "Chain Expansion should only be applied once");

        // Bob swaps to mon index 1 (turn 3)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, uint240(1)
        );

        // Verify damage dealt to Bob's mon index 1 is 1/16 of max HP (charge 1)
        int32 damageToBobMon1 = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp);
        assertEq(damageToBobMon1, -64, "Damage dealt to Bob's mon index 1 should be 1/16 of max HP");

        // Bob swaps to mon index 2 (turn 4)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, uint240(2)
        );

        // Verify damage dealt to Bob's mon index 2 is 1/4 of max HP (charge 2)
        int32 damageToBobMon2 = engine.getMonStateForBattle(battleKey, 1, 2, MonStateIndexName.Hp);
        assertEq(damageToBobMon2, -256, "Damage dealt to Bob's mon index 2 should be 1/4 of max HP");

        // Bob swaps back to mon index 0 (turn 5)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, uint240(0)
        );

        // Verify damage dealt to Bob's mon index 0 is 1/8 of max HP (charge 3)
        int32 damageToBobMon0 = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(damageToBobMon0, -128, "Damage dealt to Bob's mon index 0 should be 1/8 of max HP");

        // Bob swaps to mon index 1
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, uint240(1)
        );

        // Verify damage dealt to Bob's mon index 1 is 1/16 of max HP (charge 4)
        damageToBobMon1 = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp);
        assertEq(damageToBobMon1, -128, "Damage dealt to Bob's mon index 1 should be 1/16 of max HP (now applied twice)");

        // Verify the global effects are now empty (CE is finished)
        (effects, ) = engine.getEffects(battleKey, 2, 0);
        assertEq(effects.length, 0, "Chain Expansion should be removed from global effects");

        // Test the heal
        // Alice uses CE, Bob deals damage
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 1, 0, 0);

        // Verify that CE is back in global effects
        (effects, ) = engine.getEffects(battleKey, 2, 0);
        assertEq(effects.length, 1, "Chain Expansion should be added back to global effects");

        // Verify Alice's mon index 0 took damage
        int32 aliceDamageBeforeHeal = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(aliceDamageBeforeHeal, -64, "Alice's mon index 0 should take 1/16 of max HP");

        // Alice swaps to mon index 1, Bob does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(1), 0
        );

        // Alice swaps back to mon index 0, Bob does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(0), 0
        );

        // Verify Alice's mon index 0 is healed by 1/16 of max HP
        int32 aliceDamageAfterHeal = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(aliceDamageAfterHeal, 0, "Alice's mon index 0 should be healed by 1/16 of max HP");
    }
}
