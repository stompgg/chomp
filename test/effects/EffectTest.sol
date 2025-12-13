// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../lib/forge-std/src/Test.sol";

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {DefaultCommitManager} from "../../src/DefaultCommitManager.sol";
import {Engine} from "../../src/Engine.sol";
import {DefaultValidator} from "../../src/DefaultValidator.sol";
import {IAbility} from "../../src/abilities/IAbility.sol";
import {IEffect} from "../../src/effects/IEffect.sol";

import {IEngineHook} from "../../src/IEngineHook.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {BattleHelper} from "../abstract/BattleHelper.sol";

// Import effects
import {DefaultRuleset} from "../../src/DefaultRuleset.sol";
import {StaminaRegen} from "../../src/effects/StaminaRegen.sol";
import {StatBoosts} from "../../src/effects/StatBoosts.sol";
import {BurnStatus} from "../../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../../src/effects/status/FrostbiteStatus.sol";
import {PanicStatus} from "../../src/effects/status/PanicStatus.sol";
import {SleepStatus} from "../../src/effects/status/SleepStatus.sol";
import {ZapStatus} from "../../src/effects/status/ZapStatus.sol";

// Import standard attack factory and template
import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";

// Import mocks for OnUpdateMonState test
import {OnUpdateMonStateHealEffect} from "../mocks/OnUpdateMonStateHealEffect.sol";
import {EffectAbility} from "../mocks/EffectAbility.sol";
import {ReduceSpAtkMove} from "../mocks/ReduceSpAtkMove.sol";

