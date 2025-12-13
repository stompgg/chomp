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
import {Storm} from "../../src/effects/weather/Storm.sol";

import {DualShock} from "../../src/mons/volthare/DualShock.sol";
import {MegaStarBlast} from "../../src/mons/volthare/MegaStarBlast.sol";
import {Overclock} from "../../src/mons/volthare/Overclock.sol";

import {DummyStatus} from "../mocks/DummyStatus.sol";

import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";

contract VolthareTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultValidator validator;
    Overclock overclock;
    Storm storm;
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
        storm = new Storm(IEngine(address(engine)), statBoost);
        overclock = new Overclock(IEngine(address(engine)), storm);
        attackFactory = new StandardAttackFactory(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        matchmaker = new DefaultMatchmaker(engine);
    }

    function test_overclockAppliesStorm() public {
        // Create a team with a mon that has Overclock ability
        IMoveSet[] memory moves = new IMoveSet[](0);

        // Create a mon with Overclock ability and nice round stats
        Mon memory overclockMon = Mon({
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
            ability: IAbility(address(overclock))
        });

        // Create a regular mon with the same stats but no ability
        Mon memory regularMon = Mon({
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

        // Create teams for Alice and Bob
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = overclockMon;
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

        // Verify that Storm effect is applied
        // Check if the Storm duration is set to the default duration (2) (because turn end already ran)
        uint256 stormDuration = storm.getDuration(battleKey, 0);
        assertEq(stormDuration, storm.DEFAULT_DURATION() - 1, "Storm should be applied with default duration");

        // Verify that Alice's mon's speed is boosted according to Storm's constants
        // Speed should be increased by 25%
        int32 expectedSpeedBoost = int32(int8(storm.SPEED_PERCENT()));
        int32 speedDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Speed);
        assertEq(speedDelta, expectedSpeedBoost, "Speed should be boosted");

        // Verify that Alice's mon's special defense is decreased according to Storm's constants
        // SpDef should be decreased (3/4)
        int32 expectedSpDefDebuff = -1 * int32(int8(storm.SP_DEF_PERCENT()));
        int32 spDefDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialDefense);
        assertEq(spDefDelta, expectedSpDefDebuff, "Special Defense should be decreased");

        // Bob's mon should not be affected by the Storm since it's on Alice's side
        int32 bobSpeedDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Speed);
        int32 bobSpDefDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.SpecialDefense);
        assertEq(bobSpeedDelta, 0, "Bob's mon's speed should not be affected by Storm");
        assertEq(bobSpDefDelta, 0, "Bob's mon's special defense should not be affected by Storm");

        // Alice swaps in mon index 1, Bob does nothing (duration is now 1)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(1), 0
        );

        // Verify that Alice's new mon's speed/spdef are affected the same way
        speedDelta = engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Speed);
        spDefDelta = engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.SpecialDefense);
        assertEq(speedDelta, expectedSpeedBoost, "Speed should be boosted");
        assertEq(spDefDelta, expectedSpDefDebuff, "Special Defense should be decreased");

        // Both players do nothing, storm subsides (duration is now 0)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        // Verify that Alice's mon's speed/spdef are reset
        speedDelta = engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Speed);
        spDefDelta = engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.SpecialDefense);
        assertEq(speedDelta, 0, "Speed should be reset after Storm subsides");
        assertEq(spDefDelta, 0, "Special Defense should be reset after Storm subsides");

        // Verify that Storm is removed from global effects
        (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, 2, 0);
        assertEq(effects.length, 0, "Storm effect should be removed from global effects after Storm subsides");
    }

    function test_doubleOverclock() public {
        // Create a team with a mon that has Overclock ability
        IMoveSet[] memory moves = new IMoveSet[](0);

        // Create a mon with Overclock ability and nice round stats
        Mon memory overclockMon = Mon({
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
            ability: IAbility(address(overclock))
        });

        // Create a regular mon with the same stats but no ability
        Mon memory regularMon = Mon({
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

        // Create teams for Alice and Bob
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = overclockMon;
        aliceTeam[1] = regularMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = regularMon;
        bobTeam[1] = overclockMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice does nothing, Bob switches in his Overclock mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, uint240(1)
        );

        // Verify that the stat changes are applied to Bob's mon
        int32 expectedSpeedBoost = int32(int8(storm.SPEED_PERCENT()));
        int32 expectedSpDefDebuff = int32(int8(storm.SP_DEF_PERCENT())) * -1;
        int32 bobSpeedDelta = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Speed);
        int32 bobSpDefDelta = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.SpecialDefense);
        assertEq(bobSpeedDelta, expectedSpeedBoost, "Bob's mon's speed should be boosted");
        assertEq(bobSpDefDelta, expectedSpDefDebuff, "Bob's mon's special defense should be decreased");

        // Wait a turn
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        // Alice's mon should have its stats reset
        int32 aliceSpeedDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Speed);
        int32 aliceSpDefDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialDefense);
        assertEq(aliceSpeedDelta, 0, "Alice's mon's speed should be reset");
        assertEq(aliceSpDefDelta, 0, "Alice's mon's special defense should be reset");

        // Bob should not be reset
        bobSpeedDelta = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Speed);
        bobSpDefDelta = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.SpecialDefense);
        assertEq(bobSpeedDelta, expectedSpeedBoost, "Bob's mon's speed should not be reset");
        assertEq(bobSpDefDelta, expectedSpDefDebuff, "Bob's mon's special defense should not be reset");

        // Wait another turn
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        // Bob's mon should have its stats reset
        bobSpeedDelta = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Speed);
        bobSpDefDelta = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.SpecialDefense);
        assertEq(bobSpeedDelta, 0, "Bob's mon's speed should be reset");
        assertEq(bobSpDefDelta, 0, "Bob's mon's special defense should be reset");
    }

    function test_megaStarBlast() public {
        // Create a team with a mon that has Overclock ability
        IMoveSet[] memory moves = new IMoveSet[](1);
        DummyStatus zapStatus = new DummyStatus();
        MegaStarBlast msb = new MegaStarBlast(engine, typeCalc, zapStatus, storm);
        moves[0] = IMoveSet(address(msb));

        // Create a mon with Overclock ability and nice round stats
        Mon memory overclockMon = Mon({
            stats: MonStats({
                hp: 100,
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
            ability: IAbility(address(overclock))
        });

        // Create a regular mon with the same stats but no ability
        Mon memory regularMon = Mon({
            stats: MonStats({
                hp: 1000, // Lots of HP
                stamina: 1,
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
        aliceTeam[0] = overclockMon;

        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = regularMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        IValidator validatorToUse = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        // Start a battle
        bytes32 battleKey = _startBattle(validatorToUse, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Verify that Storm is applied
        (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, 2, 0);
        assertEq(effects.length, 1, "Storm should be applied");
        assertEq(address(effects[0].effect), address(storm), "Storm should be applied");

        // Set RNG so that Zap is applied
        mockOracle.setRNG(2);

        // Alice uses Mega Star Blast, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), 0);

        // Verify that Bob's mon is zapped
        (effects, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 1, "Bob's mon should be zapped");
        assertEq(address(effects[0].effect), address(zapStatus), "Bob's mon should be zapped");

        // Verify that Bob has taken damage
        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(bobHpDelta, -1 * int32(msb.BASE_POWER()), "Bob's mon should take 150 damage");

        // Now that Storm has cleared, set RNG to be below 50, and ensure that nothing happens
        mockOracle.setRNG(51);

        // Alice uses Mega Star Blast, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), 0);

        // Verify that Bob's mon is not zapped
        (effects, ) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 1, "Bob's mon should not be zapped (again)");

        // Verify that Bob's mon did not take more damage
        int32 bobHpDelta2 = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(bobHpDelta2, bobHpDelta, "Bob's mon should not take more damage");
    }

    function test_dualShock() public {
        // Create a team with a mon that knows Dual Shock
        IMoveSet[] memory moves = new IMoveSet[](1);
        ZapStatus zapStatus = new ZapStatus(engine);
        DualShock dualShock = new DualShock(engine, typeCalc, zapStatus);
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
