// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import "../../src/Constants.sol";
import "../../src/Structs.sol";

import {DefaultCommitManager} from "../../src/DefaultCommitManager.sol";
import {DefaultValidator} from "../../src/DefaultValidator.sol";
import {Engine} from "../../src/Engine.sol";
import {MonStateIndexName, MoveClass, Type} from "../../src/Enums.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IEngineHook} from "../../src/IEngineHook.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {IRuleset} from "../../src/IRuleset.sol";
import {DefaultRuleset} from "../../src/DefaultRuleset.sol";
import {SleepStatus} from "../../src/effects/status/SleepStatus.sol";
import {StaminaRegen} from "../../src/effects/StaminaRegen.sol";
import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {StandardAttack} from "../../src/moves/StandardAttack.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";
import {BattleHelper} from "../abstract/BattleHelper.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

// Xmon moves and abilities
import {ContagiousSlumber} from "../../src/mons/xmon/ContagiousSlumber.sol";
import {VitalSiphon} from "../../src/mons/xmon/VitalSiphon.sol";
import {Somniphobia} from "../../src/mons/xmon/Somniphobia.sol";
import {Dreamcatcher} from "../../src/mons/xmon/Dreamcatcher.sol";
import {NightTerrors} from "../../src/mons/xmon/NightTerrors.sol";

/**
    - Contagious Slumber adds Sleep effect to both mons [x]
    - Vital Siphon drains stamina only when opponent has at least 1 stamina [x]
    - Somniphobia correctly damages both mons if they choose to NO_OP [x]
    - Dreamcatcher heals on stamina gain [x]
    - Night Terrors doesn't trigger when terror stacks > available stamina [ ]
    - Night Terrors effect clears on swap [ ]
    - Night Terrors damage differs when opponent is asleep vs awake [ ]
 */

