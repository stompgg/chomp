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
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";
import {BattleHelper} from "../abstract/BattleHelper.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {Angery} from "../../src/mons/gorillax/Angery.sol";
import {RockPull} from "../../src/mons/gorillax/RockPull.sol";

contract GorillaxTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    StandardAttackFactory attackFactory;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine();
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        attackFactory = new StandardAttackFactory(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        matchmaker = new DefaultMatchmaker(engine);
    }

    function test_angery() public {
        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );
        Angery angery = new Angery(IEngine(address(engine)));

        // Create a team with a mon that has Angery ability
        IMoveSet[] memory moves = new IMoveSet[](1);
        uint256 hpScale = 100;

        // Strong attack is exactly max hp / threshold
        moves[0] = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: uint32(hpScale),
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Strong",
                EFFECT: IEffect(address(0))
            })
        );
        Mon memory angeryMon = Mon({
            stats: MonStats({
                hp: uint32(int32(angery.MAX_HP_DENOM()) * int32(uint32(hpScale))),
                stamina: 5,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(angery))
        });

        Mon[] memory team = new Mon[](1);
        team[0] = angeryMon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice chooses to attack, Bob chooses to do nothing for CHARGE_COUNT rounds
        for (uint256 i; i < angery.CHARGE_COUNT(); i++) {
            _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        }

        // Bobs's mon started with  HP = MAX_HP_DENOM * hpScale, it took 3 * hpScale damage
        // And it heals for hpScale
        // So it should have taken 2 * hpScale damage
        int32 bobMonHPDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(bobMonHPDelta, int32(-2 * int32(uint32(hpScale))));
    }

    function test_rockPull() public {
        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );
        RockPull rockPull = new RockPull(engine, typeCalc);
        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = rockPull;

        Mon memory gorillax = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 6,
                speed: 5,
                attack: 10, // Our own ATK is 2x our defense
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        Mon memory otherMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 5,
                speed: 5,
                attack: 10,
                defense: 10, // Same defense here to ensure things work as intended
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = gorillax;
        aliceTeam[1] = otherMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = otherMon;
        bobTeam[1] = otherMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses Rock Pull, Bob switches to mon index 1
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, SWITCH_MOVE_INDEX, uint240(0), uint240(1)
        );

        // Assert that Bob's mon index 0 took damage
        int32 bobMonHPDelta = -1 * engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertApproxEqRel(
            bobMonHPDelta, int32(rockPull.OPPONENT_BASE_POWER()), 2e17, "Damage dealt to opponent is within range"
        );

        // Alice uses Rock Pull, Bob does not switch
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Assert that Alice's mon index 0 took damage
        int32 aliceMonHPDelta = -1 * engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        // Note we multiply by 2 here to account for the self-damage, our stats are imbalanced to ensure the math is working as expected
        assertApproxEqRel(
            aliceMonHPDelta, int32(2 * rockPull.SELF_DAMAGE_BASE_POWER()), 2e17, "Damage dealt to self is within range"
        );
    }
}
