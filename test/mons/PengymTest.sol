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

import {FrostbiteStatus} from "../../src/effects/status/FrostbiteStatus.sol";
import {PanicStatus} from "../../src/effects/status/PanicStatus.sol";
import {PostWorkout} from "../../src/mons/pengym/PostWorkout.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";

import {BattleHelper} from "../abstract/BattleHelper.sol";

import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {StatBoosts} from "../../src/effects/StatBoosts.sol";
import {StandardAttack} from "../../src/moves/StandardAttack.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";

import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {ChillOut} from "../../src/mons/pengym/ChillOut.sol";
import {DeepFreeze} from "../../src/mons/pengym/DeepFreeze.sol";
import {PistolSquat} from "../../src/mons/pengym/PistolSquat.sol";

contract PengymTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultValidator validator;
    StandardAttackFactory attackFactory;
    PostWorkout postWorkout;
    PanicStatus panicStatus;
    FrostbiteStatus frostbiteStatus;
    StatBoosts statBoost;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine();
        validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        attackFactory = new StandardAttackFactory(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        postWorkout = new PostWorkout(IEngine(address(engine)));
        panicStatus = new PanicStatus(IEngine(address(engine)));
        statBoost = new StatBoosts(IEngine(address(engine)));
        frostbiteStatus = new FrostbiteStatus(IEngine(address(engine)), statBoost);
        matchmaker = new DefaultMatchmaker(engine);
    }

    function test_postWorkoutClearsPanicStatusAndGainsStamina() public {
        // Create an attack that inflicts PanicStatus with 100% chance
        StandardAttack panicAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0, // No damage
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 0,
                MOVE_TYPE: Type.Water,
                EFFECT_ACCURACY: 100, // 100% chance to inflict status
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Panic Inflict",
                EFFECT: IEffect(address(panicStatus))
            })
        );

        // Create a standard attack for the second mon
        StandardAttack standardAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 5,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 0,
                MOVE_TYPE: Type.Nature,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Standard Attack",
                EFFECT: IEffect(address(0))
            })
        );

        // Create Alice's team: one mon with PostWorkout ability and one regular mon
        IMoveSet[] memory aliceMon1Moves = new IMoveSet[](1);
        aliceMon1Moves[0] = standardAttack;

        IMoveSet[] memory aliceMon2Moves = new IMoveSet[](1);
        aliceMon2Moves[0] = standardAttack;

        Mon memory postWorkoutMon = Mon({
            stats: MonStats({
                hp: 10,
                stamina: 5,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Water,
                type2: Type.None
            }),
            moves: aliceMon1Moves,
            ability: IAbility(address(postWorkout))
        });

        Mon memory regularMon = Mon({
            stats: MonStats({
                hp: 10,
                stamina: 5,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Metal,
                type2: Type.None
            }),
            moves: aliceMon2Moves,
            ability: IAbility(address(0))
        });

        // Create Bob's team: one mon with PanicStatus attack and one regular mon
        IMoveSet[] memory bobMon1Moves = new IMoveSet[](1);
        bobMon1Moves[0] = panicAttack;

        IMoveSet[] memory bobMon2Moves = new IMoveSet[](1);
        bobMon2Moves[0] = standardAttack;

        Mon memory bobPanicMon = Mon({
            stats: MonStats({
                hp: 10,
                stamina: 5,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: bobMon1Moves,
            ability: IAbility(address(0))
        });

        // Set up teams
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = postWorkoutMon; // First mon has PostWorkout ability
        aliceTeam[1] = regularMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobPanicMon; // First mon has PanicStatus attack
        bobTeam[1] = regularMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Check that Alice's mon has the PostWorkout effect
        (EffectInstance[] memory aliceEffects, ) = engine.getEffects(battleKey, 0, 0);
        bool hasPostWorkoutEffect = false;
        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (aliceEffects[i].effect == IEffect(address(postWorkout))) {
                hasPostWorkoutEffect = true;
                break;
            }
        }
        assertTrue(hasPostWorkoutEffect, "Alice's mon should have PostWorkout effect");

        // Bob uses PanicStatus attack on Alice's mon
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Set the rng to be 1 (so no early panic exit)
        mockOracle.setRNG(1);

        // Check that Alice's mon has the PanicStatus effect
        (aliceEffects, ) = engine.getEffects(battleKey, 0, 0);
        bool hasPanicEffect = false;
        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (aliceEffects[i].effect == IEffect(address(panicStatus))) {
                hasPanicEffect = true;
                break;
            }
        }
        assertTrue(hasPanicEffect, "Alice's mon should have PanicStatus effect");

        // Get current stamina before switching
        int32 staminaBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);

        // Alice switches to her second mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(1), 0
        );

        // Alice switches back to her first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(0), 0
        );

        // Check that Alice's mon no longer has the PanicStatus effect
        (aliceEffects, ) = engine.getEffects(battleKey, 0, 0);
        hasPanicEffect = false;

        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (aliceEffects[i].effect == IEffect(address(panicStatus))) {
                hasPanicEffect = true;
                break;
            }
        }
        assertFalse(hasPanicEffect, "Alice's mon should not have PanicStatus effect after switching");

        // Check that Alice's mon gained 1 stamina
        int32 staminaAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        assertEq(staminaAfter, staminaBefore + 1, "Alice's mon should gain 1 stamina after switching with status");
    }

    function test_postWorkoutClearsFrostbiteStatusAndGainsStamina() public {
        // Create an attack that inflicts FrostbiteStatus with 100% chance
        StandardAttack frostbiteAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0, // No damage
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 0,
                MOVE_TYPE: Type.Ice,
                EFFECT_ACCURACY: 100, // 100% chance to inflict status
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Frostbite Inflict",
                EFFECT: IEffect(address(frostbiteStatus))
            })
        );

        // Create a standard attack for the second mon
        StandardAttack standardAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 5,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 0,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Standard Attack",
                EFFECT: IEffect(address(0))
            })
        );

        // Create Alice's team: one mon with PostWorkout ability and one regular mon
        IMoveSet[] memory aliceMon1Moves = new IMoveSet[](1);
        aliceMon1Moves[0] = standardAttack;

        IMoveSet[] memory aliceMon2Moves = new IMoveSet[](1);
        aliceMon2Moves[0] = standardAttack;

        Mon memory postWorkoutMon = Mon({
            stats: MonStats({
                hp: 10,
                stamina: 5,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 10, // Higher special attack to test Frostbite effect
                specialDefense: 5,
                type1: Type.Water,
                type2: Type.None
            }),
            moves: aliceMon1Moves,
            ability: IAbility(address(postWorkout))
        });

        Mon memory regularMon = Mon({
            stats: MonStats({
                hp: 10,
                stamina: 5,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: aliceMon2Moves,
            ability: IAbility(address(0))
        });

        // Create Bob's team: one mon with FrostbiteStatus attack and one regular mon
        IMoveSet[] memory bobMon1Moves = new IMoveSet[](1);
        bobMon1Moves[0] = frostbiteAttack;

        IMoveSet[] memory bobMon2Moves = new IMoveSet[](1);
        bobMon2Moves[0] = standardAttack;

        Mon memory bobFrostbiteMon = Mon({
            stats: MonStats({
                hp: 10,
                stamina: 5,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Ice,
                type2: Type.None
            }),
            moves: bobMon1Moves,
            ability: IAbility(address(0))
        });

        // Set up teams
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = postWorkoutMon; // First mon has PostWorkout ability
        aliceTeam[1] = regularMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobFrostbiteMon; // First mon has FrostbiteStatus attack
        bobTeam[1] = regularMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Check that Alice's mon has the PostWorkout effect
        (EffectInstance[] memory aliceEffects, ) = engine.getEffects(battleKey, 0, 0);
        bool hasPostWorkoutEffect = false;
        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (aliceEffects[i].effect == IEffect(address(postWorkout))) {
                hasPostWorkoutEffect = true;
                break;
            }
        }
        assertTrue(hasPostWorkoutEffect, "Alice's mon should have PostWorkout effect");

        // Get initial special attack value
        int32 specialAttackBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);

        // Bob uses FrostbiteStatus attack on Alice's mon
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Check that Alice's mon has the FrostbiteStatus effect
        (aliceEffects, ) = engine.getEffects(battleKey, 0, 0);
        bool hasFrostbiteEffect = false;
        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (aliceEffects[i].effect == IEffect(address(frostbiteStatus))) {
                hasFrostbiteEffect = true;
                break;
            }
        }
        assertTrue(hasFrostbiteEffect, "Alice's mon should have FrostbiteStatus effect");

        // Check that special attack was reduced
        int32 specialAttackAfterFrostbite =
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        assertTrue(specialAttackAfterFrostbite < specialAttackBefore, "Special attack should be reduced by Frostbite");

        // Get current stamina before switching
        int32 staminaBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);

        // Alice switches to her second mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(1), 0
        );

        // Alice switches back to her first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(0), 0
        );

        // Check that Alice's mon no longer has the FrostbiteStatus effect
        (aliceEffects, ) = engine.getEffects(battleKey, 0, 0);
        hasFrostbiteEffect = false;
        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (aliceEffects[i].effect == IEffect(address(frostbiteStatus))) {
                hasFrostbiteEffect = true;
                break;
            }
        }
        assertFalse(hasFrostbiteEffect, "Alice's mon should not have FrostbiteStatus effect after switching");

        // Check that Alice's mon gained 1 stamina
        int32 staminaAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        assertEq(staminaAfter, staminaBefore + 1, "Alice's mon should gain 1 stamina after switching with status");

        // Check that special attack was restored
        int32 specialAttackAfterCure = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        assertTrue(
            specialAttackAfterCure > specialAttackAfterFrostbite,
            "Special attack should be restored after Frostbite is cured"
        );
    }

    function test_chillOutAndDeepFreeze() public {
        // Create a new validator with 2 moves per mon
        DefaultValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        ChillOut chillOut = new ChillOut(engine, typeCalc, frostbiteStatus);
        DeepFreeze deepFreeze = new DeepFreeze(engine, typeCalc, frostbiteStatus);

        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = chillOut;
        moves[1] = deepFreeze;

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 10,
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

        // Alice deals damage to Bob, record the damage dealt
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );
        int32 deepFreezeDamage = -1 * engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        // Alice inflicts frostbite on Bob, Bob does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );

        int32 bobDamageBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        // Alice uses deep freeze, record the damage dealt
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );

        int32 bobDamageAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int32 deepFreezeDoubleDamage = (-1 * bobDamageAfter) + bobDamageBefore;

        // Damage dealt should be greater
        assertGt(deepFreezeDoubleDamage, deepFreezeDamage, "Should have dealt more");

        // Frostbite should be cleared, and its associated StatBoost should also be removed
        (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 0, "Frostbite and its StatBoost should be cleared");
    }

    function test_pistolSquat() public {
        DefaultValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 4, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );
        PistolSquat ps = new PistolSquat(engine, typeCalc);
        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = ps;
        moves[1] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 100, // designed to auto KO
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Water,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "test",
                EFFECT: IEffect(address(0))
            })
        );
        Mon memory slowMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 100,
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
                hp: 100,
                stamina: 100,
                speed: 11,
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
        Mon[] memory aliceTeam = new Mon[](4);
        aliceTeam[0] = slowMon;
        aliceTeam[1] = slowMon;
        aliceTeam[2] = slowMon;
        aliceTeam[3] = slowMon;

        Mon[] memory bobTeam = new Mon[](4);
        bobTeam[0] = fastMon;
        bobTeam[1] = fastMon;
        bobTeam[2] = fastMon;
        bobTeam[3] = fastMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice selects pistol squat, Bob selects move index 1 and outspeeds
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 1, uint240(0), uint240(0));

        // Alice should be KO'ed
        int32 koFlag = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut);
        assertEq(koFlag, 1, "Alice should be KO'ed");

        // Alice swaps to mon index 1
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(1), true);

        // Alice selects pistol squat, Bob does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Active mon for Bob should be 1
        uint256 bobActiveMonIndex = engine.getActiveMonIndexForBattleState(battleKey)[1];
        assertEq(bobActiveMonIndex, 1, "Swap succeeded (0 -> 1)");

        // Alice selects pistol squat, Bob does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Active mon for Bob should be 0
        bobActiveMonIndex = engine.getActiveMonIndexForBattleState(battleKey)[1];
        assertEq(bobActiveMonIndex, 0, "Swap succeeded (1 -> 0)");

        // Alice selects pistol squat, Bob does nothing (and dies)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );

        bobActiveMonIndex = engine.getActiveMonIndexForBattleState(battleKey)[1];
        assertEq(bobActiveMonIndex, 0, "No swap because KO");

        // Bob sends in mon index 1
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(1), true);

        // Alice selects pistol squat, Bob does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Now Bob's mon index 1 is KOed
        // Bob sends in mon index 2
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(2), true);

        // Alice selects pistol squat, Bob does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Now Bob has mon index 2 (already took damage) and mon index 3
        bobActiveMonIndex = engine.getActiveMonIndexForBattleState(battleKey)[1];
        assertEq(bobActiveMonIndex, 3, "Switch forced");

        // Bob switches back to mon index 2, Alice does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(2)
        );

        // Alice KOs Bob's mon index 2
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Bob sends in mon index 3
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, "", uint240(3), true);

        // Alice tries to force a switch, but active mon should not change
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );
        bobActiveMonIndex = engine.getActiveMonIndexForBattleState(battleKey)[1];
        assertEq(bobActiveMonIndex, 3, "No mons left");
    }
}