contract XmonTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;
    StandardAttackFactory attackFactory;

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine();
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        matchmaker = new DefaultMatchmaker(engine);
        attackFactory = new StandardAttackFactory(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
    }

    function test_contagiousSlumberAppliesSleepToBothMons() public {
        SleepStatus sleepStatus = new SleepStatus(IEngine(address(engine)));
        ContagiousSlumber contagiousSlumber = new ContagiousSlumber(IEngine(address(engine)), IEffect(address(sleepStatus)));

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = contagiousSlumber;

        Mon memory mon = _createMon();
        mon.moves = moves;
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses Contagious Slumber, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify that both Alice and Bob have Sleep status
        (EffectInstance[] memory aliceEffects, ) = engine.getEffects(battleKey, 0, 0);
        (EffectInstance[] memory bobEffects, ) = engine.getEffects(battleKey, 1, 0);

        bool aliceHasSleep = false;
        bool bobHasSleep = false;

        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (address(aliceEffects[i].effect) == address(sleepStatus)) {
                aliceHasSleep = true;
                break;
            }
        }

        for (uint256 i = 0; i < bobEffects.length; i++) {
            if (address(bobEffects[i].effect) == address(sleepStatus)) {
                bobHasSleep = true;
                break;
            }
        }

        assertTrue(aliceHasSleep, "Alice should have Sleep status");
        assertTrue(bobHasSleep, "Bob should have Sleep status");
    }

    function test_vitalSiphonDrainsStaminaOnlyWhenOpponentHasStamina() public {
        VitalSiphon vitalSiphon = new VitalSiphon(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));

        // Create a stamina-draining attack to reduce Bob's stamina to 0
        StandardAttack nullMove = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 4,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Stamina Drain",
                EFFECT: IEffect(address(0))
            })
        );

        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = vitalSiphon;
        moves[1] = nullMove;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = vitalSiphon.basePower("") * 4;
        mon.stats.stamina = 5; // Enough stamina for multiple moves
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Set RNG to guarantee stamina steal (>= 50)
        mockOracle.setRNG(50);

        // Alice uses Vital Siphon, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify that Bob's stamina was drained by 1 and Alice gained 1
        int32 bobStaminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        int32 aliceStaminaDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);

        // Alice spent 2 stamina for the move, gained 1 back = -1
        // Bob gained 1 from rest, lost 1 from drain = 0
        assertEq(aliceStaminaDelta, 1 - int32(vitalSiphon.stamina(0, 0, 0)), "Alice should have -1 stamina delta (spent 2, gained 1)");
        assertEq(bobStaminaDelta, -1, "Bob should have -1 stamina delta from the drain");

        // Alice does nothing, Bob uses null move, no more stamina
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 1, 0, 0);

        // Check that Bob has stamina delta of -5
        bobStaminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        assertEq(bobStaminaDelta, -5, "Bob should have -5 stamina delta");

        // Alice does stamina drain, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Bob has 0 stamina, so no change so Alice doesn't get the drain
        bobStaminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        aliceStaminaDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        assertEq(bobStaminaDelta, -5, "Bob should still have -5 stamina delta");
        assertEq(aliceStaminaDelta, 1 - 2 * int32(vitalSiphon.stamina(0, 0, 0)), "Alice should have -3 stamina delta (after using the move)");
    }

    function test_somniphobiaDamagesMonsWhoRest() public {
        Somniphobia somniphobia = new Somniphobia(IEngine(address(engine)));

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = somniphobia;

        Mon memory mon = _createMon();
        mon.moves = moves;
        // Set HP to be a multiple of DAMAGE_DENOM (16) for easy math
        mon.stats.hp = uint32(somniphobia.DAMAGE_DENOM()) * 10; // 160 HP
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses Somniphobia, Bob uses Somniphobia too
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Verify that the global effect is applied
        (EffectInstance[] memory globalEffects, ) = engine.getEffects(battleKey, 2, 2);
        bool hasSomniphobia = false;
        for (uint256 i = 0; i < globalEffects.length; i++) {
            if (address(globalEffects[i].effect) == address(somniphobia)) {
                hasSomniphobia = true;
                break;
            }
        }
        assertTrue(hasSomniphobia, "Somniphobia effect should be applied globally");

        // Both players rest (NO_OP)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        // Verify that both mons took 1/16 of max HP as damage (160 / 16 = 10)
        int32 aliceHpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        int32 expectedDamage = -10; // 160 / 16 = 10
        assertEq(aliceHpDelta, expectedDamage, "Alice should take 1/16 max HP damage for resting");
        assertEq(bobHpDelta, expectedDamage, "Bob should take 1/16 max HP damage for resting");

        // Alice rests, Bob does nothing (but doesn't rest)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Verify that only Alice took additional damage
        aliceHpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        assertEq(aliceHpDelta, expectedDamage * 2, "Alice should take damage again for resting");
        assertEq(bobHpDelta, expectedDamage, "Bob should not take additional damage (didn't rest)");
    }

    function test_dreamcatcherHealsOnStaminaGain() public {
        Dreamcatcher dreamcatcher = new Dreamcatcher(IEngine(address(engine)));
        StaminaRegen staminaRegen = new StaminaRegen(IEngine(address(engine)));

        uint32 BASE_HP = 10;
        uint32 maxHp = uint32(dreamcatcher.HEAL_DENOM()) * BASE_HP; // 160 HP

        // Create an attack that deals damage
        StandardAttack attack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 3 * BASE_HP,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Attack",
                EFFECT: IEffect(address(0))
            })
        );

        // Create a move that costs 3 stamina and does nothing
        StandardAttack staminaBurn = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 3,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Stamina Burn",
                EFFECT: IEffect(address(0))
            })
        );

        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = attack;
        moves[1] = staminaBurn;

        Mon memory fastMon = _createMon();
        fastMon.moves = moves;
        fastMon.ability = dreamcatcher;
        fastMon.stats.hp = maxHp;
        fastMon.stats.stamina = 10;
        fastMon.stats.speed = 2;

        Mon memory slowMon = _createMon();
        slowMon.moves = moves;
        slowMon.ability = dreamcatcher;
        slowMon.stats.hp = maxHp;
        slowMon.stats.stamina = 10;
        slowMon.stats.speed = 1;

        Mon[] memory team = new Mon[](2);
        team[0] = fastMon;
        team[1] = slowMon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: team.length, MOVES_PER_MON: moves.length, TIMEOUT_DURATION: 10})
        );

        // Create ruleset with StaminaRegen
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        DefaultRuleset ruleset = new DefaultRuleset(IEngine(address(engine)), effects);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager));

        // Alice sends in fast mon, Bob sends in slow mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(1)
        );

        // Verify that Alice has the Dreamcatcher effect
        (EffectInstance[] memory aliceEffects, ) = engine.getEffects(battleKey, 0, 0);
        bool hasDreamcatcher = false;
        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (address(aliceEffects[i].effect) == address(dreamcatcher)) {
                hasDreamcatcher = true;
                break;
            }
        }
        assertTrue(hasDreamcatcher, "Alice should have Dreamcatcher effect");

        // Turn 1: Alice uses stamina burn (loses 3 stamina), Bob attacks Alice
        // At end of turn: Alice regains 1 stamina (from StaminaRegen), heals by 10 (from Dreamcatcher)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 0, 0, 0);

        int32 aliceHpAfterTurn1 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(aliceHpAfterTurn1, -20);

        // Turn 2: Both players rest (NO_OP)
        // Alice heals from resting, then heals again at end of turn from stamina regen
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Alice is back to full HP
        int32 aliceHpAfterTurn2 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(aliceHpAfterTurn2, 0, "Alice should be back to full HP");
    }

    function test_nightTerrorsDoesNotTriggerWhenStaminaTooLow() public {
        /**
         * Test that Night Terrors doesn't trigger damage when terror stacks > available stamina.
         *
         * Setup: Alice has 5 stamina
         * Turn 1: Alice uses Night Terrors (1 stack on Alice), Alice loses 1 stamina at end of turn (5 -> 4)
         * Turn 2: Alice uses Night Terrors (2 stacks on Alice), Alice loses 2 stamina at end of turn (4 -> 2)
         * Turn 3: Alice uses Night Terrors (3 stacks on Alice), Alice has only 2 stamina, so no trigger
         */
        SleepStatus sleepStatus = new SleepStatus(IEngine(address(engine)));
        NightTerrors nightTerrors = new NightTerrors(IEngine(address(engine)), ITypeCalculator(address(typeCalc)), IEffect(address(sleepStatus)));

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = nightTerrors;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.stamina = 5;
        mon.stats.hp = 1000; // High HP to avoid KO
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: team.length, MOVES_PER_MON: moves.length, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Turn 1: Alice uses Night Terrors, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Alice has 1 stack and lost 1 stamina (5 -> 4), Bob took damage
        int32 aliceStaminaAfterTurn1 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        int32 bobHpAfterTurn1 = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(aliceStaminaAfterTurn1, -1, "Alice should have -1 stamina delta after turn 1");
        assertTrue(bobHpAfterTurn1 < 0, "Bob should have taken damage");

        // Turn 2: Alice uses Night Terrors again, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Alice has 2 stacks and lost 2 more stamina (4 -> 2), Bob took more damage
        int32 aliceStaminaAfterTurn2 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        int32 bobHpAfterTurn2 = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(aliceStaminaAfterTurn2, -3, "Alice should have -3 stamina delta after turn 2");
        assertTrue(bobHpAfterTurn2 < bobHpAfterTurn1, "Bob should have taken more damage");

        // Turn 3: Alice uses Night Terrors again, Bob does nothing
        // Alice has 2 stamina but 3 stacks, so no trigger
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Alice's stamina didn't change (still at 2) and Bob's HP didn't change
        int32 aliceStaminaAfterTurn3 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        int32 bobHpAfterTurn3 = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(aliceStaminaAfterTurn3, -3, "Alice should still have -3 stamina delta (no trigger)");
        assertEq(bobHpAfterTurn3, bobHpAfterTurn2, "Bob's HP should not have changed (no damage dealt)");
    }

    function test_nightTerrorsClearsOnSwap() public {
        /**
         * Test that Night Terrors effect clears when the mon switches out.
         *
         * Setup: Both players have 2-mon teams
         * Turn 1: Alice uses Night Terrors (effect on Alice's mon 0)
         * Turn 2: Alice swaps to mon 1
         * Verify: Alice's mon 0 no longer has Night Terrors effect
         */
        SleepStatus sleepStatus = new SleepStatus(IEngine(address(engine)));
        NightTerrors nightTerrors = new NightTerrors(IEngine(address(engine)), ITypeCalculator(address(typeCalc)), IEffect(address(sleepStatus)));

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = nightTerrors;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = 1000;
        mon.stats.stamina = 10;

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: team.length, MOVES_PER_MON: moves.length, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Turn 1: Alice uses Night Terrors, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Alice's mon 0 has Night Terrors effect
        (EffectInstance[] memory aliceEffectsBeforeSwap, ) = engine.getEffects(battleKey, 0, 0);
        bool hasNightTerrorsBeforeSwap = false;
        for (uint256 i = 0; i < aliceEffectsBeforeSwap.length; i++) {
            if (address(aliceEffectsBeforeSwap[i].effect) == address(nightTerrors)) {
                hasNightTerrorsBeforeSwap = true;
                break;
            }
        }
        assertTrue(hasNightTerrorsBeforeSwap, "Alice's mon 0 should have Night Terrors effect before swap");

        // Turn 2: Alice swaps to mon 1, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(1), 0);

        // Verify Alice's mon 0 no longer has Night Terrors effect
        (EffectInstance[] memory aliceEffectsAfterSwap, ) = engine.getEffects(battleKey, 0, 0);
        bool hasNightTerrorsAfterSwap = false;
        for (uint256 i = 0; i < aliceEffectsAfterSwap.length; i++) {
            if (address(aliceEffectsAfterSwap[i].effect) == address(nightTerrors)) {
                hasNightTerrorsAfterSwap = true;
                break;
            }
        }
        assertFalse(hasNightTerrorsAfterSwap, "Alice's mon 0 should not have Night Terrors effect after swap");
    }

    function test_nightTerrorsDamageIncreasesWhenAsleep() public {
        /**
         * Test that Night Terrors deals more damage when the opponent is asleep.
         *
         * Setup: Create a sleep-inflicting move
         * Turn 1: Alice uses Night Terrors (effect on Alice), damages Bob (awake)
         * Turn 2: Alice swaps out to clear Night Terrors
         * Turn 3: Alice swaps back in
         * Turn 4: Alice uses Sleep move on Bob
         * Turn 5: Alice uses Night Terrors, damages sleeping Bob
         * Verify: Asleep damage is at least 50% more than awake damage (30/20 = 1.5)
         */
        SleepStatus sleepStatus = new SleepStatus(IEngine(address(engine)));
        NightTerrors nightTerrors = new NightTerrors(IEngine(address(engine)), ITypeCalculator(address(typeCalc)), IEffect(address(sleepStatus)));

        // Create a sleep-inflicting move with zero cost and zero damage
        StandardAttack sleepMove = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Sleep Move",
                EFFECT: IEffect(address(sleepStatus))
            })
        );

        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = nightTerrors;
        moves[1] = sleepMove;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = 1000;
        mon.stats.stamina = 20;

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: team.length, MOVES_PER_MON: moves.length, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Set RNG to 1 to prevent early waking from sleep (rng % 3 == 0 wakes early)
        mockOracle.setRNG(1);

        // Turn 1: Alice uses Night Terrors, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Check damage dealt to Bob (should be BASE_DAMAGE_PER_STACK = 20)
        int32 bobHpAfterAwakeDamage = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int32 awakeDamage = -bobHpAfterAwakeDamage;

        // Turn 2: Alice swaps out to mon 1 to clear Night Terrors, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(1), 0);

        // Turn 3: Alice swaps back to mon 0, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(0), 0);

        // Turn 4: Alice uses Sleep move on Bob, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Bob is asleep
        (EffectInstance[] memory bobEffects, ) = engine.getEffects(battleKey, 1, 0);
        bool bobIsAsleep = false;
        for (uint256 i = 0; i < bobEffects.length; i++) {
            if (address(bobEffects[i].effect) == address(sleepStatus)) {
                bobIsAsleep = true;
                break;
            }
        }
        assertTrue(bobIsAsleep, "Bob should be asleep");

        // Get Bob's HP before asleep damage
        int32 bobHpBeforeAsleepDamage = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        // Turn 5: Alice uses Night Terrors on sleeping Bob, Bob does nothing (forced by sleep)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Check damage dealt to Bob (should be ASLEEP_DAMAGE_PER_STACK = 30)
        int32 bobHpAfterAsleepDamage = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int32 asleepDamage = bobHpBeforeAsleepDamage - bobHpAfterAsleepDamage;

        // Verify asleep damage is at least 50% more than awake damage (30/20 = 1.5)
        assertTrue(asleepDamage * 100 >= awakeDamage * 150, "Asleep damage should be at least 50% more than awake damage");
    }
}
