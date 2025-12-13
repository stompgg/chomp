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
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";

import {BattleHelper} from "../abstract/BattleHelper.sol";

import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {StatBoosts} from "../../src/effects/StatBoosts.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";

import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {ActusReus} from "../../src/mons/malalien/ActusReus.sol";
import {TripleThink} from "../../src/mons/malalien/TripleThink.sol";

contract MalalienTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    ActusReus actusReus;
    StandardAttackFactory attackFactory;
    StatBoosts statBoosts;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine();
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        statBoosts = new StatBoosts(engine);
        actusReus = new ActusReus(IEngine(address(engine)), statBoosts);
        attackFactory = new StandardAttackFactory(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        matchmaker = new DefaultMatchmaker(engine);
    }

    function test_actusReusIndictment() public {
        // Create a StandardAttack that can KO a mon in one hit
        IMoveSet[] memory moves = new IMoveSet[](1);
        uint256 hpScale = 100;

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
                NAME: "KO Attack",
                EFFECT: IEffect(address(0))
            })
        );

        // Create a mon with ActusReus ability
        Mon memory actusReusMon = Mon({
            stats: MonStats({
                hp: uint32(hpScale),
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
            ability: IAbility(address(actusReus))
        });

        // Create a regular mon
        Mon memory regularMon = Mon({
            stats: MonStats({
                hp: uint32(hpScale),
                stamina: 10,
                speed: 4,
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

        // Create teams with 3 mons each
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = actusReusMon;
        aliceTeam[1] = regularMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = regularMon;
        bobTeam[1] = regularMon;

        // Register teams
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice's mon has ActusReus ability
        // Alice attacks and KOs Bob's mon
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Bob's mon is KO'd
        int32 isKnockedOut = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut);
        assertEq(isKnockedOut, 1, "Bob's mon should be KO'd");

        // Verify that Alice's mon has an indictment charge
        (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, 0, 0);
        bool indictmentFound = false;
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(actusReus) && uint256(effects[i].data) == 1) {
                indictmentFound = true;
                break;
            }
        }
        assertTrue(indictmentFound, "Alice's mon should have an indictment charge");

        // Bob switches to mon index 1
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(1), true);

        // Alice does nothing, Bob attacks and KOs Alice's mon
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Verify Alice's mon is KO'd
        isKnockedOut = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut);
        assertEq(isKnockedOut, 1, "Alice's mon should be KO'd");

        // Get Bob's mon index 1's original speed
        int32 originalSpeed = int32(engine.getMonValueForBattle(battleKey, 1, 1, MonStateIndexName.Speed));

        // Get Bob's mon's speed after the debuff
        int32 speedDelta = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Speed);

        // Calculate expected speed debuff
        int32 expectedSpeedDebuff = -1 * originalSpeed * (100 - int32(int8(actusReus.SPEED_DEBUFF_PERCENT()))) / 100;

        // Verify the speed debuff was applied correctly
        assertEq(speedDelta, expectedSpeedDebuff, "Bob's mon should have a speed debuff");
    }

    function test_tripleThink() public {
        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );
        IMoveSet[] memory moves = new IMoveSet[](1);
        TripleThink tripleThink = new TripleThink(engine, statBoosts);
        moves[0] = tripleThink;
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1,
                stamina: 10,
                speed: 4,
                attack: 5,
                defense: 5,
                specialAttack: 100,
                specialDefense: 5,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        // Start battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Alice and Bob both send in mon index 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Both players use triple think
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, uint240(0), uint240(0));

        // SpecialAttack delta for both is 100
        int32 aliceSpAtkBoost = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        int32 bobSpAtkBoost = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.SpecialAttack);

        assertEq(aliceSpAtkBoost, int32(int8(tripleThink.SP_ATTACK_BUFF_PERCENT())), "Buff applied for Alice");
        assertEq(bobSpAtkBoost, int32(int8(tripleThink.SP_ATTACK_BUFF_PERCENT())), "Buff applied for Bob");

        // Alice uses it again, Bob swaps out
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, SWITCH_MOVE_INDEX, uint240(0), uint240(1)
        );

        // Alice should be at 1.75 * 1.75 = 1.225 + 1.75 + 0.0875 = 2.0625, Bob should be at 0
        aliceSpAtkBoost = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        bobSpAtkBoost = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.SpecialAttack);

        // The boost is the amount we need to get the total amount to the right multiplier
        // (so we subtract 100 because that's the base stat)
        int32 newAmount = (((100 + int32(int8(tripleThink.SP_ATTACK_BUFF_PERCENT()))) ** 2) / 100) - 100;

        assertEq(aliceSpAtkBoost, newAmount, "Buff applied again for Alice");
        assertEq(bobSpAtkBoost, 0, "Bob buff wore off");
    }
}
