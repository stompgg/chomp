// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../lib/forge-std/src/Test.sol";

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {Engine} from "../../src/Engine.sol";
import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";
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
import {DirectStatWriteMove} from "../mocks/DirectStatWriteMove.sol";
import {EffectAbility} from "../mocks/EffectAbility.sol";
import {OnUpdateMonStateHealEffect} from "../mocks/OnUpdateMonStateHealEffect.sol";
import {ReduceSpAtkMove} from "../mocks/ReduceSpAtkMove.sol";

contract EffectTest is Test, BattleHelper {
    DefaultCommitManager commitManager;
    Engine engine;
    ITypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;

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
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        commitManager = new DefaultCommitManager(engine);
        typeCalc = new TestTypeCalculator();
        defaultRegistry = new TestTeamRegistry();

        // Deploy StandardAttackFactory
        standardAttackFactory = new StandardAttackFactory(typeCalc);

        // Deploy all effects
        frostbiteStatus = new FrostbiteStatus();
        sleepStatus = new SleepStatus();
        panicStatus = new PanicStatus();
        burnStatus = new BurnStatus();
        zapStatus = new ZapStatus();
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

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(frostbiteAttack)));
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
            ability: 0
        });
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        // Register both teams
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move of the game has to be selecting their mons (both index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice and Bob both select attacks, both of them are move index 0 (do frostbite damage)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Both mons carry the frostbite status; its SpAtk debuff lives in the boost store, not
        // the effect list (boost sources are no longer effect entries).
        (EffectInstance[] memory effects0,) = engine.getEffects(battleKey, 0, 0);
        (EffectInstance[] memory effects1,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects0.length, 1);
        assertEq(effects1.length, 1);

        // Check that both mons took 1 damage (we should round down)
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -1);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -1);

        // Check that the special attack of both mons was reduced by 50%
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack), -10);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.SpecialAttack), -10);

        // Alice and Bob both select attacks, both of them are move index 0 (do frostbite damage)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Check that both mons still carry exactly the status entry
        (effects0,) = engine.getEffects(battleKey, 0, 0);
        (effects1,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects0.length, 1);
        assertEq(effects1.length, 1);

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

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(frostbiteAttack)));
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
            ability: 0
        });
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        // Register both teams
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move of the game has to be selecting their mons (both index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice switches to mon index 1, Bob induces frostbite
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, 0, uint16(1), 0);

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

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(sleepAttack)));

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

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -1);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), 0);
        mockOracle.setRNG(1);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -1);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), 0);
        mockOracle.setRNG(2);
        // Bob wakes up, inflicts on Alice
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -1);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), -1);
        // Alice is asleep, Bob does nothing, Alice switches to mon index 1, should be successful
        mockOracle.setRNG(1);
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(1), 0
        );
        assertEq(engine.getBattleContext(battleKey).p0ActiveMonIndex, 1);
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
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(panicAttack)));

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
            ability: 0
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
            ability: 0
        });
        Mon[] memory fastTeam = new Mon[](1);
        fastTeam[0] = fastMon;
        Mon[] memory slowTeam = new Mon[](1);
        slowTeam[0] = slowMon;

        // Register both teams
        defaultRegistry.setTeam(ALICE, fastTeam);
        defaultRegistry.setTeam(BOB, slowTeam);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move of the game has to be selecting their mons (both index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice and Bob both select attacks, both of them are move index 0 (inflict panic)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Both mons have inflicted panic
        (EffectInstance[] memory panicEffects0,) = engine.getEffects(battleKey, 0, 0);
        (EffectInstance[] memory panicEffects1,) = engine.getEffects(battleKey, 1, 0);
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
        (EffectInstance[] memory panicEffectsAfter,) = engine.getEffects(battleKey, 1, 0);
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

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(burnAttack)));

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
            ability: 0
        });

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        // Register both teams
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move of the game has to be selecting their mons (both index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice and Bob both select attacks, both of them are move index 0 (apply burn status)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Both mons carry the burn status; its attack debuff lives in the boost store, not the
        // effect list (boost sources are no longer effect entries).
        (EffectInstance[] memory burnEffects0,) = engine.getEffects(battleKey, 0, 0);
        (EffectInstance[] memory burnEffects1,) = engine.getEffects(battleKey, 1, 0);
        assertEq(burnEffects0.length, 1);
        assertEq(burnEffects1.length, 1);

        // Check that the attack of both mons was reduced by 50% (32/2 = 16)
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack), -16);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Attack), -16);

        // Check that both mons took 1/16 damage at end of round (256/16 = 16)
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -16);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -16);

        // Alice and Bob both select attacks again to increase burn degree
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Check that both mons still carry exactly the status entry (debuff is store-side)
        (EffectInstance[] memory effects0,) = engine.getEffects(battleKey, 0, 0);
        (EffectInstance[] memory effects1,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects0.length, 1);
        assertEq(effects1.length, 1);

        // Check that both mons took additional 1/8 damage (256/8 = 32)
        // Total damage should be 16 (first round) + 32 (second round) = 48
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -48);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -48);

        // Alice and Bob both select attacks again to increase burn degree to maximum
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Check that both mons still carry exactly the status entry
        (effects0,) = engine.getEffects(battleKey, 0, 0);
        (effects1,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects0.length, 1);
        assertEq(effects1.length, 1);

        // Check that both mons took additional 1/4 damage (256/4 = 64)
        // Total damage should be 16 (first round) + 32 (second round) + 64 (third round) = 112
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -112);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -112);

        // Alice and Bob both select attacks again to increase burn degree to maximum
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Check that both mons still carry exactly the status entry
        (effects0,) = engine.getEffects(battleKey, 0, 0);
        (effects1,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects0.length, 1);
        assertEq(effects1.length, 1);

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
        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(fasterThanSwapZap)));
        moves[1] = uint256(uint160(address(normalZap)));

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
            ability: 0
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
            ability: 0
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

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move of the game has to be selecting their mons (both index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice and Bob both select attacks, both of them are move index 0 (apply zap status)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // But Alice should outspeed Bob, so Bob should have zero stamina delta
        // Whereas Alice should have -1 stamina delta
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -1);

        // Alice uses Zap, Bob switches to mon index 1
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, SWITCH_MOVE_INDEX, 0, uint16(1));

        // The move should outspeed the swap, so the swap doesn't happen
        // So Bob's active mon index should still be 0
        assertEq(engine.getBattleContext(battleKey).p1ActiveMonIndex, 0);

        // Alice uses slower Zap, Bob switches to mon index 1
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, SWITCH_MOVE_INDEX, 0, uint16(1));

        // Bob's active mon index should be 1 (swap goes before getting Zapped)
        assertEq(engine.getBattleContext(battleKey).p1ActiveMonIndex, 1);

        // Bob's active mon should have the Zap effect
        (EffectInstance[] memory zapEffects,) = engine.getEffects(battleKey, 1, 1);
        assertEq(zapEffects.length, 1);

        // Alice does nothing, Bob attempts to switch to mon index 1, which should succeed because Zap allows switches
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, uint16(0)
        );

        // Check that Bob's active mon index is now 0, and the effect is still there
        assertEq(engine.getBattleContext(battleKey).p1ActiveMonIndex, 0);
        (EffectInstance[] memory zapEffectsAfter,) = engine.getEffects(battleKey, 1, 1);
        assertEq(zapEffectsAfter.length, 1);

        // Bob switches back to mon index 1, Alice does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, uint16(1)
        );

        // Bob tries to make a move, Alice does nothing, Zap should skip his turn
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Check that zap is now gone
        (EffectInstance[] memory zapEffectsAfterRoundEnd,) = engine.getEffects(battleKey, 1, 1);
        assertEq(zapEffectsAfterRoundEnd.length, 0);
    }

    function test_staminaRegen() public {
        StaminaRegen regen = new StaminaRegen();
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

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(noDamageAttack)));
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
            ability: 0
        });

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(
            engine, mockOracle, defaultRegistry, matchmaker, new IEngineHook[](0), rules, address(commitManager)
        );

        // First move of the game has to be selecting their mons (both index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
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
        OnUpdateMonStateHealEffect healEffect = new OnUpdateMonStateHealEffect();
        EffectAbility healAbility = new EffectAbility(healEffect);
        ReduceSpAtkMove reduceSpAtkMove = new ReduceSpAtkMove();

        // Create a mon with the ReduceSpAtkMove for Alice
        uint256[] memory aliceMoves = new uint256[](1);
        aliceMoves[0] = uint256(uint160(address(reduceSpAtkMove)));
        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 20,
                stamina: 10,
                speed: 5,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Math,
                type2: Type.None
            }),
            moves: aliceMoves,
            ability: 0
        });

        // Create a mon with the heal effect ability for Bob
        // This mon should heal when its SpecialAttack is reduced
        uint256[] memory bobMoves = new uint256[](1);
        bobMoves[0] = uint256(uint160(address(0))); // Bob won't attack
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
            ability: uint160(address(healAbility)) // Bob has the heal effect
        });

        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;

        // Register teams
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: both switch in their mons
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Verify Bob's mon has the heal effect applied (from ability on switch in)
        (EffectInstance[] memory bobEffects,) = engine.getEffects(battleKey, 1, 0);
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

    // Stats are owned by the inlined stat-boost system: a direct updateMonState on a stat delta
    // (here Attack, via a move) must revert so it can't silently clobber the boost aggregation.
    function test_directStatWriteIsRejected() public {
        DirectStatWriteMove badMove = new DirectStatWriteMove();
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(badMove)));
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 20,
                stamina: 10,
                speed: 5,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Math,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });
        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Switch both mons in (turnId 0 -> 1).
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Move turn (turnId 1, odd): BOB commits, ALICE reveals, then BOB's reveal auto-executes —
        // the move's direct stat write makes execute revert with StatRequiresStatBoost.
        uint8 mv = 0;
        uint104 salt = 0;
        uint16 ed = 0;
        vm.startPrank(BOB);
        commitManager.commitMove(battleKey, keccak256(abi.encodePacked(mv, salt, ed)));
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, mv, salt, ed, true);
        vm.startPrank(BOB);
        vm.expectRevert(Engine.StatRequiresStatBoost.selector);
        commitManager.revealMove(battleKey, mv, salt, ed, true);
        vm.stopPrank();
        engine.resetCallContext();
    }

    // ------------------------------------------------------------------
    // One-sleeper-per-player gate (SleepStatus global sleep key)
    // ------------------------------------------------------------------

    /// @dev Mirrors SleepStatus._globalSleepKey.
    function _sleepGlobalKey(uint256 targetIndex) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encodePacked("Sleep", targetIndex))));
    }

    /// @dev Finds an oracle rng value whose SleepStatus.onRoundStart wake roll for
    ///      (targetIndex, monIndex) matches `wantWake`.
    function _sleepRngFor(bool wantWake, uint256 targetIndex, uint256 monIndex) internal pure returns (uint256) {
        for (uint256 r = 1; r < 100; r++) {
            bool wakes = uint256(keccak256(abi.encode(r, targetIndex, monIndex))) % 3 == 0;
            if (wakes == wantWake) {
                return r;
            }
        }
        revert("no rng found");
    }

    function _makeSleepAttack() internal returns (IMoveSet) {
        return standardAttackFactory.createAttack(
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
                NAME: "SleepHit",
                EFFECT: sleepStatus
            })
        );
    }

    /// @dev Two 2-mon teams; Alice's mons are faster so her sleep lands before Bob acts.
    ///      Every mon carries [sleepAttack, koAttack] so tests can also KO (validator allows 2 moves).
    function _setupSleepGateBattle() internal returns (bytes32 battleKey) {
        IMoveSet sleepAttack = _makeSleepAttack();
        IMoveSet koAttack = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 100,
                STAMINA_COST: 0,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Ice,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "KOHit",
                EFFECT: IEffect(address(0))
            })
        );
        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(sleepAttack)));
        moves[1] = uint256(uint160(address(koAttack)));

        Mon memory fastMon = _createMon();
        fastMon.moves = moves;
        fastMon.stats.speed = 2;
        fastMon.stats.stamina = 5;
        Mon memory slowMon = _createMon();
        slowMon.moves = moves;
        slowMon.stats.stamina = 5;

        Mon[] memory fastTeam = new Mon[](2);
        fastTeam[0] = fastMon;
        fastTeam[1] = fastMon;
        Mon[] memory slowTeam = new Mon[](2);
        slowTeam[0] = slowMon;
        slowTeam[1] = slowMon;
        defaultRegistry.setTeam(ALICE, fastTeam);
        defaultRegistry.setTeam(BOB, slowTeam);

        battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
    }

    function test_sleepOnePerPlayer_blocksSecondSleeper() public {
        bytes32 battleKey = _setupSleepGateBattle();

        // Turn 1: Alice sleeps Bob's mon 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        (EffectInstance[] memory bobMon0Effects,) = engine.getEffects(battleKey, 1, 0);
        assertEq(bobMon0Effects.length, 1, "Bob's mon 0 should be asleep");
        // The player-1 sleeper flag points at mon 0 (value = [monIndex+1 | sleepStatus address])
        uint192 flag = engine.getGlobalKV(battleKey, _sleepGlobalKey(1));
        assertEq(address(uint160(flag)), address(sleepStatus), "sleeper flag should carry the status address");
        assertEq(uint256(flag >> 160), 1, "sleeper flag should point at mon 0");

        // Turn 2: Bob switches to mon 1 (mon 0 stays asleep on the bench)
        mockOracle.setRNG(_sleepRngFor(false, 1, 0));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, 1);

        // Turn 3: Alice tries to sleep Bob's mon 1 — blocked, only one sleeper per player
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        (EffectInstance[] memory bobMon1Effects,) = engine.getEffects(battleKey, 1, 1);
        assertEq(bobMon1Effects.length, 0, "second sleeper on the same player should be blocked");
    }

    function test_sleepOnePerPlayer_allowsNewSleeperAfterWake() public {
        bytes32 battleKey = _setupSleepGateBattle();

        // Turn 1: Alice sleeps Bob's mon 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Turn 2: Bob's mon wakes early (rng chosen to trigger the wake roll)
        mockOracle.setRNG(_sleepRngFor(true, 1, 0));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 0, "mon 0 should have woken");
        assertEq(uint256(engine.getGlobalKV(battleKey, _sleepGlobalKey(1))), 0, "sleeper flag should clear on wake");

        // Turn 3: Alice sleeps Bob's mon 0 again — allowed now that the previous sleep ended
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        (effects,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 1, "re-sleep after wake should apply");
    }

    function test_sleepOnePerPlayer_koReleasesGate() public {
        bytes32 battleKey = _setupSleepGateBattle();

        // Turn 1: Alice sleeps Bob's mon 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Turn 2: Alice KOs the sleeping mon 0 (no early wake)
        mockOracle.setRNG(_sleepRngFor(false, 1, 0));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 1);

        // Turn 3 (single-player): Bob switches in mon 1
        vm.startPrank(BOB);
        _revealMoveAndReset(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, 0, 1);

        // Turn 4: Alice sleeps mon 1 — allowed because the registered sleeper (mon 0) is KO'd
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        (EffectInstance[] memory bobMon1Effects,) = engine.getEffects(battleKey, 1, 1);
        assertEq(bobMon1Effects.length, 1, "gate should release when the registered sleeper is KO'd");
        uint192 flag = engine.getGlobalKV(battleKey, _sleepGlobalKey(1));
        assertEq(uint256(flag >> 160), 2, "sleeper flag should now point at mon 1");
    }
}
