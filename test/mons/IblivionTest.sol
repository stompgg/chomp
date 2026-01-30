// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Structs.sol";
import {Test} from "forge-std/Test.sol";

import {DefaultCommitManager} from "../../src/DefaultCommitManager.sol";
import {Engine} from "../../src/Engine.sol";
import {MonStateIndexName, Type} from "../../src/Enums.sol";
import {DefaultValidator} from "../../src/DefaultValidator.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IAbility} from "../../src/abilities/IAbility.sol";
import {StatBoosts} from "../../src/effects/StatBoosts.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";
import {BattleHelper} from "../abstract/BattleHelper.sol";
import {EffectTestHelper} from "../abstract/EffectTestHelper.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {Baselight} from "../../src/mons/iblivion/Baselight.sol";
import {Brightback} from "../../src/mons/iblivion/Brightback.sol";
import {UnboundedStrike} from "../../src/mons/iblivion/UnboundedStrike.sol";
import {Loop} from "../../src/mons/iblivion/Loop.sol";
import {Renormalize} from "../../src/mons/iblivion/Renormalize.sol";
import {BurnStatus} from "../../src/effects/status/BurnStatus.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {MoveClass} from "../../src/Enums.sol";
import {StandardAttack} from "../../src/moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";
import {MockEffectRemover} from "../mocks/MockEffectRemover.sol";

