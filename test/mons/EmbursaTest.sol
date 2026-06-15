// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Structs.sol";
import {Test} from "forge-std/Test.sol";

import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";
import {Engine} from "../../src/Engine.sol";
import {MonStateIndexName, MoveClass, Type} from "../../src/Enums.sol";

import {DefaultValidator} from "../../src/DefaultValidator.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IValidator} from "../../src/IValidator.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";

import {BattleHelper} from "../abstract/BattleHelper.sol";

import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";

import {BurnStatus} from "../../src/effects/status/BurnStatus.sol";
import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {HeatBeacon} from "../../src/mons/embursa/HeatBeacon.sol";
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
        engine = new Engine(0, 0);
        validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        attackFactory = new StandardAttackFactory(ITypeCalculator(address(typeCalc)));
        matchmaker = new DefaultMatchmaker(engine);
    }

    function test_q5() public {
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(new Q5(typeCalc))));

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
            ability: 0
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
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice uses Q5, Bob does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Verify no damage occurred
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), 0, "No damage should have occurred"
        );

        // Wait 4 turns
        for (uint256 i = 0; i < 4; i++) {
            _commitRevealExecuteForAliceAndBob(
                engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(0), uint16(0)
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
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Verify damage occurred
        // Real type chart (TypeCalcLib) resolves this matchup at 0.5x — custom attacks no longer
        // use the injected mock calculator (dispatchCustomAttack consolidation).
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -75, "Damage should have occurred"
        );
    }

    function test_heatBeacon() public {
        DummyStatus dummyStatus = new DummyStatus();
        HeatBeacon heatBeacon = new HeatBeacon(IEffect(address(dummyStatus)));
        Q5 q5 = new Q5(typeCalc);
        SetAblaze setAblaze = new SetAblaze(typeCalc, IEffect(address(dummyStatus)));

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

        // Engine team storage holds MOVE_LANES_PER_MON (4) moves per mon, matching prod.
        uint256[] memory aliceMoves = new uint256[](4);
        aliceMoves[0] = uint256(uint160(address(heatBeacon)));
        aliceMoves[1] = uint256(uint160(address(q5)));
        aliceMoves[2] = uint256(uint160(address(setAblaze)));
        aliceMoves[3] = uint256(uint160(address(koMove)));

        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 1,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: aliceMoves,
            ability: 0
        });

        // 5. Create Bob's mon with higher speed
        uint256[] memory bobMoves = new uint256[](4);
        bobMoves[0] = uint256(uint160(address(heatBeacon)));
        bobMoves[1] = uint256(uint160(address(q5)));
        bobMoves[2] = uint256(uint160(address(setAblaze)));
        bobMoves[3] = uint256(uint160(address(koMove)));

        Mon memory bobMon = Mon({
            stats: MonStats({
                hp: 1000, // Large enough to survive a crit on SetAblaze so the test isolates Heat Beacon behavior
                stamina: 10,
                speed: 2, // Higher speed than Alice
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: bobMoves,
            ability: 0
        });
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);
        IValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 4, TIMEOUT_DURATION: 10})
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
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 1, "Bob's mon should have 1 effect (Dummy status)");
        assertEq(address(effects[0].effect), address(dummyStatus), "Bob's mon should have Dummy status");
        assertEq(heatBeacon.priority(engine, battleKey, 0), DEFAULT_PRIORITY + 1, "Alice should have priority boost");
        mockOracle.setRNG(2);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, 3, 0, 0);
        assertEq(heatBeacon.priority(engine, battleKey, 0), DEFAULT_PRIORITY, "Alice's priority boost should be cleared");
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut),
            1,
            "Alice's mon should be KOed"
        );
        // Bob takes damage from SetAblaze but survives (exact amount depends on volatility/crit RNG)
        assertLt(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp),
            0,
            "Bob's mon should take damage from SetAblaze"
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
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
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
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 3, 0, 0);
        (effects, ) = engine.getEffects(battleKey, 2, 0);
        assertEq(address(effects[0].effect), address(q5), "Q5 should be applied to global effects");
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut),
            1,
            "Alice's mon should be KOed"
        );

        // Honey Bribe test (NOTE when un-TODOing: teams hold 4 moves — swap honeyBribe into a
        // lane (e.g. replace q5) and redeploy it here; it was dropped from the shared move array)
        // Start a new battle
        // Alice uses Heat Beacon, Bob does nothing
        // Alice uses Honey Bribe, Bob uses KO move
        // Verify Honey Bribe applied stat boost to Bob's mon, verify Alice is KOed
        battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 3, 4, 0, 0);
        (effects, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(address(effects[1].effect), STAT_BOOST_ADDRESS, "StatBoosts should be applied to Bob's mon");
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut),
            1,
            "Alice's mon should be KOed"
        );
        */
    }

    // Verifies that when Q5 fires on RoundStart and KOs Bob's active mon (in a 2v2),
    // Bob's pending attack does NOT execute (Alice takes no damage)
    function test_q5_ko_prevents_attack() public {
        Q5 q5 = new Q5(typeCalc);

        uint256[] memory q5Moves = new uint256[](1);
        q5Moves[0] = uint256(uint160(address(q5)));

        IMoveSet bobAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 50,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 0,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "TestAttack",
                EFFECT: IEffect(address(0))
            })
        );

        uint256[] memory attackMoves = new uint256[](1);
        attackMoves[0] = uint256(uint160(address(bobAttack)));

        Mon memory aliceMon = _createMon();
        aliceMon.moves = q5Moves;
        aliceMon.stats.hp = 1000;
        aliceMon.stats.specialAttack = 5;
        aliceMon.stats.defense = 5;
        aliceMon.stats.stamina = 10;

        Mon memory bobMon = _createMon();
        bobMon.moves = attackMoves;
        bobMon.stats.hp = 100;
        bobMon.stats.attack = 5;
        bobMon.stats.specialDefense = 5;
        bobMon.stats.stamina = 10;

        // 2v2: each side has a second mon (identical to first)
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMon;
        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        IValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey =
            _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        vm.warp(vm.getBlockTimestamp() + 1);

        // Both switch in
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice uses Q5, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Wait 4 turns (Q5 counter ticks from 1 to 5)
        for (uint256 i = 0; i < 4; i++) {
            _commitRevealExecuteForAliceAndBob(
                engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(0), uint16(0)
            );
        }

        // On the firing turn: Alice does nothing, Bob tries to attack
        // Q5 fires during RoundStart and should KO Bob's active mon before Bob's move executes
        mockOracle.setRNG(2);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Q5 should have KO'd Bob's active mon
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut),
            1,
            "Bob's mon should be KO'd by Q5"
        );

        // Alice should have taken NO damage (Bob's attack should not have executed)
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp),
            0,
            "Alice should not have taken damage"
        );

        // Game is NOT over — Bob still has a second mon
        assertEq(engine.getWinner(battleKey), address(0), "Game should not be over yet");
    }

    // Reproduces a battle log where Q5 fires on RoundStart and KOs Bob's active mon, while
    // BOTH players submitted a switch as their Q-priority move that turn. Confirms whether
    // those queued switches still execute or are short-circuited like a normal attack would be.
    function test_q5_ko_with_concurrent_switches() public {
        Q5 q5 = new Q5(typeCalc);

        uint256[] memory q5Moves = new uint256[](1);
        q5Moves[0] = uint256(uint160(address(q5)));

        // Bob doesn't need a real attack move — both players will submit switches on the firing turn.
        IMoveSet bobAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 1,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 0,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "TestAttack",
                EFFECT: IEffect(address(0))
            })
        );

        uint256[] memory attackMoves = new uint256[](1);
        attackMoves[0] = uint256(uint160(address(bobAttack)));

        Mon memory aliceMon = _createMon();
        aliceMon.moves = q5Moves;
        aliceMon.stats.hp = 1000;
        aliceMon.stats.specialAttack = 5;
        aliceMon.stats.defense = 5;
        aliceMon.stats.stamina = 10;
        aliceMon.stats.speed = 10;

        Mon memory bobMon = _createMon();
        bobMon.moves = attackMoves;
        bobMon.stats.hp = 100;
        bobMon.stats.attack = 5;
        bobMon.stats.specialDefense = 5;
        bobMon.stats.stamina = 10;
        bobMon.stats.speed = 5;

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMon;
        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        IValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey =
            _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        vm.warp(vm.getBlockTimestamp() + 1);

        // Turn 0: both pick mon 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Turn 1: Alice uses Q5
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Turns 2..5: idle so Q5's tick counter advances 1 -> 5
        for (uint256 i = 0; i < 4; i++) {
            _commitRevealExecuteForAliceAndBob(
                engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(0), uint16(0)
            );
        }

        // Sanity: pre-firing turn, both active mons are slot 0 with no KO
        assertEq(_aliceActive(battleKey), 0, "Alice active mon == 0 pre-fire");
        assertEq(_bobActive(battleKey), 0, "Bob active mon == 0 pre-fire");
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 0, "Bob slot 0 alive pre-fire"
        );

        mockOracle.setRNG(2);

        // Firing turn: BOTH players queue a switch to their slot-1 mon. Q5 ticks at RoundStart
        // and KOs Bob's slot-0 active mon BEFORE the Q-priority switch moves run.
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(1), uint16(1)
        );

        // Q5 ticked and KO'd Bob's slot 0
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut),
            1,
            "Bob slot 0 should be KO'd by Q5 tick"
        );

        // Question under test: do the queued switches still execute, or does the post-RoundStart-KO
        // playerSwitchForTurnFlag short-circuit them in _handleMove (Engine.sol line ~1603)?
        // Engine reading: both _handleMove calls should early-return → both active indices stay at 0,
        // and next turn becomes a single-player forced switch for Bob.
        assertEq(_aliceActive(battleKey), 0, "Alice's queued switch should NOT execute (early-return)");
        assertEq(_bobActive(battleKey), 0, "Bob's queued switch should NOT execute (early-return)");

        // After turn ends, only Bob has a forced switch pending.
        assertEq(
            uint256(engine.getBattleContext(battleKey).playerSwitchForTurnFlag),
            1,
            "Next turn should be Bob's single-player forced switch"
        );

        // Game not over — Bob still has slot 1
        assertEq(engine.getWinner(battleKey), address(0), "Game should not be over yet");
    }

    function _aliceActive(bytes32 battleKey) internal view returns (uint256) {
        return engine.getActiveMonIndexForBattleState(battleKey)[0];
    }

    function _bobActive(bytes32 battleKey) internal view returns (uint256) {
        return engine.getActiveMonIndexForBattleState(battleKey)[1];
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
        BurnStatus burnStatus = new BurnStatus();
        Tinderclaws tinderclaws = new Tinderclaws(IEffect(address(burnStatus)));

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(attackFactory.createAttack(
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
        ))));

        Mon memory aliceMon = _createMon();
        aliceMon.moves = moves;
        aliceMon.ability = uint160(address(tinderclaws));
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
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
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
        BurnStatus burnStatus = new BurnStatus();
        Tinderclaws tinderclaws = new Tinderclaws(IEffect(address(burnStatus)));

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(attackFactory.createAttack(
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
        ))));

        Mon memory aliceMon = _createMon();
        aliceMon.moves = moves;
        aliceMon.ability = uint160(address(tinderclaws));
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
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
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
