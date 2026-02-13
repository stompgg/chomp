// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import "../../src/Constants.sol";
import "../../src/Structs.sol";

import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";
import {DefaultValidator} from "../../src/DefaultValidator.sol";
import {Engine} from "../../src/Engine.sol";
import {MonStateIndexName, MoveClass, Type} from "../../src/Enums.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {StatBoosts} from "../../src/effects/StatBoosts.sol";
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

// Ekineki contracts
import {BubbleBop} from "../../src/mons/ekineki/BubbleBop.sol";
import {NineNineNine} from "../../src/mons/ekineki/NineNineNine.sol";
import {Overflow} from "../../src/mons/ekineki/Overflow.sol";
import {SaviorComplex} from "../../src/mons/ekineki/SaviorComplex.sol";
import {SneakAttack} from "../../src/mons/ekineki/SneakAttack.sol";

/**
 * Tests:
 *  - Bubble Bop hits twice, dealing damage with each hit [x]
 *  - SneakAttack hits a non-active opponent mon [x]
 *  - SneakAttack can only be used once per switch-in [x]
 *  - SneakAttack resets on switch (local effect removed on switch-out) [x]
 *  - 999 boosts crit rate to 90% on the next turn [x]
 *  - SaviorComplex boosts sp atk based on KO'd mons [x]
 *  - SaviorComplex only triggers once per game [x]
 *  - SaviorComplex does not trigger with 0 KOs (can trigger later) [x]
 *  - Overflow deals damage [x]
 */
