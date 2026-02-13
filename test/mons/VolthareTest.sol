// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Structs.sol";
import {Test} from "forge-std/Test.sol";

import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";
import {Engine} from "../../src/Engine.sol";
import {MonStateIndexName, Type} from "../../src/Enums.sol";

import {DefaultValidator} from "../../src/DefaultValidator.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IValidator} from "../../src/IValidator.sol";
import {IAbility} from "../../src/abilities/IAbility.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";

import {BattleHelper} from "../abstract/BattleHelper.sol";

import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {StatBoosts} from "../../src/effects/StatBoosts.sol";

import {ZapStatus} from "../../src/effects/status/ZapStatus.sol";
import {Overclock} from "../../src/effects/battlefield/Overclock.sol";

import {DualShock} from "../../src/mons/volthare/DualShock.sol";
import {MegaStarBlast} from "../../src/mons/volthare/MegaStarBlast.sol";
import {PreemptiveShock} from "../../src/mons/volthare/PreemptiveShock.sol";

import {DummyStatus} from "../mocks/DummyStatus.sol";
import {GlobalEffectAttack} from "../mocks/GlobalEffectAttack.sol";

import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";

contract VolthareTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultValidator validator;
    PreemptiveShock preemptiveShock;
    Overclock overclock;
    StatBoosts statBoost;
    StandardAttackFactory attackFactory;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine();
        validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 0, TIMEOUT_DURATION: 10})
        );
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        statBoost = new StatBoosts(IEngine(address(engine)));
        overclock = new Overclock(IEngine(address(engine)), statBoost);
        preemptiveShock = new PreemptiveShock(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        attackFactory = new StandardAttackFactory(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        matchmaker = new DefaultMatchmaker(engine);
    }

    /**
     * Test: PreemptiveShock deals damage when switching in
     * - When a mon with PreemptiveShock ability switches in, it should deal BASE_POWER (15)
     *   Lightning Physical damage to the opponent's active mon
     */
    function test_preemptiveShockDealsDamage() public {
        IMoveSet[4] memory moves;

        // Create a mon with PreemptiveShock ability
        Mon memory preemptiveShockMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 100,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 100,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(preemptiveShock))
        });

        // Create a regular mon with no ability
        Mon memory regularMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 100,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 100,
                type1: Type.Fire, // Not Lightning, so no same-type resistance
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        // Create teams for Alice and Bob
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = preemptiveShockMon;
        aliceTeam[1] = regularMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = regularMon;
        bobTeam[1] = regularMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Verify that Bob's mon took damage from PreemptiveShock
        // Damage can vary due to DEFAULT_VOL (10), so check it's within expected range
        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int32 basePower = int32(preemptiveShock.BASE_POWER());
        int32 volatility = int32(preemptiveShock.DEFAULT_VOL());
        assertTrue(bobHpDelta <= -basePower + volatility, "Bob's mon should take at least min PreemptiveShock damage");
        assertTrue(bobHpDelta >= -basePower - volatility, "Bob's mon should take at most max PreemptiveShock damage");
    }

    /**
     * Test: MegaStarBlast with Overclock active
     * - Uses a mock move to apply Overclock, then tests that MegaStarBlast has increased accuracy
     *   and can apply Zap status when Overclock is active
     */
    function test_megaStarBlast() public {
        // Create moves: one to apply Overclock, one is MegaStarBlast
        DummyStatus zapStatus = new DummyStatus();
        MegaStarBlast msb = new MegaStarBlast(engine, typeCalc, zapStatus, overclock);
        GlobalEffectAttack overclockMove = new GlobalEffectAttack(
            engine,
            overclock,
            GlobalEffectAttack.Args({TYPE: Type.Lightning, STAMINA_COST: 0, PRIORITY: 0})
        );

        IMoveSet[4] memory moves;
        moves[0] = IMoveSet(address(overclockMove));
        moves[1] = IMoveSet(address(msb));

        // Create a mon with no ability
        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 100,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        // Create a regular mon with lots of HP
        Mon memory regularMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 10,
                speed: 1,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        // Create teams for Alice and Bob
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;

        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = regularMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        IValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        // Start a battle
        bytes32 battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses the Overclock move (move index 0), Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), 0);

        // Verify that Overclock is applied
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 2, 0);
        assertEq(effects.length, 1, "Overclock should be applied");
        assertEq(address(effects[0].effect), address(overclock), "Overclock should be applied");

        // Set RNG so that Zap is applied
        mockOracle.setRNG(2);

        // Alice uses Mega Star Blast (move index 1), Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, uint240(0), 0);

        // Verify that Bob's mon is zapped
        (effects,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 1, "Bob's mon should be zapped");
        assertEq(address(effects[0].effect), address(zapStatus), "Bob's mon should be zapped");

        // Verify that Bob has taken damage
        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(bobHpDelta, -1 * int32(msb.BASE_POWER()), "Bob's mon should take 150 damage");

        // Now that Overclock has cleared, set RNG to be below 50, and ensure that nothing happens
        mockOracle.setRNG(msb.BASE_ACCURACY() + 1);

        // Alice uses Mega Star Blast, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, uint240(0), 0);

        // Verify that Bob's mon is not zapped (again)
        (effects,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 1, "Bob's mon should not be zapped (again)");

        // Verify that Bob's mon did not take more damage
        int32 bobHpDelta2 = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(bobHpDelta2, bobHpDelta, "Bob's mon should not take more damage");
    }

    function test_dualShock() public {
        // Create a team with a mon that knows Dual Shock
        IMoveSet[4] memory moves;
        ZapStatus zapStatus = new ZapStatus(engine);
        DualShock dualShock = new DualShock(engine, typeCalc, zapStatus, overclock);
        moves[0] = IMoveSet(address(dualShock));

        // Create a mon with nice round stats
        Mon memory fastMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 100,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 100,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });
        Mon memory slowMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 1,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 100,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        // Create teams for Alice and Bob
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = fastMon;

        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = slowMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(
            new DefaultValidator(
                IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
            ),
            engine,
            mockOracle,
            defaultRegistry,
            matchmaker,
            address(commitManager)
        );

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Both players use Dual Shock, Alice should move first and skip their next move
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Alice's mon should have the skip turn flag set
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.ShouldSkipTurn), 1);
    }
}
