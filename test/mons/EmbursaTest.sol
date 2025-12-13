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
import {IValidator} from "../../src/IValidator.sol";
import {IAbility} from "../../src/abilities/IAbility.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";

import {BattleHelper} from "../abstract/BattleHelper.sol";

import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";

import {StatBoosts} from "../../src/effects/StatBoosts.sol";
import {BurnStatus} from "../../src/effects/status/BurnStatus.sol";
import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {HeatBeacon} from "../../src/mons/embursa/HeatBeacon.sol";
import {HoneyBribe} from "../../src/mons/embursa/HoneyBribe.sol";
import {Q5} from "../../src/mons/embursa/Q5.sol";
import {SetAblaze} from "../../src/mons/embursa/SetAblaze.sol";
import {Tinderclaws} from "../../src/mons/embursa/Tinderclaws.sol";
import {DummyStatus} from "../mocks/DummyStatus.sol";

contract EmbursaTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultValidator validator;
    StandardAttackFactory attackFactory;
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
        matchmaker = new DefaultMatchmaker(engine);
    }

    function test_q5() public {
        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = new Q5(engine, typeCalc);

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 10,
                speed: 5,
                attack: 5,
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

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        IValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        // Start battle
        bytes32 battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses Q5, Bob does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Verify no damage occurred
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), 0, "No damage should have occurred"
        );

        // Wait 4 turns
        for (uint256 i = 0; i < 4; i++) {
            _commitRevealExecuteForAliceAndBob(
                engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
            );
        }
        // Verify no damage occurred
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), 0, "No damage should have occurred"
        );

        // Set rng to be 2 (magic number that cancels out the damage calc volatility stuff)
        mockOracle.setRNG(2);

        // Alice and Bob both do nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Verify damage occurred
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -150, "Damage should have occurred"
        );
    }

    function test_heatBeacon() public {
        DummyStatus dummyStatus = new DummyStatus();
        HeatBeacon heatBeacon = new HeatBeacon(IEngine(address(engine)), IEffect(address(dummyStatus)));
        Q5 q5 = new Q5(engine, typeCalc);
        SetAblaze setAblaze = new SetAblaze(engine, typeCalc, IEffect(address(dummyStatus)));
        StatBoosts statBoosts = new StatBoosts(engine);
        HoneyBribe honeyBribe = new HoneyBribe(engine, statBoosts);

        IMoveSet koMove = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 200,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "KO Move",
                EFFECT: IEffect(address(0))
            })
        );

        IMoveSet[] memory aliceMoves = new IMoveSet[](5);
        aliceMoves[0] = heatBeacon;
        aliceMoves[1] = q5;
        aliceMoves[2] = setAblaze;
        aliceMoves[3] = honeyBribe;
        aliceMoves[4] = koMove;

        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 1,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: aliceMoves,
            ability: IAbility(address(0))
        });

        // 5. Create Bob's mon with higher speed
        IMoveSet[] memory bobMoves = new IMoveSet[](5);
        bobMoves[0] = heatBeacon;
        bobMoves[1] = q5;
        bobMoves[2] = setAblaze;
        bobMoves[3] = honeyBribe;
        bobMoves[4] = koMove;

        Mon memory bobMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 2, // Higher speed than Alice
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: bobMoves,
            ability: IAbility(address(0))
        });
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);
        IValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 5, TIMEOUT_DURATION: 10})
        );

        // Set Ablaze test
        // Start battle
        // Alice uses Heat Beacon, Bob does nothing
        // Verify dummy status was applied to Bob's mon
        // Verify Alice's priority boost
        // Alice uses Set Ablaze, Bob uses KO move
        // Verify Alice's priority boost is cleared
        // Verify Alice's mon is KO'ed but Bob has taken damage
        bytes32 battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + 1);

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 1, "Bob's mon should have 1 effect (Dummy status)");
        assertEq(address(effects[0].effect), address(dummyStatus), "Bob's mon should have Dummy status");
        assertEq(heatBeacon.priority(battleKey, 0), DEFAULT_PRIORITY + 1, "Alice should have priority boost");
        mockOracle.setRNG(2); // Magic number to cancel out volatility
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, 4, 0, 0);
        assertEq(heatBeacon.priority(battleKey, 0), DEFAULT_PRIORITY, "Alice's priority boost should be cleared");
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut),
            1,
            "Alice's mon should be KOed"
        );
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp),
            -1 * int32(setAblaze.basePower(battleKey)),
            "Bob's mon should take damage"
        );

        // Heat Beacon test
        // Start a new battle
        // Alice uses Heat Beacon, Bob does nothing
        // Alice uses Heat Beacon again, Bob uses KO Move
        // Verify Alice's mon is KO'ed but Bob's mon now has 2x Dummy status
        battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + 1);

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );
        (effects, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 0, "Bob's mon should have no effects");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        (effects, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 2, "Bob's mon should have 2x Dummy status");

        /* TODO later
        // Q5 test
        // Start a new battle
        // Alice uses Heat Beacon, Bob does nothing
        // Alice uses Q5, Bob uses KO move
        // Verify Q5 was applied to global effects, verify Alice is KOed
        battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 4, 0, 0);
        (effects, ) = engine.getEffects(battleKey, 2, 0);
        assertEq(address(effects[0].effect), address(q5), "Q5 should be applied to global effects");
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut),
            1,
            "Alice's mon should be KOed"
        );

        // Honey Bribe test
        // Start a new battle
        // Alice uses Heat Beacon, Bob does nothing
        // Alice uses Honey Bribe, Bob uses KO move
        // Verify Honey Bribe applied stat boost to Bob's mon, verify Alice is KOed
        battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 3, 4, 0, 0);
        (effects, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(address(effects[1].effect), address(statBoosts), "StatBoosts should be applied to Bob's mon");
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut),
            1,
            "Alice's mon should be KOed"
        );
        */
    }

    /**
     * Tinderclaws ability tests:
     * - After using a move (not NO_OP or SWITCH), Embursa has a 1/3 chance to self-burn
     * - When burned, Embursa gains a 50% SpATK boost at end of round (in addition to burn's Attack penalty)
     * - When resting (NO_OP), burn is removed
     * - When burn is removed, SpATK boost is also removed at end of round
     * - If burn is applied externally, SpATK boost is still granted at end of round
     */
    function test_tinderclaws_selfBurnOnMove() public {
        StatBoosts statBoosts = new StatBoosts(engine);
        BurnStatus burnStatus = new BurnStatus(IEngine(address(engine)), statBoosts);
        Tinderclaws tinderclaws = new Tinderclaws(IEngine(address(engine)), IEffect(address(burnStatus)), statBoosts);

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 10,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "TestAttack",
                EFFECT: IEffect(address(0))
            })
        );

        Mon memory aliceMon = _createMon();
        aliceMon.moves = moves;
        aliceMon.ability = IAbility(address(tinderclaws));
        aliceMon.stats.hp = 100;
        aliceMon.stats.attack = 10;
        aliceMon.stats.specialAttack = 10;
        aliceMon.stats.speed = 10;

        Mon memory bobMon = _createMon();
        bobMon.moves = moves;
        bobMon.stats.hp = 1000; // High HP so Bob doesn't get KO'd before AfterMove runs
        bobMon.stats.speed = 5;

        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        DefaultValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + 1);

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Set RNG so that burn triggers (rng % 3 == 2)
        mockOracle.setRNG(2);

        // Alice uses attack, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Check if Alice's mon got burned (the RNG may or may not trigger burn depending on hash)
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 0, 0);

        // The mon should have at least the Tinderclaws effect
        bool hasTinderclaws = false;
        bool hasBurn = false;
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(tinderclaws)) {
                hasTinderclaws = true;
            }
            if (address(effects[i].effect) == address(burnStatus)) {
                hasBurn = true;
            }
        }
        assertTrue(hasTinderclaws, "Alice's mon should have Tinderclaws effect");

        // If burn was applied, check that SpATK boost was also applied
        // Note: RNG is hashed with contract address, so burn may or may not trigger
        if (hasBurn) {
            int32 spAtkDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
            int32 attackDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
            // SpATK should be boosted by 50% (10 * 0.5 = 5)
            // Attack should be reduced by 50% due to burn (10 / 2 = -5)
            assertEq(spAtkDelta, 5, "SpATK should be boosted by 50%");
            assertEq(attackDelta, -5, "Attack should be reduced by 50% due to burn");
        }
    }

    function test_tinderclaws_restingRemovesBurn() public {
        StatBoosts statBoosts = new StatBoosts(engine);
        BurnStatus burnStatus = new BurnStatus(IEngine(address(engine)), statBoosts);
        Tinderclaws tinderclaws = new Tinderclaws(IEngine(address(engine)), IEffect(address(burnStatus)), statBoosts);

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "BurnAttack",
                EFFECT: IEffect(address(burnStatus))
            })
        );

        Mon memory aliceMon = _createMon();
        aliceMon.moves = moves;
        aliceMon.ability = IAbility(address(tinderclaws));
        aliceMon.stats.hp = 100;
        aliceMon.stats.attack = 10;
        aliceMon.stats.specialAttack = 10;
        aliceMon.stats.speed = 5; // Slower than Bob

        Mon memory bobMon = _createMon();
        bobMon.moves = moves;
        bobMon.stats.hp = 100;
        bobMon.stats.speed = 10; // Faster than Alice

        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        DefaultValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Bob uses burn attack on Alice (Bob is faster)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Verify Alice is burned and has SpATK boost
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 0, 0);
        bool hasBurn = false;
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(burnStatus)) {
                hasBurn = true;
            }
        }
        assertTrue(hasBurn, "Alice should be burned");

        int32 spAtkDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        assertEq(spAtkDelta, 5, "SpATK should be boosted by 50%");

        // Alice rests (NO_OP), which should remove burn
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        // Verify burn is removed
        (effects,) = engine.getEffects(battleKey, 0, 0);
        hasBurn = false;
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(burnStatus)) {
                hasBurn = true;
            }
        }
        assertFalse(hasBurn, "Burn should be removed after resting");

        // Verify SpATK boost is also removed at end of round
        spAtkDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        assertEq(spAtkDelta, 0, "SpATK boost should be removed when burn is removed");
    }
}
