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
import {IEffect} from "../../src/effects/IEffect.sol";
import {StatBoosts} from "../../src/effects/StatBoosts.sol";
import {BurnStatus} from "../../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../../src/effects/status/FrostbiteStatus.sol";
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

// Aurox moves
import {BullRush} from "../../src/mons/aurox/BullRush.sol";
import {GildedRecovery} from "../../src/mons/aurox/GildedRecovery.sol";
import {IronWall} from "../../src/mons/aurox/IronWall.sol";
import {UpOnly} from "../../src/mons/aurox/UpOnly.sol";
import {VolatilePunch} from "../../src/mons/aurox/VolatilePunch.sol";

 /**
        - Bull Rush correctly deals SELF_DAMAGE_PERCENT of max hp to self [x]
        - Gilded Recovery heals for HEAL_PERCENT of max hp if there is a status effect [x]
        - Gilded Recovery gives +1 stamina if there is a status effect [x]
        - Iron Wall correctly heals damage dealt until end of next turn [x]
        - Up Only correctly boosts on damage, and it stays on switch in/out [x]
        - Volatile Punch correctly deals damage and can trigger status effects
            - rng of 2 should trigger frostbite
            - rng of 10 should trigger burn
     */

contract AuroxTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    StatBoosts statBoosts;
    DefaultMatchmaker matchmaker;
    StandardAttackFactory attackFactory;

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine();
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        statBoosts = new StatBoosts(IEngine(address(engine)));
        matchmaker = new DefaultMatchmaker(engine);
        attackFactory = new StandardAttackFactory(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
    }

    function testBullRush() public {
        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );
        BullRush bullRush = new BullRush(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = bullRush;

        Mon memory mon = _createMon();
        mon.moves = moves;
        uint32 maxHp = 10 * uint32(bullRush.SELF_DAMAGE_PERCENT());
        mon.stats.hp = maxHp;
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );
        // Alice uses Bull Rush, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        int32 aliceHpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        int32 expectedSelfDamage = -1 * int32(maxHp) * int32(bullRush.SELF_DAMAGE_PERCENT()) / 100;
        assertEq(aliceHpDelta, expectedSelfDamage, "Alice should take self damage");
    }

    function test_gildedRecoveryHealsWithStatus() public {
        FrostbiteStatus frostbiteStatus = new FrostbiteStatus(IEngine(address(engine)), statBoosts);
        GildedRecovery gildedRecovery = new GildedRecovery(IEngine(address(engine)));

        uint32 maxHp = 100;

        // Create an attack that inflicts frostbite
        StandardAttack frostbiteAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Ice,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Frostbite Attack",
                EFFECT: IEffect(address(frostbiteStatus))
            })
        );

        // Create an attack with base power of maxHp / 2
        StandardAttack attack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: maxHp / 2,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Attack",
                EFFECT: IEffect(address(0))
            })
        );

        StandardAttack zeroDamageStaminaAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Stamina Attack",
                EFFECT: IEffect(address(0))
            })
        );

        IMoveSet[] memory moves = new IMoveSet[](4);
        moves[0] = frostbiteAttack;
        moves[1] = attack;
        moves[2] = gildedRecovery;
        moves[3] = zeroDamageStaminaAttack;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = maxHp;
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: team.length, MOVES_PER_MON: moves.length, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice spends 1 stamina, Bob inflicts frostbite
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 3, 0, 0, 0);

        // Verify that Alice's mon index 0 has spent 1 stamina
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina),
            -1,
            "Alice's mon should have -1 staminaDelta"
        );

        // Verify that Alice's mon index 0 has -1 staminaDelta
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina),
            -1,
            "Alice's mon should have -1 staminaDelta"
        );

        // Alice swaps to mon index 1, Bob does the 50% attack
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, 1, uint240(1), 0);

        // Verify that Alice's mon index 1 has taken 50% damage
        int32 aliceDamage = engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Hp);
        assertEq(
            aliceDamage,
            -1 * int32(maxHp) * int32(gildedRecovery.HEAL_PERCENT()) / 100,
            "Alice's mon should take 50% damage"
        );

        // Alice uses Gilded Recovery targeting self, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, uint240(1), 0);

        // Nothing should happen, mon index 0 for Alice should still have -1 staminaDelta, hpDelta for mon index 1 should still be the same
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina),
            -1,
            "Alice's mon should have -1 staminaDelta"
        );
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Hp),
            aliceDamage,
            "Alice's mon should have same damage"
        );

        // Alice uses Gilded Recovery targeting mon index , Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, uint240(0), 0);

        // Verify that Alice's mon index 1 is healed by 50% and mon index 0 has staminaDelta of 0, and no longer has frostbite
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Hp), 0, "Alice's mon should be healed by 50%"
        );
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina),
            0,
            "Alice's mon should have 0 staminaDelta"
        );
        (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, 0, 0);
        for (uint256 i = 0; i < effects.length; i++) {
            assertNotEq(address(effects[i].effect), address(frostbiteStatus), "Alice's mon should no longer have frostbite");
        }
    }

    function test_ironWallHealsDamage() public {
        uint32 maxHp = 100;

        IronWall ironWall = new IronWall(IEngine(address(engine)));
        StandardAttack attack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: maxHp / 2,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Attack",
                EFFECT: IEffect(address(0))
            })
        );

        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = ironWall;
        moves[1] = attack;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = maxHp;
        Mon[] memory fastTeam = new Mon[](1);
        fastTeam[0] = mon;
        fastTeam[0].stats.speed = 2;
        Mon[] memory slowTeam = new Mon[](1);
        slowTeam[0] = mon;

        defaultRegistry.setTeam(ALICE, fastTeam);
        defaultRegistry.setTeam(BOB, slowTeam);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: fastTeam.length, MOVES_PER_MON: moves.length, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses Iron Wall, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        
        // Alice does nothing, Bob attacks
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 1, 0, 0);

        // Verify that Alice's mon index 0 has taken damage (should be the basePower of the move multiplied by 100 - the heal percent)
        int32 aliceDamage = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(aliceDamage, -1 * int32(attack.basePower(battleKey)) * int32(100 - ironWall.HEAL_PERCENT()) / 100, "Alice's mon should take reduced damage");

        // Verify that the effect is gone
        (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, 0, 0);
        for (uint256 i = 0; i < effects.length; i++) {
            assertNotEq(address(effects[i].effect), address(ironWall), "Alice's mon should no longer have Iron Wall");
        }
    }

    function test_ironWallSkipsIfKO() public {
        uint32 maxHp = 100;

        IronWall ironWall = new IronWall(IEngine(address(engine)));
        StandardAttack attack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: maxHp,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Attack",
                EFFECT: IEffect(address(0))
            })
        );

        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = ironWall;
        moves[1] = attack;

        Mon memory fastMon = _createMon();
        fastMon.moves = moves;
        fastMon.stats.hp = maxHp;
        Mon memory slowMon = _createMon();
        slowMon.moves = moves;
        slowMon.stats.hp = maxHp;
        Mon[] memory team = new Mon[](2);
        team[0] = fastMon;
        team[1] = slowMon;

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

        // Alice uses Iron Wall, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Alice does nothing, Bob attacks
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 1, 0, 0);

        // Verify that Alice's mon index 0 is KO'ed
        int32 isKnockedOut = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut);
        assertEq(isKnockedOut, 1, "Alice's mon should be KO'ed");

        //Verify that HP delta is -100
        int32 hpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(hpDelta, -100, "Alice's mon should have -100 HP delta");
    }

    function test_upOnlyBoostsOnDamage() public {
        uint32 maxHp = 100;
        uint32 maxAtk = 100;
        uint32 maxDef = 100;

        UpOnly upOnly = new UpOnly(IEngine(address(engine)), statBoosts);
        StandardAttack attack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: maxHp / 2,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Attack",
                EFFECT: IEffect(address(0))
            })
        );
        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = attack;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.ability = upOnly;
        mon.stats.hp = maxHp;
        mon.stats.attack = maxAtk;
        mon.stats.defense = maxDef;
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

        // Alice uses attack, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify that Bob's mon index 0 has a positive attack delta of upOnly.ATTACK_BOOST_PERCENT()
        int32 bobAttackDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Attack);
        assertEq(bobAttackDelta, int32(int8(upOnly.ATTACK_BOOST_PERCENT())) * int32(maxHp) / 100, "Bob's mon should be boosted");

        // Alice does nothing, Bob switches to mon index 1
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, uint240(1));

        // Verify that Bob's mon index 0 has a positive attack delta of upOnly.ATTACK_BOOST_PERCENT()
        bobAttackDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Attack);
        assertEq(bobAttackDelta, int32(int8(upOnly.ATTACK_BOOST_PERCENT())) * int32(maxHp) / 100, "Bob's mon should be boosted");
    }

    function test_volatilePunchDealsDamageAndTriggersStatusEffects() public {
        uint32 maxHp = 100;

        BurnStatus burnStatus = new BurnStatus(IEngine(address(engine)), statBoosts);
        FrostbiteStatus frostbiteStatus = new FrostbiteStatus(IEngine(address(engine)), statBoosts);
        VolatilePunch volatilePunch = new VolatilePunch(
            IEngine(address(engine)), typeCalc, burnStatus, frostbiteStatus
        );
        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = volatilePunch;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = maxHp;
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

        // Set rng to be 2 to trigger frostbite
        mockOracle.setRNG(2);

        // Alice uses volatile punch, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify that Bob's mon index 0 has frostbite (first effect is stat boost)
        (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, 1, 0);

        assertEq(address(effects[1].effect), address(frostbiteStatus), "Bob's mon should have frostbite");

        // Set rng to be 10 to trigger burn
        mockOracle.setRNG(6);

        // Alice does nothing, Bob uses volatile punch
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Verify that Alice's mon index 0 has burn (first effect is stat boost)
        (effects, ) = engine.getEffects(battleKey, 0, 0);
        assertEq(address(effects[1].effect), address(burnStatus), "Alice's mon should have burn");
    }
}
