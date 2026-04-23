// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../lib/forge-std/src/Test.sol";

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";
import {DefaultValidator} from "../../src/DefaultValidator.sol";
import {Engine} from "../../src/Engine.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";

import {BattleHelper} from "../abstract/BattleHelper.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

contract StandardAttackRngTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    DefaultValidator validator;
    ITypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    StandardAttackFactory factory;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        mockOracle = new MockRandomnessOracle();
        engine = new Engine(0, 0, 0);
        commitManager = new DefaultCommitManager(engine);
        validator = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 100})
        );
        typeCalc = new TestTypeCalculator();
        defaultRegistry = new TestTeamRegistry();
        factory = new StandardAttackFactory(typeCalc);
        matchmaker = new DefaultMatchmaker(engine);
    }

    // When two mirror mons use the same volatile move against each other with the oracle feeding a single rng,
    // the per-attacker rng mix in StandardAttack._move must make the two damage rolls differ.
    // Without the mix, identical stats + identical raw rng would collapse to identical damage.
    function test_sameMoveFromMirrorMonsRollsDifferentDamage() public {
        IMoveSet attack = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 50,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 10,
                NAME: "Mirror",
                EFFECT: IEffect(address(0))
            })
        );

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(attack)));
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 10,
                speed: 5,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
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

        bytes32 battleKey =
            _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Switch in mon 0 on both sides.
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Oracle returns the same rng for both attackers this turn.
        mockOracle.setRNG(1);

        // Both players use move 0 simultaneously. Alice attacks Bob and Bob attacks Alice with the same move.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        int32 aliceHpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        assertLt(aliceHpDelta, 0, "Alice should have taken damage");
        assertLt(bobHpDelta, 0, "Bob should have taken damage");
        assertTrue(
            aliceHpDelta != bobHpDelta,
            "Mirror mons using the same move should not roll identical damage"
        );
    }
}
