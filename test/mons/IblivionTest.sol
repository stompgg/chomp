// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Structs.sol";
import {Test} from "forge-std/Test.sol";

import {Engine} from "../../src/Engine.sol";
import {MonStateIndexName, Type} from "../../src/Enums.sol";
import {IEngine} from "../../src/IEngine.sol";
import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";
import {BattleHelper} from "../abstract/BattleHelper.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {MoveClass} from "../../src/Enums.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {BurnStatus} from "../../src/effects/status/BurnStatus.sol";
import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {Baselight} from "../../src/mons/iblivion/Baselight.sol";
import {Brightback} from "../../src/mons/iblivion/Brightback.sol";
import {Loop} from "../../src/mons/iblivion/Loop.sol";
import {Renormalize} from "../../src/mons/iblivion/Renormalize.sol";
import {UnboundedStrike} from "../../src/mons/iblivion/UnboundedStrike.sol";
import {StandardAttack} from "../../src/moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";
import {MockEffectRemover} from "../mocks/MockEffectRemover.sol";

contract IblivionTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    StandardAttackFactory attackFactory;
    DefaultMatchmaker matchmaker;

    // Iblivion contracts
    Baselight baselight;
    Brightback brightback;
    UnboundedStrike unboundedStrike;
    Loop loop;
    Renormalize renormalize;

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        attackFactory = new StandardAttackFactory(ITypeCalculator(address(typeCalc)));
        matchmaker = new DefaultMatchmaker(engine);

        // Deploy Iblivion contracts
        baselight = new Baselight();
        brightback = new Brightback(ITypeCalculator(address(typeCalc)), baselight);
        unboundedStrike = new UnboundedStrike(ITypeCalculator(address(typeCalc)), baselight);
        loop = new Loop(baselight);
        renormalize = new Renormalize(baselight, loop);
    }

    // ============ Baselight Ability Tests ============

    function test_baselightStartsAtOneOnFirstSwitchIn() public {
        // Create a mon with Baselight ability
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = mon;
        aliceTeam[1] = mon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = mon;
        bobTeam[1] = mon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Switch in mons
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Baselight seeds at 1 on switch-in; it no longer gains at round end (gains on damage).
        uint256 baselightLevel = baselight.getBaselightLevel(engine, battleKey, 0, 0);
        assertEq(baselightLevel, 1, "Baselight should be 1 after first switch in (seed only, no round-end gain)");
    }

    function test_baselightGainsOnDamage() public {
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Seeds at 1; no round-end gain.
        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 1, "Should seed at 1 after switch-in");

        // Each time Iblivion takes damage it gains 1 (Bob attacks with move 0). 1 -> 2.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 2, "Should be 2 after taking a hit");

        // 2 -> 3 (max).
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 3, "Should be 3 (max) after another hit");

        // Capped at 3.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 3, "Should stay at 3 (max)");
    }

    // ============ Brightback Tests ============

    function test_brightbackHealsWithStack() public {
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon memory bobMon = Mon({
            stats: MonStats({
                hp: 10000,
                stamina: 20,
                speed: 50,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice seeds at 1 Baselight stack.
        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 1, "Should seed with 1 stack");

        // Bob damages Alice first -> Alice gains a Baselight stack (1 -> 2).
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Get Alice's HP before Brightback
        int32 aliceHpBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertTrue(aliceHpBefore < 0, "Alice should have taken damage");

        // Taking the hit bumped Baselight to 2.
        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 2, "Should be 2 after taking a hit");

        // Alice uses Brightback - should consume 1 stack and heal
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Consumed 1 (2 -> 1); no round-end gain.
        uint256 afterBrightback = baselight.getBaselightLevel(engine, battleKey, 0, 0);
        assertEq(afterBrightback, 1, "Baselight should be 1 (consumed 1 from 2)");

        // Check Alice healed
        int32 aliceHpAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertTrue(aliceHpAfter > aliceHpBefore, "Alice should have healed");
    }

    function test_brightbackNoHealWithoutStack() public {
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: 0 // No Baselight ability, so no stacks
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // No Baselight stacks
        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 0, "Should have 0 stacks without ability");

        // Bob damages Alice
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        int32 aliceHpBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertTrue(aliceHpBefore < 0, "Alice should have taken damage");

        // Alice uses Brightback - should NOT heal (no stacks)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        int32 aliceHpAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(aliceHpAfter, aliceHpBefore, "Alice should not have healed without stacks");
    }

    // ============ Unbounded Strike Tests ============

    function test_unboundedStrikeNormalPower() public {
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon memory bobMon = Mon({
            stats: MonStats({
                hp: 10000,
                stamina: 20,
                speed: 50,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice has 1 stack (not 3), so normal power (80).
        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 1, "Should have 1 stack");

        // Alice uses Unbounded Strike
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, 0, 0);

        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertTrue(bobHpDelta < 0, "Bob should have taken damage");

        // Below 3 stacks Unbounded Strike consumes nothing; Alice took no damage, so still 1.
        assertEq(
            baselight.getBaselightLevel(engine, battleKey, 0, 0), 1, "Stacks unchanged below the 3-stack threshold"
        );
    }

    function test_unboundedStrikeEmpoweredPower() public {
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon memory bobMon = Mon({
            stats: MonStats({
                hp: 10000,
                stamina: 20,
                speed: 50,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Accrue to 3 stacks: Iblivion gains 1 per hit (seed 1 -> 2 -> 3). Bob attacks with move 0.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 3, "Should have 3 stacks");

        // Get Bob's HP before
        int32 bobHpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        // Alice uses Unbounded Strike at 3 stacks - empowered (130 power)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, 0, 0);

        int32 bobHpAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int32 damageDealt = bobHpBefore - bobHpAfter;
        assertTrue(damageDealt > 0, "Bob should have taken damage");

        // All 3 stacks consumed; Alice took no damage this turn, so Baselight is 0.
        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 0, "All stacks consumed to 0");
    }

    // ============ Loop Tests ============

    function test_loopAppliesStatBoosts() public {
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // At Baselight 1 (seed), Loop should give a 15% boost.
        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 1, "Should have 1 stack");

        // Get stats before Loop
        int32 attackBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);

        // Alice uses Loop
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0);

        // Check stats are boosted (15% of 100 = 15)
        int32 attackAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(attackAfter - attackBefore, 15, "Attack should be boosted by 15%");

        // Loop should be marked as active
        assertTrue(loop.isLoopActive(engine, battleKey, 0, 0), "Loop should be active");
    }

    function test_loopFailsIfAlreadyActive() public {
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice uses Loop first time
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0);

        int32 attackAfterFirst = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertTrue(loop.isLoopActive(engine, battleKey, 0, 0), "Loop should be active");

        // Alice uses Loop second time - should fail
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0);

        int32 attackAfterSecond = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(attackAfterSecond, attackAfterFirst, "Attack should not change when Loop fails");
    }

    function test_loopReArmsAfterSwitchOut() public {
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both switch in mon 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice uses Loop on mon 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0);
        assertTrue(loop.isLoopActive(engine, battleKey, 0, 0), "Loop should be active after first use");
        assertTrue(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack) > 0, "Attack should be boosted"
        );

        // Alice switches out mon 0 -> mon 1: the marker re-arms and the Temp boost is dropped
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(1), uint16(0)
        );
        assertFalse(loop.isLoopActive(engine, battleKey, 0, 0), "Loop should re-arm after switch-out");
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack),
            0,
            "Temp boost should be cleared on switch-out"
        );

        // Alice switches back mon 1 -> mon 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Loop fires again on the fresh switch-in
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0);
        assertTrue(loop.isLoopActive(engine, battleKey, 0, 0), "Loop should be active again after switching back in");
        assertTrue(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack) > 0,
            "Attack should be boosted again after re-arm"
        );
    }

    function test_loopBoostPercentages() public {
        // Test that Loop gives correct boosts at different Baselight levels
        // Level 1: 15%, Level 2: 30%, Level 3: 50%

        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Accrue to 3 stacks: 1 per hit (seed 1 -> 2 -> 3). Bob attacks with move 0.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 3, "Should have 3 stacks");

        // Get stats before Loop
        int32 attackBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);

        // Alice uses Loop at level 3 - should get 50% boost
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0);

        int32 attackAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(attackAfter - attackBefore, 50, "Attack should be boosted by 50% at level 3");
    }

    // ============ Renormalize Tests ============

    function test_renormalizeSetsBaselightToThree() public {
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Seeds at 1 stack.
        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 1, "Should seed at 1 stack");

        // Alice uses Renormalize
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 3, NO_OP_MOVE_INDEX, 0, 0);

        // Should be at 3 stacks (Renormalize sets it to 3).
        assertEq(baselight.getBaselightLevel(engine, battleKey, 0, 0), 3, "Baselight should be set to 3");
    }

    function test_renormalizeClearsStatBoosts() public {
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice uses Loop to get stat boosts
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0);

        int32 attackBoosted = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertTrue(attackBoosted > 0, "Attack should be boosted");

        // Alice uses Renormalize - should clear stat boosts
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 3, NO_OP_MOVE_INDEX, 0, 0);

        int32 attackAfterRenormalize = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(attackAfterRenormalize, 0, "Attack boost should be cleared");
    }

    function test_renormalizeClearsLoopActive() public {
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice uses Loop
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0);

        assertTrue(loop.isLoopActive(engine, battleKey, 0, 0), "Loop should be active");

        // Alice uses Renormalize
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 3, NO_OP_MOVE_INDEX, 0, 0);

        assertFalse(loop.isLoopActive(engine, battleKey, 0, 0), "Loop should no longer be active");

        // Alice can use Loop again
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0);

        int32 attackBoosted = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertTrue(attackBoosted > 0, "Attack should be boosted again after Renormalize");
    }

    function test_renormalizeHasLowerPriority() public {
        // Renormalize should have -1 priority (DEFAULT_PRIORITY - 1 = 2)
        uint256[] memory moves = new uint256[](4);
        moves[0] = uint256(uint160(address(brightback)));
        moves[1] = uint256(uint160(address(unboundedStrike)));
        moves[2] = uint256(uint160(address(loop)));
        moves[3] = uint256(uint160(address(renormalize)));

        Mon memory fastMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon memory slowMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 10, // Much slower
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(baselight))
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = fastMon;
        aliceTeam[1] = fastMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = slowMon;
        bobTeam[1] = slowMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Check priority
        uint32 renomalPriority = renormalize.priority(IEngine(address(engine)), battleKey, 0);
        assertEq(renomalPriority, DEFAULT_PRIORITY - 1, "Renormalize should have -1 priority");
    }

    /**
     * Tests Renormalize interaction with status effect stat boosts:
     * 1. Iblivion gets burned (BurnStatus applies a permanent attack debuff via StatBoosts)
     * 2. Iblivion uses Renormalize (clears ALL stat boosts including burn's attack debuff)
     * 3. MockEffectRemover removes the burn status (burn's onRemove tries to call removeStatBoosts)
     * 4. Verify: removeStatBoosts silently fails (no revert) because Renormalize already cleared it
     * 5. Verify: stats remain at base values (no change from the failed removal attempt)
     */
    function test_renormalizeClearsStatusEffectStatBoosts() public {
        BurnStatus burnStatus = new BurnStatus();
        MockEffectRemover effectRemover = new MockEffectRemover();

        // Create a 0-damage attack that inflicts burn with 100% accuracy
        StandardAttack burnAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Other,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Burn Attack",
                EFFECT: IEffect(address(burnStatus))
            })
        );

        uint256[] memory iblivionMoves = new uint256[](4);
        iblivionMoves[0] = uint256(uint160(address(brightback)));
        iblivionMoves[1] = uint256(uint160(address(unboundedStrike)));
        iblivionMoves[2] = uint256(uint160(address(loop)));
        iblivionMoves[3] = uint256(uint160(address(renormalize)));

        uint256[] memory opponentMoves = new uint256[](4);
        opponentMoves[0] = uint256(uint160(address(burnAttack)));
        opponentMoves[1] = uint256(uint160(address(effectRemover)));
        opponentMoves[2] = uint256(uint160(address(loop)));
        opponentMoves[3] = uint256(uint160(address(renormalize)));

        uint32 baseAttack = 100;

        Mon memory iblivionMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 50, // Slower so Bob can inflict burn first
                attack: baseAttack,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yin,
                type2: Type.None
            }),
            moves: iblivionMoves,
            ability: uint160(address(baselight))
        });

        Mon memory opponentMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 100, // Faster
                attack: baseAttack,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: opponentMoves,
            ability: 0
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = iblivionMon;
        aliceTeam[1] = iblivionMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = opponentMon;
        bobTeam[1] = opponentMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Switch in mons
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Verify Alice's attack starts at base (0 delta)
        int32 aliceAttackBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(aliceAttackBefore, 0, "Alice's attack delta should start at 0");

        // Bob inflicts burn on Alice (move index 0), Alice does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Verify Alice has burn effect and attack debuff applied
        (EffectInstance[] memory effectsAfterBurn,) = engine.getEffects(battleKey, 0, 0);
        bool hasBurn = false;
        for (uint256 i = 0; i < effectsAfterBurn.length; i++) {
            if (address(effectsAfterBurn[i].effect) == address(burnStatus)) {
                hasBurn = true;
                break;
            }
        }
        assertTrue(hasBurn, "Alice should have burn effect");

        // Verify attack is debuffed (BurnStatus divides attack by 50%, so attack delta should be negative)
        int32 aliceAttackAfterBurn = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertTrue(aliceAttackAfterBurn < 0, "Alice's attack should be debuffed by burn");
        // Expected debuff: baseAttack / 2 = 50, so delta = 50 - 100 = -50
        assertEq(aliceAttackAfterBurn, -1 * int32(baseAttack) / 2, "Attack debuff should be -50%");

        // Alice uses Renormalize (move index 3), Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 3, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Alice's attack is reset to base (0 delta) after Renormalize
        int32 aliceAttackAfterRenormalize = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(aliceAttackAfterRenormalize, 0, "Alice's attack should be reset to base after Renormalize");

        // Alice still has burn effect (Renormalize only clears stat boosts, not status effects)
        (EffectInstance[] memory effectsAfterRenormalize,) = engine.getEffects(battleKey, 0, 0);
        bool stillHasBurn = false;
        for (uint256 i = 0; i < effectsAfterRenormalize.length; i++) {
            if (address(effectsAfterRenormalize[i].effect) == address(burnStatus)) {
                stillHasBurn = true;
                break;
            }
        }
        assertTrue(stillHasBurn, "Alice should still have burn effect after Renormalize");

        // Bob uses MockEffectRemover to remove burn from Alice (move index 1).
        // Pass burn status's slot index as extraData (looked up from Alice's effects).
        uint16 burnSlot;
        {
            (EffectInstance[] memory beforeRemove, uint256[] memory beforeIndices) = engine.getEffects(battleKey, 0, 0);
            for (uint256 i = 0; i < beforeRemove.length; i++) {
                if (address(beforeRemove[i].effect) == address(burnStatus)) {
                    burnSlot = uint16(beforeIndices[i]);
                    break;
                }
            }
        }
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 1, 0, burnSlot);

        // Verify burn effect is removed
        (EffectInstance[] memory effectsAfterRemove,) = engine.getEffects(battleKey, 0, 0);
        bool burnRemoved = true;
        for (uint256 i = 0; i < effectsAfterRemove.length; i++) {
            if (address(effectsAfterRemove[i].effect) == address(burnStatus)) {
                burnRemoved = false;
                break;
            }
        }
        assertTrue(burnRemoved, "Burn effect should be removed");

        // Verify stats remain at base (removeStatBoosts silently failed, no revert, no stat change)
        int32 aliceAttackFinal = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(
            aliceAttackFinal, 0, "Alice's attack should remain at base after burn removal (no double-removal issue)"
        );
    }
}