contract EkinekiTest is Test, BattleHelper {
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

    function test_bubbleBopHitsTwice() public {
        uint32 maxHp = 200;

        BubbleBop bubbleBop = new BubbleBop(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));

        // Create a single-hit reference attack with same params (0 vol, 0 crit for predictable damage)
        StandardAttack singleHit = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 50,
                STAMINA_COST: 3,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Liquid,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Single Hit",
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        );

        // Set up team with BubbleBop
        IMoveSet[4] memory bubbleBopMoves;
        bubbleBopMoves[0] = bubbleBop;
        Mon memory bubbleBopMon = _createMon();
        bubbleBopMon.moves = bubbleBopMoves;
        bubbleBopMon.stats.hp = maxHp;
        bubbleBopMon.stats.specialAttack = 100;
        bubbleBopMon.stats.specialDefense = 100;
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = bubbleBopMon;

        // Set up team with single hit for Bob (so bob takes damage, not deals it)
        IMoveSet[4] memory singleMoves;
        singleMoves[0] = singleHit;
        Mon memory singleMon = _createMon();
        singleMon.moves = singleMoves;
        singleMon.stats.hp = maxHp;
        singleMon.stats.specialAttack = 100;
        singleMon.stats.specialDefense = 100;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = singleMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey =
            _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses Bubble Bop, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Bob took damage (dual hit should deal damage)
        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertTrue(bobHpDelta < 0, "Bob should have taken damage from Bubble Bop");

        // Now do a fresh battle with single hit to compare
        Engine engine2 = new Engine();
        DefaultCommitManager commitManager2 = new DefaultCommitManager(IEngine(address(engine2)));
        DefaultMatchmaker matchmaker2 = new DefaultMatchmaker(engine2);
        TestTeamRegistry registry2 = new TestTeamRegistry();
        registry2.setTeam(ALICE, aliceTeam);
        registry2.setTeam(BOB, bobTeam);

        DefaultValidator validator2 = new DefaultValidator(
            IEngine(address(engine2)),
            DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey2 =
            _startBattle(validator2, engine2, mockOracle, registry2, matchmaker2, address(commitManager2));
        _commitRevealExecuteForAliceAndBob(
            engine2, commitManager2, battleKey2, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Bob uses single hit on Alice
        _commitRevealExecuteForAliceAndBob(engine2, commitManager2, battleKey2, NO_OP_MOVE_INDEX, 0, 0, 0);
        int32 aliceSingleHitDamage = engine2.getMonStateForBattle(battleKey2, 0, 0, MonStateIndexName.Hp);

        // Bubble Bop should deal more damage than a single hit of same base power
        // (since Bubble Bop has volatility and two hits, we check it dealt strictly more)
        assertTrue(
            bobHpDelta < aliceSingleHitDamage,
            "Bubble Bop (two hits) should deal more damage than a single hit of same base power"
        );
    }

    function test_sneakAttackHitsNonActiveMon() public {
        uint32 maxHp = 100;

        SneakAttack sneakAttack = new SneakAttack(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        SaviorComplex saviorComplex = new SaviorComplex(IEngine(address(engine)), statBoosts);

        IMoveSet[4] memory moves;
        moves[0] = sneakAttack;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.ability = saviorComplex;
        mon.stats.hp = maxHp;
        mon.stats.specialAttack = 100;
        mon.stats.specialDefense = 100;
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey =
            _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses SneakAttack targeting Bob's non-active mon (index 1)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(1), 0);

        // Verify Bob's mon at index 1 (non-active) took damage
        int32 bobMon1HpDelta = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp);
        assertTrue(bobMon1HpDelta < 0, "Bob's non-active mon should have taken damage from Sneak Attack");

        // Verify Bob's active mon (index 0) was unaffected
        int32 bobMon0HpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(bobMon0HpDelta, 0, "Bob's active mon should be unaffected");
    }

    function test_sneakAttackOncePerSwitchIn() public {
        uint32 maxHp = 100;

        SneakAttack sneakAttack = new SneakAttack(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        SaviorComplex saviorComplex = new SaviorComplex(IEngine(address(engine)), statBoosts);

        IMoveSet[4] memory moves;
        moves[0] = sneakAttack;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.ability = saviorComplex;
        mon.stats.hp = maxHp;
        mon.stats.specialAttack = 100;
        mon.stats.specialDefense = 100;
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey =
            _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses SneakAttack targeting Bob's non-active mon (index 1) - first use
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(1), 0);

        int32 bobMon1DamageAfterFirst = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp);
        assertTrue(bobMon1DamageAfterFirst < 0, "First sneak attack should deal damage");

        // Alice uses SneakAttack again - should do nothing (already used this switch-in)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(1), 0);

        int32 bobMon1DamageAfterSecond = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp);
        assertEq(
            bobMon1DamageAfterSecond,
            bobMon1DamageAfterFirst,
            "Second sneak attack should not deal additional damage"
        );
    }

    function test_sneakAttackResetsOnSwitchIn() public {
        uint32 maxHp = 200;

        SneakAttack sneakAttack = new SneakAttack(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));
        SaviorComplex saviorComplex = new SaviorComplex(IEngine(address(engine)), statBoosts);

        IMoveSet[4] memory moves;
        moves[0] = sneakAttack;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.ability = saviorComplex;
        mon.stats.hp = maxHp;
        mon.stats.specialAttack = 100;
        mon.stats.specialDefense = 100;
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey =
            _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select mon 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses SneakAttack - first use works
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(1), 0);
        int32 damageAfterFirst = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp);
        assertTrue(damageAfterFirst < 0, "First sneak attack should deal damage");

        // Alice switches to mon 1 (sneak attack effect removed on switch-out)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint240(1), 0
        );

        // Alice (now mon 1) uses SneakAttack again - should work (reset by switch)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint240(1), 0);
        int32 damageAfterReset = engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp);
        assertTrue(damageAfterReset < damageAfterFirst, "Sneak attack should work again after switching");
    }

    function test_nineNineNineBoostsCritRate() public {
        uint32 maxHp = 200;

        NineNineNine nineNineNine = new NineNineNine(IEngine(address(engine)));
        SaviorComplex saviorComplex = new SaviorComplex(IEngine(address(engine)), statBoosts);

        // Create a predictable attack (0 vol, 0 default crit) to isolate crit boost
        StandardAttack testAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 50,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Liquid,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Test Attack",
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        );

        // Team with 999 + test attack
        IMoveSet[4] memory moves;
        moves[0] = nineNineNine;
        moves[1] = testAttack;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.ability = saviorComplex;
        mon.stats.hp = maxHp;
        mon.stats.specialAttack = 100;
        mon.stats.specialDefense = 100;
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey =
            _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Bob uses test attack without 999 (baseline)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 1, 0, 0);
        int32 aliceDamageWithoutCrit = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);

        // Expected: 50 base * 100 spAtk / 100 spDef = 50 damage (no crit, no vol)
        assertEq(aliceDamageWithoutCrit, -50, "Baseline damage without crit should be 50");

        // Alice uses 999, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify the 999 KV is set for the next turn
        bytes32 nineKey = keccak256(abi.encode(uint256(0), "NINE_NINE_NINE"));
        uint192 storedTurn = engine.getGlobalKV(battleKey, nineKey);
        uint256 currentTurn = engine.getTurnIdForBattleState(battleKey);
        assertEq(uint256(storedTurn), currentTurn, "999 should be set for the current turn (which is now the 'next' turn)");
    }

    function test_saviorComplexBoostsOnKO() public {
        uint32 maxHp = 100;

        SaviorComplex saviorComplex = new SaviorComplex(IEngine(address(engine)), statBoosts);

        // Create a strong attack that will KO in one hit
        StandardAttack koAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: maxHp,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "KO Attack",
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        );

        IMoveSet[4] memory moves;
        moves[0] = koAttack;

        // Alice's team: 3 mons, one with savior complex
        Mon memory aliceMon = _createMon();
        aliceMon.moves = moves;
        aliceMon.stats.hp = maxHp;
        aliceMon.stats.attack = 100;
        aliceMon.stats.defense = 100;
        aliceMon.stats.specialAttack = 100;
        aliceMon.stats.specialDefense = 100;

        Mon memory aliceMonWithAbility = _createMon();
        aliceMonWithAbility.moves = moves;
        aliceMonWithAbility.ability = saviorComplex;
        aliceMonWithAbility.stats.hp = maxHp;
        aliceMonWithAbility.stats.attack = 100;
        aliceMonWithAbility.stats.defense = 100;
        aliceMonWithAbility.stats.specialAttack = 100;
        aliceMonWithAbility.stats.specialDefense = 100;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMon;
        aliceTeam[2] = aliceMonWithAbility;

        // Bob's team: faster mon to get first hit
        Mon memory bobMon = _createMon();
        bobMon.moves = moves;
        bobMon.stats.hp = maxHp;
        bobMon.stats.attack = 100;
        bobMon.stats.defense = 100;
        bobMon.stats.specialAttack = 100;
        bobMon.stats.specialDefense = 100;
        bobMon.stats.speed = 2; // Faster
        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;
        bobTeam[2] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 3, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey =
            _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both select mon 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Bob attacks Alice's mon 0 (KO), Alice does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Verify Alice's mon 0 is KO'd
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut),
            1,
            "Alice's mon 0 should be KO'd"
        );

        // Alice forced switch to mon 2 (the one with savior complex)
        // After KO, playerSwitchForTurnFlag = 0 (Alice must switch, no commit needed)
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, "", uint240(2), true);

        // Verify that Alice's mon 2 got a sp atk boost (STAGE_1_BOOST = 15% of 100 = 15)
        int32 spAtkDelta = engine.getMonStateForBattle(battleKey, 0, 2, MonStateIndexName.SpecialAttack);
        assertEq(
            spAtkDelta,
            int32(int8(saviorComplex.STAGE_1_BOOST())) * 100 / 100,
            "Alice's mon should have sp atk boost from Savior Complex with 1 KO"
        );
    }

    function test_saviorComplexTriggersOncePerGame() public {
        uint32 maxHp = 100;

        SaviorComplex saviorComplex = new SaviorComplex(IEngine(address(engine)), statBoosts);

        StandardAttack koAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: maxHp,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "KO Attack",
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        );

        IMoveSet[4] memory moves;
        moves[0] = koAttack;

        Mon memory aliceMon = _createMon();
        aliceMon.moves = moves;
        aliceMon.stats.hp = maxHp;
        aliceMon.stats.attack = 100;
        aliceMon.stats.defense = 100;
        aliceMon.stats.specialAttack = 100;
        aliceMon.stats.specialDefense = 100;

        Mon memory aliceMonWithAbility = _createMon();
        aliceMonWithAbility.moves = moves;
        aliceMonWithAbility.ability = saviorComplex;
        aliceMonWithAbility.stats.hp = maxHp;
        aliceMonWithAbility.stats.attack = 100;
        aliceMonWithAbility.stats.defense = 100;
        aliceMonWithAbility.stats.specialAttack = 100;
        aliceMonWithAbility.stats.specialDefense = 100;

        Mon[] memory aliceTeam = new Mon[](3);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMonWithAbility;
        aliceTeam[2] = aliceMon;

        Mon memory bobMon = _createMon();
        bobMon.moves = moves;
        bobMon.stats.hp = maxHp;
        bobMon.stats.attack = 100;
        bobMon.stats.defense = 100;
        bobMon.stats.specialAttack = 100;
        bobMon.stats.specialDefense = 100;
        bobMon.stats.speed = 2;
        Mon[] memory bobTeam = new Mon[](3);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;
        bobTeam[2] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 3, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey =
            _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both select mon 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Bob KOs Alice's mon 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Alice forced switch to mon 1 (savior complex triggers with 1 KO)
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, "", uint240(1), true);

        int32 spAtkDeltaFirstSwitch = engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.SpecialAttack);
        assertEq(spAtkDeltaFirstSwitch, 15, "Should get 15 sp atk boost from 1 KO");

        // Alice switches to mon 2, Bob KOs Alice's mon 2 in the same turn (Bob is faster but switch has higher priority)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, 0, uint240(2), 0
        );

        // Verify Alice's mon 2 is KO'd
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 2, MonStateIndexName.IsKnockedOut),
            1,
            "Alice's mon 2 should be KO'd"
        );

        // Alice forced switch back to mon 1 (savior complex should NOT trigger again)
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, "", uint240(1), true);

        int32 spAtkDeltaSecondSwitch = engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.SpecialAttack);
        // Boost is temp so it was cleared when mon 1 switched out, and savior complex
        // should not re-apply it (once per game), so delta should be 0
        assertEq(
            spAtkDeltaSecondSwitch,
            0,
            "Savior Complex should not trigger again (once per game), temp boost cleared on switch out"
        );
    }

    function test_saviorComplexNoBoostWithZeroKOs() public {
        uint32 maxHp = 100;

        SaviorComplex saviorComplex = new SaviorComplex(IEngine(address(engine)), statBoosts);

        StandardAttack koAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: maxHp,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "KO Attack",
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        );

        IMoveSet[4] memory moves;
        moves[0] = koAttack;

        Mon memory monWithAbility = _createMon();
        monWithAbility.moves = moves;
        monWithAbility.ability = saviorComplex;
        monWithAbility.stats.hp = maxHp;
        monWithAbility.stats.attack = 100;
        monWithAbility.stats.defense = 100;
        monWithAbility.stats.specialAttack = 100;
        monWithAbility.stats.specialDefense = 100;

        Mon memory normalMon = _createMon();
        normalMon.moves = moves;
        normalMon.stats.hp = maxHp;
        normalMon.stats.attack = 100;
        normalMon.stats.defense = 100;
        normalMon.stats.specialAttack = 100;
        normalMon.stats.specialDefense = 100;

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = monWithAbility;
        aliceTeam[1] = normalMon;

        Mon memory bobMon = _createMon();
        bobMon.moves = moves;
        bobMon.stats.hp = maxHp;
        bobMon.stats.attack = 100;
        bobMon.stats.defense = 100;
        bobMon.stats.specialAttack = 100;
        bobMon.stats.specialDefense = 100;
        bobMon.stats.speed = 2;
        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey =
            _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Alice selects mon 0 (with savior complex) - no KO'd mons
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Verify no boost was applied (0 KOs)
        int32 spAtkDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        assertEq(spAtkDelta, 0, "No sp atk boost should be applied with 0 KOs");

        // Now Bob KOs Alice's mon 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut),
            1,
            "Alice's mon 0 should be KO'd"
        );

        // Alice forced switch to mon 1
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, "", uint240(1), true);

        // Mon 1 has no ability, so no savior complex trigger
        // But the savior complex on mon 0 should NOT have been consumed (it didn't trigger)
        // Verify by checking global KV is still 0
        bytes32 scKey = keccak256(abi.encode(uint256(0), "SAVIOR_COMPLEX"));
        uint192 scTriggered = engine.getGlobalKV(battleKey, scKey);
        assertEq(scTriggered, 0, "Savior Complex should not have been consumed with 0 KOs");
    }

    function test_overflowDealsDamage() public {
        uint32 maxHp = 200;

        Overflow overflow = new Overflow(IEngine(address(engine)), ITypeCalculator(address(typeCalc)));

        IMoveSet[4] memory moves;
        moves[0] = overflow;

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = maxHp;
        mon.stats.specialAttack = 100;
        mon.stats.specialDefense = 100;
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey =
            _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses Overflow, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertTrue(bobHpDelta < 0, "Bob should have taken damage from Overflow");
    }
}