contract EffectTest is Test, BattleHelper {
    DefaultCommitManager commitManager;
    Engine engine;
    DefaultValidator oneMonOneMoveValidator;
    ITypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;

    StatBoosts statBoosts;
    StandardAttackFactory standardAttackFactory;
    FrostbiteStatus frostbiteStatus;
    SleepStatus sleepStatus;
    PanicStatus panicStatus;
    BurnStatus burnStatus;
    ZapStatus zapStatus;
    DefaultMatchmaker matchmaker;

    uint256 constant TIMEOUT_DURATION = 100;

    Mon dummyMon;
    IMoveSet dummyAttack;

    /**
     * - ensure only 1 effect can be applied at a time
     *  - ensure that the effects actually do what they should do:
     *   - frostbite does damage at eot
     *   - frostbit reduces sp atk
     *   - sleep prevents moves
     *   - fright reduces stamina
     *   - sleep and fright end after 3 turns
     *   - burn reduces attack and deals damage at eot
     *   - burn degree increases over time, increasing damage
     */
    function setUp() public {
        mockOracle = new MockRandomnessOracle();
        engine = new Engine();
        commitManager = new DefaultCommitManager(engine);
        oneMonOneMoveValidator = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );
        typeCalc = new TestTypeCalculator();
        defaultRegistry = new TestTeamRegistry();

        // Deploy StandardAttackFactory
        standardAttackFactory = new StandardAttackFactory(engine, typeCalc);

        // Deploy all effects
        statBoosts = new StatBoosts(engine);
        frostbiteStatus = new FrostbiteStatus(engine, statBoosts);
        sleepStatus = new SleepStatus(engine);
        panicStatus = new PanicStatus(engine);
        burnStatus = new BurnStatus(engine, statBoosts);
        zapStatus = new ZapStatus(engine);
        matchmaker = new DefaultMatchmaker(engine);
    }

    function test_frostbite() public {
        // Deploy an attack with frostbite
        IMoveSet frostbiteAttack = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Ice,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "FrostbiteHit",
                EFFECT: frostbiteStatus
            })
        );

        // Verify the name matches
        assertEq(frostbiteAttack.name(), "FrostbiteHit");

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = frostbiteAttack;
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 20,
                stamina: 2,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 20,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        // Register both teams
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(oneMonOneMoveValidator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move of the game has to be selecting their mons (both index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice and Bob both select attacks, both of them are move index 0 (do frostbite damage)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Check that both mons have an effect length of 2 (including stat boost)
        (EffectInstance[] memory effects0, ) = engine.getEffects(battleKey, 0, 0);
        (EffectInstance[] memory effects1, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects0.length, 2);
        assertEq(effects1.length, 2);

        // Check that both mons took 1 damage (we should round down)
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -1);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -1);

        // Check that the special attack of both mons was reduced by 50%
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack), -10);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.SpecialAttack), -10);

        // Alice and Bob both select attacks, both of them are move index 0 (do frostbite damage)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Check that both mons still have an effect length of 2 (including stat boost)
        (effects0, ) = engine.getEffects(battleKey, 0, 0);
        (effects1, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects0.length, 2);
        assertEq(effects1.length, 2);

        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -2);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -2);

        // Alice and Bob both select to do a no op
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        // Check that health was reduced
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -3);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -3);
    }

    function test_another_frostbite() public {
        // Deploy an attack with frostbite
        IMoveSet frostbiteAttack = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Ice,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "FrostbiteHit",
                EFFECT: frostbiteStatus
            })
        );

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = frostbiteAttack;
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 20,
                stamina: 2,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 20,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        DefaultValidator twoMonOneMoveValidator = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );

        // Register both teams
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(twoMonOneMoveValidator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move of the game has to be selecting their mons (both index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice switches to mon index 1, Bob induces frostbite
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, 0, uint240(1), 0);

        // Check that Alice's new mon at index 0 has taken damage
        assertEq(engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Hp), -1);
    }

    function test_sleep() public {
        // Deploy an attack with sleep
        IMoveSet sleepAttack = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Ice,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "SleepHit",
                EFFECT: sleepStatus
            })
        );

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = sleepAttack;

        Mon memory fastMon = _createMon();
        fastMon.moves = moves;
        fastMon.stats.speed = 2;
        fastMon.stats.stamina = 3;
        Mon memory slowMon = _createMon();
        slowMon.moves = moves;
        slowMon.stats.stamina = 3;
        Mon[] memory team = new Mon[](2);
        team[0] = fastMon;
        team[1] = slowMon;

        DefaultValidator validatorToUse = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: team.length, MOVES_PER_MON: 1, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        /*
        - Alice sends in fast mon, Bob sends in slow mon
        - Alice and Bob both use their move index 0
        - Alice moves first, overwrites Bob's move
        - Check that Alice has -1 stamina delta, Bob should have 0
        - Do not exit sleep early
        - Alice does NO_OP, Bob uses their move index 0
        - Check that Alice has -1 stamina delta, Bob should have 0 (the move doesn't go off)
        - Exit sleep early
        - Alice does NO_OP, Bob uses their move index 0
        - Check that Alice has -1 stamina delta, Bob should have -1 (the move goes off)
        - Alice is asleep, Bob does nothing, Alice switches to mon index 1, should be successful
        */

        bytes32 battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -1);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), 0);
        mockOracle.setRNG(1);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -1);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), 0);
        mockOracle.setRNG(0);
        // Bob wakes up, inflicts on Alice
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -1);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), -1);
        // Alice is asleep, Bob does nothing, Alice switches to mon index 1, should be successful
        mockOracle.setRNG(1);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(1), 0);
        assertEq(engine.getActiveMonIndexForBattleState(battleKey)[0], 1);
    }

    /**
     * - Alice and Bob both have mons that induce panic
     *  - Alice outspeeds Bob, and Bob should not have enough stamina after the effect's onApply trigger
     *  - So Bob's effect should fizzle
     *  - Wait 3 turns, Bob just does nothing, Alice does nothing
     *  - Wait for effect to end by itself
     *  - Check that Bob's mon has no more targeted effects
     */
    function test_panic() public {
        // Deploy an attack with panic
        IMoveSet panicAttack = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 1,
                STAMINA_COST: 1, // Does 1 damage, costs 1 stamina
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "PanicHit",
                EFFECT: panicStatus
            })
        );
        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = panicAttack;

        Mon memory fastMon = Mon({
            stats: MonStats({
                hp: 10,
                stamina: 5,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        Mon memory slowMon = Mon({
            stats: MonStats({
                hp: 10,
                stamina: 1, // Only 1 stamina
                speed: 1,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });
        Mon[] memory fastTeam = new Mon[](1);
        fastTeam[0] = fastMon;
        Mon[] memory slowTeam = new Mon[](1);
        slowTeam[0] = slowMon;

        // Register both teams
        defaultRegistry.setTeam(ALICE, fastTeam);
        defaultRegistry.setTeam(BOB, slowTeam);

        bytes32 battleKey = _startBattle(oneMonOneMoveValidator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move of the game has to be selecting their mons (both index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice and Bob both select attacks, both of them are move index 0 (inflict panic)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Both mons have inflicted panic
        (EffectInstance[] memory panicEffects0, ) = engine.getEffects(battleKey, 0, 0);
        (EffectInstance[] memory panicEffects1, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(panicEffects0.length, 1);
        assertEq(panicEffects1.length, 1);

        // Assert that both mons took 1 damage
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -1);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -1);

        // Assert that Alice's mon has a stamina delta of -2 (max stamina of 5)
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -2);

        // Assert that Bob's mon has a stamina delta of -1 (max stamina of 1)
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), -1);

        // Set the oracle to report back 1 for the next turn (we do not exit panic early)
        mockOracle.setRNG(1);

        // Alice and Bob both select attacks, both of them are no ops (we wait a turn)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        // Alice and Bob both select attacks, both of them are no ops (we wait another turn)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        // The panic effect should be over now
        (EffectInstance[] memory panicEffectsAfter, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(panicEffectsAfter.length, 0);
    }

    function test_burn() public {
        // Deploy an attack with burn status
        IMoveSet burnAttack = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "BurnHit",
                EFFECT: burnStatus
            })
        );

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = burnAttack;

        // Create mons with HP = 256 for easy division by 16 (burn damage denominator)
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 256,
                stamina: 10,
                speed: 5,
                attack: 32, // Use 32 for easy division by 2 (attack reduction denominator)
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        // Register both teams
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(oneMonOneMoveValidator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move of the game has to be selecting their mons (both index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice and Bob both select attacks, both of them are move index 0 (apply burn status)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Check that both mons have an effect length of 2 (including stat boost)
        (EffectInstance[] memory burnEffects0, ) = engine.getEffects(battleKey, 0, 0);
        (EffectInstance[] memory burnEffects1, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(burnEffects0.length, 2);
        assertEq(burnEffects1.length, 2);

        // Check that the attack of both mons was reduced by 50% (32/2 = 16)
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack), -16);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Attack), -16);

        // Check that both mons took 1/16 damage at end of round (256/16 = 16)
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -16);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -16);

        // Alice and Bob both select attacks again to increase burn degree
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Check that both mons still have an effect length of 2 (including stat boost)
        (EffectInstance[] memory effects0, ) = engine.getEffects(battleKey, 0, 0);
        (EffectInstance[] memory effects1, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects0.length, 2);
        assertEq(effects1.length, 2);

        // Check that both mons took additional 1/8 damage (256/8 = 32)
        // Total damage should be 16 (first round) + 32 (second round) = 48
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -48);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -48);

        // Alice and Bob both select attacks again to increase burn degree to maximum
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Check that both mons still have an effect length of 2
        (effects0, ) = engine.getEffects(battleKey, 0, 0);
        (effects1, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects0.length, 2);
        assertEq(effects1.length, 2);

        // Check that both mons took additional 1/4 damage (256/4 = 64)
        // Total damage should be 16 (first round) + 32 (second round) + 64 (third round) = 112
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -112);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -112);

        // Alice and Bob both select attacks again to increase burn degree to maximum
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Check that both mons still have an effect length of 2
        (effects0, ) = engine.getEffects(battleKey, 0, 0);
        (effects1, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects0.length, 2);
        assertEq(effects1.length, 2);

        // Check that both mons took another 1/4 damage (max burn degree)
        // Total damage should be 16 (first round) + 32 (second round) + 64 (third round) + 64 (fourth round) = 176
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -176);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -176);
    }

    function test_zap() public {
        // Deploy an attack with burn status
        IMoveSet fasterThanSwapZap = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: uint32(SWITCH_PRIORITY) + 1, // Make it faster than switching
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "ZapHitFast",
                EFFECT: zapStatus
            })
        );
        IMoveSet normalZap = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "ZapHit",
                EFFECT: zapStatus
            })
        );
        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = fasterThanSwapZap;
        moves[1] = normalZap;

        // Create mons with HP = 256 for easy division by 16 (burn damage denominator)
        Mon memory fastMon = Mon({
            stats: MonStats({
                hp: 256,
                stamina: 10,
                speed: 5,
                attack: 32, // Use 32 for easy division by 2 (attack reduction denominator)
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });
        Mon memory slowMon = Mon({
            stats: MonStats({
                hp: 256,
                stamina: 10,
                speed: 1,
                attack: 32, // Use 32 for easy division by 2 (attack reduction denominator)
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        Mon[] memory fastTeam = new Mon[](2);
        fastTeam[0] = fastMon;
        fastTeam[1] = fastMon;

        Mon[] memory slowTeam = new Mon[](2);
        slowTeam[0] = slowMon;
        slowTeam[1] = slowMon;

        // Register both teams
        defaultRegistry.setTeam(ALICE, fastTeam);
        defaultRegistry.setTeam(BOB, slowTeam);

        DefaultValidator validatorTouse = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 2, TIMEOUT_DURATION: TIMEOUT_DURATION})
        );

        bytes32 battleKey = _startBattle(validatorTouse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move of the game has to be selecting their mons (both index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice and Bob both select attacks, both of them are move index 0 (apply zap status)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // But Alice should outspeed Bob, so Bob should have zero stamina delta
        // Whereas Alice should have -1 stamina delta
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -1);

        // Alice uses Zap, Bob switches to mon index 1
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, SWITCH_MOVE_INDEX, 0, uint240(1));

        // The move should outspeed the swap, so the swap doesn't happen
        // So Bob's active mon index should still be 0
        assertEq(engine.getActiveMonIndexForBattleState(battleKey)[1], 0);

        // Alice uses slower Zap, Bob switches to mon index 1
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, SWITCH_MOVE_INDEX, 0, uint240(1));

        // Bob's active mon index should be 1 (swap goes before getting Zapped)
        assertEq(engine.getActiveMonIndexForBattleState(battleKey)[1], 1);

        // Bob's active mon should have the Zap effect
        (EffectInstance[] memory zapEffects, ) = engine.getEffects(battleKey, 1, 1);
        assertEq(zapEffects.length, 1);

        // Alice does nothing, Bob attempts to switch to mon index 1
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, uint240(0));

        // Nothing happens because the Zap occurred
        // Check that Bob's active mon index is still 1 and the effect is removed
        assertEq(engine.getActiveMonIndexForBattleState(battleKey)[1], 1);
        (EffectInstance[] memory zapEffectsAfter, ) = engine.getEffects(battleKey, 1, 1);
        assertEq(zapEffectsAfter.length, 0);
    }

    function test_staminaRegen() public {
        StaminaRegen regen = new StaminaRegen(engine);
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = regen;
        DefaultRuleset rules = new DefaultRuleset(engine, effects);

        // Deploy an attack that does 0 damage but consumes 5 stamina
        IMoveSet noDamageAttack = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 5,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "NoDamage",
                EFFECT: IEffect(address(0))
            })
        );

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = noDamageAttack;
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 20,
                stamina: 10,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 20,
                specialDefense: 1,
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

        bytes32 battleKey = _startBattle(
            oneMonOneMoveValidator, engine, mockOracle, defaultRegistry, matchmaker, new IEngineHook[](0), rules, address(commitManager)
        );

        // First move of the game has to be selecting their mons (both index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses NoDamage, Bob does as well
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Both should have -4 stamina delta because of end of turn regen
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -4);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), -4);

        // Both players No Op, and this should heal them by an extra 1 stamina
        // So at end of turn, both players should have -2 stamina delta
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -2);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), -2);
    }

    function test_onUpdateMonStateHook() public {
        // Import the mock effect and move
        OnUpdateMonStateHealEffect healEffect = new OnUpdateMonStateHealEffect(engine);
        EffectAbility healAbility = new EffectAbility(engine, healEffect);
        ReduceSpAtkMove reduceSpAtkMove = new ReduceSpAtkMove(engine);

        // Create a mon with the ReduceSpAtkMove for Alice
        IMoveSet[] memory aliceMoves = new IMoveSet[](1);
        aliceMoves[0] = reduceSpAtkMove;
        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 20,
                stamina: 10,
                speed: 5,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Mind,
                type2: Type.None
            }),
            moves: aliceMoves,
            ability: IAbility(address(0))
        });

        // Create a mon with the heal effect ability for Bob
        // This mon should heal when its SpecialAttack is reduced
        IMoveSet[] memory bobMoves = new IMoveSet[](1);
        bobMoves[0] = IMoveSet(address(0)); // Bob won't attack
        Mon memory bobMon = Mon({
            stats: MonStats({
                hp: 20,
                stamina: 10,
                speed: 3,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: bobMoves,
            ability: healAbility // Bob has the heal effect
        });

        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;

        // Register teams
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(oneMonOneMoveValidator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: both switch in their mons
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Verify Bob's mon has the heal effect applied (from ability on switch in)
        (EffectInstance[] memory bobEffects, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(bobEffects.length, 1, "Bob should have 1 effect");

        // Get Bob's initial HP (should be 0 delta since no damage dealt yet)
        int32 bobHpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(bobHpBefore, 0, "Bob should have 0 HP delta initially");

        // Get Bob's initial SpATK (should be 0 delta)
        int32 bobSpAtkBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.SpecialAttack);
        assertEq(bobSpAtkBefore, 0, "Bob should have 0 SpATK delta initially");

        // Alice uses ReduceSpAtkMove to reduce Bob's SpecialAttack
        // Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Get Bob's state after the move
        int32 bobHpAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int32 bobSpAtkAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.SpecialAttack);

        // Verify that Bob's SpecialAttack was reduced by 1
        assertEq(bobSpAtkAfter, -1, "Bob's SpATK should be reduced by 1");

        // Verify that the OnUpdateMonState effect triggered and healed Bob by 5 HP
        assertEq(bobHpAfter, 5, "Bob should be healed by 5 HP when SpATK is reduced");
    }
}