contract IblivionTest is Test, BattleHelper, EffectTestHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultValidator validator;
    StatBoosts statBoost;
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
        engine = new Engine();
        validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 4, TIMEOUT_DURATION: 10})
        );
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        // Deploy effects with correct bitmaps (auto-computed from shouldRunAtStep)
        statBoost = StatBoosts(deployWithCorrectBitmap(new StatBoosts(IEngine(address(engine)))));
        attackFactory = new StandardAttackFactory(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        matchmaker = new DefaultMatchmaker(engine);

        // Deploy Iblivion contracts with correct bitmaps
        baselight = Baselight(deployWithCorrectBitmap(new Baselight(IEngine(address(engine)))));
        brightback = new Brightback(IEngine(address(engine)), ITypeCalculator(address(typeCalc)), baselight);
        unboundedStrike = new UnboundedStrike(IEngine(address(engine)), ITypeCalculator(address(typeCalc)), baselight);
        loop = new Loop(IEngine(address(engine)), baselight, statBoost);
        renormalize = new Renormalize(IEngine(address(engine)), baselight, statBoost, loop);
    }

    // ============ Baselight Ability Tests ============

    function test_baselightStartsAtOneOnFirstSwitchIn() public {
        // Create a mon with Baselight ability
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(baselight))
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = mon;
        aliceTeam[1] = mon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = mon;
        bobTeam[1] = mon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Switch in mons
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Check that Baselight level is 2 (1 from switch-in + 1 from round end)
        uint256 baselightLevel = baselight.getBaselightLevel(battleKey, 0, 0);
        assertEq(baselightLevel, 2, "Baselight should be 2 after first switch in (1 initial + 1 from round end)");
    }

    function test_baselightGainsOnePerRound() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Baselight starts at 2 (1 from switch + 1 from round end)
        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 2, "Should start at 2 after switch-in round");

        // After one more round, should be 3 (max)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0
        );
        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 3, "Should be 3 (max) after one more round");

        // After another round, should still be 3 (capped at max)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0
        );
        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 3, "Should stay at 3 (max)");
    }

    // ============ Brightback Tests ============

    function test_brightbackHealsWithStack() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(baselight))
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
            ability: IAbility(address(0))
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice starts with 2 Baselight stacks (1 from switch + 1 from round end)
        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 2, "Should start with 2 stacks");

        // Bob damages Alice first
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0
        );

        // Get Alice's HP before Brightback
        int32 aliceHpBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertTrue(aliceHpBefore < 0, "Alice should have taken damage");

        // After round, Baselight is now 3 (max)
        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 3, "Should be 3 (max) after round");

        // Alice uses Brightback - should consume 1 stack and heal
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0
        );

        // Check Baselight decreased by 1 (3 - 1 = 2, then +1 at round end = 3 max)
        uint256 afterBrightback = baselight.getBaselightLevel(battleKey, 0, 0);
        assertEq(afterBrightback, 3, "Baselight should be 3 (consumed 1 from 3, gained 1 at round end, capped at 3)");

        // Check Alice healed
        int32 aliceHpAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertTrue(aliceHpAfter > aliceHpBefore, "Alice should have healed");
    }

    function test_brightbackNoHealWithoutStack() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(0)) // No Baselight ability, so no stacks
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // No Baselight stacks
        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 0, "Should have 0 stacks without ability");

        // Bob damages Alice
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0
        );

        int32 aliceHpBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertTrue(aliceHpBefore < 0, "Alice should have taken damage");

        // Alice uses Brightback - should NOT heal (no stacks)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0
        );

        int32 aliceHpAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(aliceHpAfter, aliceHpBefore, "Alice should not have healed without stacks");
    }

    // ============ Unbounded Strike Tests ============

    function test_unboundedStrikeNormalPower() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(baselight))
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
            ability: IAbility(address(0))
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice has 2 stacks (not 3), so normal power (80)
        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 2, "Should have 2 stacks");

        // Alice uses Unbounded Strike
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, 0, 0
        );

        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertTrue(bobHpDelta < 0, "Bob should have taken damage");

        // Stacks should NOT be consumed (still 2, but round end adds 1 = 3 max)
        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 3, "Stacks should not be consumed at < 3, capped at 3 after round end");
    }

    function test_unboundedStrikeEmpoweredPower() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(baselight))
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
            ability: IAbility(address(0))
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Wait for 3 stacks (start at 2, need 1 more round)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 3, "Should have 3 stacks");

        // Get Bob's HP before
        int32 bobHpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        // Alice uses Unbounded Strike at 3 stacks - empowered (130 power)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, 0, 0
        );

        int32 bobHpAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int32 damageDealt = bobHpBefore - bobHpAfter;
        assertTrue(damageDealt > 0, "Bob should have taken damage");

        // All stacks consumed (but round end adds 1, so should be 1)
        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 1, "Stacks should be consumed to 0 then gain 1 at round end");
    }

    // ============ Loop Tests ============

    function test_loopAppliesStatBoosts() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // At Baselight 2, Loop should give 30% boost
        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 2, "Should have 2 stacks");

        // Get stats before Loop
        int32 attackBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);

        // Alice uses Loop
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0
        );

        // Check stats are boosted (30% of 100 = 30)
        int32 attackAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(attackAfter - attackBefore, 30, "Attack should be boosted by 30%");

        // Loop should be marked as active
        assertTrue(loop.isLoopActive(battleKey, 0, 0), "Loop should be active");
    }

    function test_loopFailsIfAlreadyActive() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses Loop first time
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0
        );

        int32 attackAfterFirst = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertTrue(loop.isLoopActive(battleKey, 0, 0), "Loop should be active");

        // Alice uses Loop second time - should fail
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0
        );

        int32 attackAfterSecond = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(attackAfterSecond, attackAfterFirst, "Attack should not change when Loop fails");
    }

    function test_loopBoostPercentages() public {
        // Test that Loop gives correct boosts at different Baselight levels
        // Level 1: 15%, Level 2: 30%, Level 3: 40%

        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Wait for 3 stacks (start at 2, need 1 more round)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 3, "Should have 3 stacks");

        // Get stats before Loop
        int32 attackBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);

        // Alice uses Loop at level 3 - should get 40% boost
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0
        );

        int32 attackAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(attackAfter - attackBefore, 40, "Attack should be boosted by 40% at level 3");
    }

    // ============ Renormalize Tests ============

    function test_renormalizeSetsBaselightToThree() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Start at 2 stacks (1 initial + 1 from round end)
        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 2, "Should have 2 stacks");

        // Alice uses Renormalize
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 3, NO_OP_MOVE_INDEX, 0, 0
        );

        // Should be at 3 stacks (set to 3, then capped at max even with round end)
        assertEq(baselight.getBaselightLevel(battleKey, 0, 0), 3, "Baselight should be set to 3");
    }

    function test_renormalizeClearsStatBoosts() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses Loop to get stat boosts
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0
        );

        int32 attackBoosted = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertTrue(attackBoosted > 0, "Attack should be boosted");

        // Alice uses Renormalize - should clear stat boosts
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 3, NO_OP_MOVE_INDEX, 0, 0
        );

        int32 attackAfterRenormalize = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(attackAfterRenormalize, 0, "Attack boost should be cleared");
    }

    function test_renormalizeClearsLoopActive() public {
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(baselight))
        });

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses Loop
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0
        );

        assertTrue(loop.isLoopActive(battleKey, 0, 0), "Loop should be active");

        // Alice uses Renormalize
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 3, NO_OP_MOVE_INDEX, 0, 0
        );

        assertFalse(loop.isLoopActive(battleKey, 0, 0), "Loop should no longer be active");

        // Alice can use Loop again
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, 0, 0
        );

        int32 attackBoosted = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertTrue(attackBoosted > 0, "Attack should be boosted again after Renormalize");
    }

    function test_renormalizeHasLowerPriority() public {
        // Renormalize should have -1 priority (DEFAULT_PRIORITY - 1 = 2)
        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = brightback;
        moves[1] = unboundedStrike;
        moves[2] = loop;
        moves[3] = renormalize;

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
            ability: IAbility(address(baselight))
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
            ability: IAbility(address(baselight))
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = fastMon;
        aliceTeam[1] = fastMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = slowMon;
        bobTeam[1] = slowMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Check priority
        uint32 renomalPriority = renormalize.priority(battleKey, 0);
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
        BurnStatus burnStatus = new BurnStatus(IEngine(address(engine)), statBoost);
        MockEffectRemover effectRemover = new MockEffectRemover(IEngine(address(engine)));

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

        IMoveSet[] memory iblivionMoves = new IMoveSet[](4);
        iblivionMoves[0] = brightback;
        iblivionMoves[1] = unboundedStrike;
        iblivionMoves[2] = loop;
        iblivionMoves[3] = renormalize;

        IMoveSet[] memory opponentMoves = new IMoveSet[](4);
        opponentMoves[0] = burnAttack;
        opponentMoves[1] = effectRemover;
        opponentMoves[2] = loop;
        opponentMoves[3] = renormalize;

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
            ability: IAbility(address(baselight))
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
            ability: IAbility(address(0))
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = iblivionMon;
        aliceTeam[1] = iblivionMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = opponentMon;
        bobTeam[1] = opponentMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Switch in mons
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Verify Alice's attack starts at base (0 delta)
        int32 aliceAttackBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(aliceAttackBefore, 0, "Alice's attack delta should start at 0");

        // Bob inflicts burn on Alice (move index 0), Alice does nothing
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0
        );

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
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 3, NO_OP_MOVE_INDEX, 0, 0
        );

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

        // Bob uses MockEffectRemover to remove burn from Alice (move index 1)
        // Pass burn status address as extraData
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 1, 0, uint240(uint160(address(burnStatus)))
        );

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
        assertEq(aliceAttackFinal, 0, "Alice's attack should remain at base after burn removal (no double-removal issue)");
    }
}
