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
import {IEngineHook} from "../../src/IEngineHook.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {IRuleset} from "../../src/IRuleset.sol";
import {DefaultRuleset} from "../../src/DefaultRuleset.sol";
import {SleepStatus} from "../../src/effects/status/SleepStatus.sol";
import {StaminaRegen} from "../../src/effects/StaminaRegen.sol";
import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {StandardAttack} from "../../src/moves/StandardAttack.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";
import {BattleHelper} from "../abstract/BattleHelper.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

// Xmon moves and abilities
import {ContagiousSlumber} from "../../src/mons/xmon/ContagiousSlumber.sol";
import {VitalSiphon} from "../../src/mons/xmon/VitalSiphon.sol";
import {Somniphobia} from "../../src/mons/xmon/Somniphobia.sol";
import {InvokeTaboo} from "../../src/mons/xmon/InvokeTaboo.sol";
import {Dreamcatcher} from "../../src/mons/xmon/Dreamcatcher.sol";
import {NightTerrors} from "../../src/mons/xmon/NightTerrors.sol";

/**
    - Contagious Slumber adds Sleep effect to both mons [x]
    - Vital Siphon drains stamina only when opponent has at least 1 stamina [x]
    - Somniphobia damages a mon on any stamina gain (round-end regen + resting) [x]
    - Somniphobia does NOT damage a resting mon that gains no stamina (already full) [x]
    - Dreamcatcher heals on stamina gain (external StaminaRegen path) [x]
    - Dreamcatcher heals on inline stamina regen (INLINE_STAMINA_REGEN_RULESET) [x]
    - Invoke Taboo brands the opponent's move; repeating it puts them to sleep [x]
    - Invoke Taboo brand clears when the opponent switches out [x]
    - Night Terrors doesn't trigger when terror stacks > available stamina [ ]
    - Night Terrors effect clears on swap [ ]
    - Night Terrors damage differs when opponent is asleep vs awake [ ]
 */

contract XmonTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;
    StandardAttackFactory attackFactory;

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine(0, 0);
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        matchmaker = new DefaultMatchmaker(engine);
        attackFactory = new StandardAttackFactory(ITypeCalculator(address(typeCalc)));
    }

    function test_contagiousSlumberAppliesSleepToBothMons() public {
        SleepStatus sleepStatus = new SleepStatus();
        ContagiousSlumber contagiousSlumber = new ContagiousSlumber(IEffect(address(sleepStatus)));

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(contagiousSlumber)));

        Mon memory mon = _createMon();
        mon.moves = moves;
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice uses Contagious Slumber, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify that both Alice and Bob have Sleep status
        (EffectInstance[] memory aliceEffects, ) = engine.getEffects(battleKey, 0, 0);
        (EffectInstance[] memory bobEffects, ) = engine.getEffects(battleKey, 1, 0);

        bool aliceHasSleep = false;
        bool bobHasSleep = false;

        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (address(aliceEffects[i].effect) == address(sleepStatus)) {
                aliceHasSleep = true;
                break;
            }
        }

        for (uint256 i = 0; i < bobEffects.length; i++) {
            if (address(bobEffects[i].effect) == address(sleepStatus)) {
                bobHasSleep = true;
                break;
            }
        }

        assertTrue(aliceHasSleep, "Alice should have Sleep status");
        assertTrue(bobHasSleep, "Bob should have Sleep status");
    }

    function test_vitalSiphonDrainsStaminaOnlyWhenOpponentHasStamina() public {
        VitalSiphon vitalSiphon = new VitalSiphon(ITypeCalculator(address(typeCalc)));

        // Create a stamina-draining attack to reduce Bob's stamina to 0
        StandardAttack nullMove = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 4,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Stamina Drain",
                EFFECT: IEffect(address(0))
            })
        );

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(vitalSiphon)));
        moves[1] = uint256(uint160(address(nullMove)));

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = vitalSiphon.basePower("") * 4;
        mon.stats.stamina = 5; // Enough stamina for multiple moves
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Set RNG to guarantee stamina steal (>= 50)
        mockOracle.setRNG(50);

        // Alice uses Vital Siphon, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify that Bob's stamina was drained by 1 and Alice gained 1
        int32 bobStaminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        int32 aliceStaminaDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);

        // Alice spent 2 stamina for the move, gained 1 back = -1
        // Bob gained 1 from rest, lost 1 from drain = 0
        assertEq(aliceStaminaDelta, 1 - int32(vitalSiphon.stamina(IEngine(address(0)), 0, 0, 0)), "Alice should have -1 stamina delta (spent 2, gained 1)");
        assertEq(bobStaminaDelta, -1, "Bob should have -1 stamina delta from the drain");

        // Alice does nothing, Bob uses null move, no more stamina
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 1, 0, 0);

        // Check that Bob has stamina delta of -5
        bobStaminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        assertEq(bobStaminaDelta, -5, "Bob should have -5 stamina delta");

        // Alice does stamina drain, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Bob has 0 stamina, so no change so Alice doesn't get the drain
        bobStaminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        aliceStaminaDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        assertEq(bobStaminaDelta, -5, "Bob should still have -5 stamina delta");
        assertEq(aliceStaminaDelta, 1 - 2 * int32(vitalSiphon.stamina(IEngine(address(0)), 0, 0, 0)), "Alice should have -3 stamina delta (after using the move)");
    }

    // Stamina-burn filler: costs stamina, deals no damage, so a mon can drop below full and regen.
    function _staminaBurn(uint32 cost) internal returns (StandardAttack) {
        return attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: cost,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Stamina Burn",
                EFFECT: IEffect(address(0))
            })
        );
    }

    // Somniphobia triggers on any stamina gain (not just resting): the round-end regen tick deals
    // damage, while a mon resting at full stamina gains nothing and is untouched.
    function test_somniphobiaDamagesOnAnyStaminaGain() public {
        Somniphobia somniphobia = new Somniphobia();
        StaminaRegen staminaRegen = new StaminaRegen();

        uint32 maxHp = uint32(somniphobia.DAMAGE_DENOM()) * 50; // 400 HP -> 50 damage per tick at 1 stack
        int32 tick = -int32(maxHp) / somniphobia.DAMAGE_DENOM(); // -50

        StandardAttack staminaBurn = _staminaBurn(2);

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(somniphobia)));
        moves[1] = uint256(uint160(address(staminaBurn)));

        // Alice is faster so move order is deterministic.
        Mon memory aliceMon = _createMon();
        aliceMon.moves = moves;
        aliceMon.stats.hp = maxHp;
        aliceMon.stats.stamina = 5;
        aliceMon.stats.speed = 2;

        Mon memory bobMon = _createMon();
        bobMon.moves = moves;
        bobMon.stats.hp = maxHp;
        bobMon.stats.stamina = 5;
        bobMon.stats.speed = 1;

        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        // Battle with the StaminaRegen global effect so resting / round-end actually regen stamina.
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        DefaultRuleset ruleset = new DefaultRuleset(IEngine(address(engine)), effects);

        bytes32 battleKey = _startBattle(
            validator, engine, mockOracle, defaultRegistry, matchmaker, new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager)
        );

        // Both players select their first mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Turn 1: Alice casts Somniphobia, Bob burns 2 stamina. Neither rests. At round-end
        // StaminaRegen tops each mon back up by 1, and that gain triggers Somniphobia on both.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 1, 0, 0);

        // The global coordinator exists and both active mons carry the per-mon effect.
        (bool coordinatorExists,,) = engine.getEffectData(battleKey, 2, 2, address(somniphobia));
        (bool aliceHas,,) = engine.getEffectData(battleKey, 0, 0, address(somniphobia));
        (bool bobHas,,) = engine.getEffectData(battleKey, 1, 0, address(somniphobia));
        assertTrue(coordinatorExists, "Somniphobia coordinator should exist");
        assertTrue(aliceHas, "Alice should have Somniphobia effect");
        assertTrue(bobHas, "Bob should have Somniphobia effect");

        // Round-end regen (a non-rest stamina gain) dealt one tick to each.
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), tick, "Alice tick from round-end regen");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), tick, "Bob tick from round-end regen");
        // Alice regen'd from -1 -> 0; Bob from -2 -> -1.
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), 0, "Alice stamina back to full");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), -1, "Bob stamina still -1");

        // Turn 2: both rest. Alice is already at full stamina -> no gain -> NO damage.
        // Bob is at -1 -> resting regens +1 -> gain -> one more tick.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp),
            tick,
            "Alice took NO new damage: resting at full stamina is not a gain"
        );
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp),
            tick * 2,
            "Bob took another tick: resting regen'd stamina"
        );
    }

    // Re-casting Somniphobia raises the stack, scaling the per-gain damage (1/8 max HP per stack).
    function test_somniphobiaStacks() public {
        Somniphobia somniphobia = new Somniphobia();
        StaminaRegen staminaRegen = new StaminaRegen();

        uint32 maxHp = uint32(somniphobia.DAMAGE_DENOM()) * 100; // 800 HP -> 100 per stack
        int32 stack1 = -int32(maxHp) / somniphobia.DAMAGE_DENOM(); // -100

        StandardAttack staminaBurn = _staminaBurn(2);
        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(somniphobia)));
        moves[1] = uint256(uint160(address(staminaBurn)));

        Mon memory aliceMon = _createMon();
        aliceMon.moves = moves;
        aliceMon.stats.hp = maxHp;
        aliceMon.stats.stamina = 5;
        aliceMon.stats.speed = 2;

        Mon memory bobMon = _createMon();
        bobMon.moves = moves;
        bobMon.stats.hp = maxHp;
        bobMon.stats.stamina = 5;
        bobMon.stats.speed = 1;

        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        DefaultRuleset ruleset = new DefaultRuleset(IEngine(address(engine)), effects);
        bytes32 battleKey = _startBattle(
            validator, engine, mockOracle, defaultRegistry, matchmaker, new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager)
        );

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Turn 1: Alice casts Somniphobia (stack 1), Bob burns stamina. Round-end regen deals 1 stack.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 1, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), stack1, "Alice 1-stack tick");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), stack1, "Bob 1-stack tick");

        // Turn 2: Alice casts again (stack 2), Bob burns stamina. Round-end regen now deals 2 stacks.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 1, 0, 0);

        (,, bytes32 data) = engine.getEffectData(battleKey, 2, 2, address(somniphobia));
        assertEq((uint256(data) >> 8) & 0xFF, 2, "Coordinator should be at stack 2");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), stack1 * 3, "Alice: 1 stack + 2 stacks");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), stack1 * 3, "Bob: 1 stack + 2 stacks");
    }

    // A mon switched in while Somniphobia is active picks up the effect; the one switched out loses it.
    function test_somniphobiaFollowsSwitchIns() public {
        Somniphobia somniphobia = new Somniphobia();
        StaminaRegen staminaRegen = new StaminaRegen();

        uint32 maxHp = uint32(somniphobia.DAMAGE_DENOM()) * 100; // 800 HP -> 100 per stack
        int32 stack1 = -int32(maxHp) / somniphobia.DAMAGE_DENOM(); // -100

        StandardAttack staminaBurn = _staminaBurn(2);
        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(somniphobia)));
        moves[1] = uint256(uint160(address(staminaBurn)));

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = maxHp;
        mon.stats.stamina = 5;
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        DefaultRuleset ruleset = new DefaultRuleset(IEngine(address(engine)), effects);
        bytes32 battleKey = _startBattle(
            validator, engine, mockOracle, defaultRegistry, matchmaker, new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager)
        );

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Turn 1: Alice casts Somniphobia, Bob burns stamina -> Bob's mon 0 picks up the effect.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 1, 0, 0);
        (bool bob0Has,,) = engine.getEffectData(battleKey, 1, 0, address(somniphobia));
        assertTrue(bob0Has, "Bob mon 0 should have the effect");

        // Turn 2: Bob switches to mon 1. Mon 0 loses the effect; mon 1 gains it on switch-in.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, uint16(1));
        (bool bob0Still,,) = engine.getEffectData(battleKey, 1, 0, address(somniphobia));
        (bool bob1Has,,) = engine.getEffectData(battleKey, 1, 1, address(somniphobia));
        (bool coordinatorAlive,,) = engine.getEffectData(battleKey, 2, 2, address(somniphobia));
        assertFalse(bob0Still, "Switched-out mon 0 should lose the effect");
        assertTrue(bob1Has, "Switched-in mon 1 should pick up the effect");
        assertTrue(coordinatorAlive, "Coordinator persists across switches");

        // Turn 3: Bob's mon 1 burns stamina; the round-end regen gain damages it, proving coverage.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 1, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp), stack1, "Switched-in mon takes a tick");
    }

    // The effect (coordinator + per-mon copies) is gone after DURATION turns.
    function test_somniphobiaExpiresAfterDuration() public {
        Somniphobia somniphobia = new Somniphobia();

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(somniphobia)));
        moves[1] = uint256(uint160(address(_staminaBurn(2))));

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = 1000;
        mon.stats.stamina = 10;
        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Turn 1 casts it (DURATION = 4). It then counts down one per round end.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        // Turns 2-3: still active.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);
        (bool aliveAtTurn3,,) = engine.getEffectData(battleKey, 2, 2, address(somniphobia));
        assertTrue(aliveAtTurn3, "Coordinator still active before duration elapses");

        // Turn 4: the 4th round end expires it; the per-mon copy self-clears the same round.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);
        (bool coordinatorGone,,) = engine.getEffectData(battleKey, 2, 2, address(somniphobia));
        (bool punisherGone,,) = engine.getEffectData(battleKey, 0, 0, address(somniphobia));
        assertFalse(coordinatorGone, "Coordinator should expire after DURATION turns");
        assertFalse(punisherGone, "Per-mon copy should clear once the coordinator is gone");
    }

    /// @notice Invoke Taboo (-1 priority) reads the move the opponent used this turn and brands it.
    ///         If the opponent uses that same move again before switching out, they fall asleep.
    function test_invokeTabooSleepsOnRepeatedMove() public {
        SleepStatus sleepStatus = new SleepStatus();
        InvokeTaboo invokeTaboo = new InvokeTaboo(IEffect(address(sleepStatus)));

        // A cheap, low-power attack that Bob will repeat.
        StandardAttack jab = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 10,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Jab",
                EFFECT: IEffect(address(0))
            })
        );

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(invokeTaboo)));
        moves[1] = uint256(uint160(address(jab)));

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = 1000; // high HP so jabs never KO
        mon.stats.stamina = 10;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Turn 1: Alice uses Invoke Taboo (priority 2), Bob jabs (priority 3 -> moves first).
        // Invoke Taboo resolves after Bob and brands Bob's jab (slot 1).
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 1, 0, 0);

        (bool bobBranded,, bytes32 brandData) = engine.getEffectData(battleKey, 1, 0, address(invokeTaboo));
        assertTrue(bobBranded, "Bob should be branded with the Invoke Taboo effect");
        // Regular move slots are stored +1 in the packed move index (slot 1 -> 2). The brand records
        // that same packed form, and the trigger compares against it, so both stay consistent.
        assertEq(uint256(brandData), 1 + uint256(MOVE_INDEX_OFFSET), "Branded move should be Bob's jab (slot 1)");

        // Bob is not asleep yet (the branding turn does not trigger).
        (bool asleepAfterBrand,,) = engine.getEffectData(battleKey, 1, 0, address(sleepStatus));
        assertFalse(asleepAfterBrand, "Bob should not be asleep on the branding turn");

        // Turn 2: Bob repeats the tabooed jab. Alice rests. After Bob's move, the taboo triggers sleep.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 1, 0, 0);

        (bool asleepAfterRepeat,,) = engine.getEffectData(battleKey, 1, 0, address(sleepStatus));
        assertTrue(asleepAfterRepeat, "Bob should fall asleep after repeating the tabooed move");
    }

    /// @notice The Invoke Taboo brand is scoped to the branded mon and is cleared when it switches out.
    function test_invokeTabooClearsOnSwitchOut() public {
        SleepStatus sleepStatus = new SleepStatus();
        InvokeTaboo invokeTaboo = new InvokeTaboo(IEffect(address(sleepStatus)));

        StandardAttack jab = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 10,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Jab",
                EFFECT: IEffect(address(0))
            })
        );

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(invokeTaboo)));
        moves[1] = uint256(uint160(address(jab)));

        // Both sides field two mons (Bob needs a second mon to switch into).
        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = 1000;
        mon.stats.stamina = 10;
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        // One validator governs both sides; size it for the larger (2-mon) team.
        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Alice sends mon 0, Bob sends mon 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Turn 1: Alice uses Invoke Taboo, Bob jabs -> Bob mon 0 branded with slot 1.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 1, 0, 0);

        (bool branded,,) = engine.getEffectData(battleKey, 1, 0, address(invokeTaboo));
        assertTrue(branded, "Bob mon 0 should be branded before switching out");

        // Turn 2: Bob switches to mon 1, clearing the brand on mon 0. Alice rests.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, uint16(1));

        (bool stillBranded,,) = engine.getEffectData(battleKey, 1, 0, address(invokeTaboo));
        assertFalse(stillBranded, "Brand should be cleared after the branded mon switches out");
    }

    function test_dreamcatcherHealsOnStaminaGain() public {
        Dreamcatcher dreamcatcher = new Dreamcatcher();
        StaminaRegen staminaRegen = new StaminaRegen();

        uint32 BASE_HP = 10;
        uint32 maxHp = uint32(dreamcatcher.HEAL_DENOM()) * BASE_HP; // 160 HP

        // Create an attack that deals damage
        StandardAttack attack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 3 * BASE_HP,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Attack",
                EFFECT: IEffect(address(0))
            })
        );

        // Create a move that costs 3 stamina and does nothing
        StandardAttack staminaBurn = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 3,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Stamina Burn",
                EFFECT: IEffect(address(0))
            })
        );

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(attack)));
        moves[1] = uint256(uint160(address(staminaBurn)));

        Mon memory fastMon = _createMon();
        fastMon.moves = moves;
        fastMon.ability = uint160(address(dreamcatcher));
        fastMon.stats.hp = maxHp;
        fastMon.stats.stamina = 10;
        fastMon.stats.speed = 2;

        Mon memory slowMon = _createMon();
        slowMon.moves = moves;
        slowMon.ability = uint160(address(dreamcatcher));
        slowMon.stats.hp = maxHp;
        slowMon.stats.stamina = 10;
        slowMon.stats.speed = 1;

        Mon[] memory team = new Mon[](2);
        team[0] = fastMon;
        team[1] = slowMon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: team.length, MOVES_PER_MON: moves.length, TIMEOUT_DURATION: 10})
        );

        // Create ruleset with StaminaRegen
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        DefaultRuleset ruleset = new DefaultRuleset(IEngine(address(engine)), effects);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager));

        // Alice sends in fast mon, Bob sends in slow mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(1)
        );

        // Verify that Alice has the Dreamcatcher effect
        (EffectInstance[] memory aliceEffects, ) = engine.getEffects(battleKey, 0, 0);
        bool hasDreamcatcher = false;
        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (address(aliceEffects[i].effect) == address(dreamcatcher)) {
                hasDreamcatcher = true;
                break;
            }
        }
        assertTrue(hasDreamcatcher, "Alice should have Dreamcatcher effect");

        // Turn 1: Alice uses stamina burn (loses 3 stamina), Bob attacks Alice
        // At end of turn: Alice regains 1 stamina (from StaminaRegen), heals by 10 (from Dreamcatcher)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 0, 0, 0);

        int32 aliceHpAfterTurn1 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(aliceHpAfterTurn1, -20);

        // Turn 2: Both players rest (NO_OP)
        // Alice heals from resting, then heals again at end of turn from stamina regen
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Alice is back to full HP
        int32 aliceHpAfterTurn2 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(aliceHpAfterTurn2, 0, "Alice should be back to full HP");
    }

    /// @notice Regression for a desync where Dreamcatcher silently no-op'd under the
    /// inline stamina-regen ruleset. The inline path used to mutate `monState.staminaDelta`
    /// directly in StaminaRegenLogic, skipping `engine.updateMonState` and so never firing
    /// the OnUpdateMonState fan-out that Dreamcatcher subscribes to. Same setup as
    /// `test_dreamcatcherHealsOnStaminaGain` but driven by `INLINE_STAMINA_REGEN_RULESET`
    /// instead of a DefaultRuleset-wired StaminaRegen effect.
    function test_dreamcatcherHealsOnInlineStaminaRegen() public {
        Dreamcatcher dreamcatcher = new Dreamcatcher();

        uint32 BASE_HP = 10;
        uint32 maxHp = uint32(dreamcatcher.HEAL_DENOM()) * BASE_HP; // 160 HP

        StandardAttack attack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 3 * BASE_HP,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Attack",
                EFFECT: IEffect(address(0))
            })
        );

        StandardAttack staminaBurn = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 3,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Stamina Burn",
                EFFECT: IEffect(address(0))
            })
        );

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(attack)));
        moves[1] = uint256(uint160(address(staminaBurn)));

        Mon memory fastMon = _createMon();
        fastMon.moves = moves;
        fastMon.ability = uint160(address(dreamcatcher));
        fastMon.stats.hp = maxHp;
        fastMon.stats.stamina = 10;
        fastMon.stats.speed = 2;

        Mon memory slowMon = _createMon();
        slowMon.moves = moves;
        slowMon.ability = uint160(address(dreamcatcher));
        slowMon.stats.hp = maxHp;
        slowMon.stats.stamina = 10;
        slowMon.stats.speed = 1;

        Mon[] memory team = new Mon[](2);
        team[0] = fastMon;
        team[1] = slowMon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: team.length, MOVES_PER_MON: moves.length, TIMEOUT_DURATION: 10})
        );

        // Use the sentinel address that flips Engine into `hasInlineStaminaRegen` mode.
        bytes32 battleKey = _startBattle(
            validator,
            engine,
            mockOracle,
            defaultRegistry,
            matchmaker,
            new IEngineHook[](0),
            IRuleset(INLINE_STAMINA_REGEN_RULESET),
            address(commitManager)
        );

        // Alice sends in fast mon, Bob sends in slow mon
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(1)
        );

        // Sanity: Alice has Dreamcatcher registered via activateOnSwitch
        (EffectInstance[] memory aliceEffects,) = engine.getEffects(battleKey, 0, 0);
        bool hasDreamcatcher = false;
        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (address(aliceEffects[i].effect) == address(dreamcatcher)) {
                hasDreamcatcher = true;
                break;
            }
        }
        assertTrue(hasDreamcatcher, "Alice should have Dreamcatcher effect");

        // Turn 1: Alice burns 3 stamina, Bob attacks Alice for 30 damage.
        // Alice ends turn at -3 stamina, +1 regen from inline-after-move = -2.
        // Dreamcatcher heals 10 HP, leaving Alice at -20.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 0, 0, 0);
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp),
            -20,
            "Alice should be at -20 HP after turn 1 (one inline-regen heal)"
        );

        // Turn 2: Both rest (NO_OP). Alice gets two regen ticks (post-move + round-end),
        // each one firing OnUpdateMonState. Dreamcatcher heals 10 HP per tick → back to full.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp),
            0,
            "Alice should be back to full HP after inline regen heals fire"
        );
    }

    function test_nightTerrorsDoesNotTriggerWhenStaminaTooLow() public {
        /**
         * Test that Night Terrors doesn't trigger damage when terror stacks > available stamina.
         *
         * Setup: Alice has 5 stamina
         * Turn 1: Alice uses Night Terrors (1 stack on Alice), Alice loses 1 stamina at end of turn (5 -> 4)
         * Turn 2: Alice uses Night Terrors (2 stacks on Alice), Alice loses 2 stamina at end of turn (4 -> 2)
         * Turn 3: Alice uses Night Terrors (3 stacks on Alice), Alice has only 2 stamina, so no trigger
         */
        SleepStatus sleepStatus = new SleepStatus();
        NightTerrors nightTerrors = new NightTerrors(ITypeCalculator(address(typeCalc)), IEffect(address(sleepStatus)));

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(nightTerrors)));

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.stamina = 5;
        mon.stats.hp = 1000; // High HP to avoid KO
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
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Turn 1: Alice uses Night Terrors, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Alice has 1 stack and lost 1 stamina (5 -> 4), Bob took damage
        int32 aliceStaminaAfterTurn1 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        int32 bobHpAfterTurn1 = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(aliceStaminaAfterTurn1, -1, "Alice should have -1 stamina delta after turn 1");
        assertTrue(bobHpAfterTurn1 < 0, "Bob should have taken damage");

        // Turn 2: Alice uses Night Terrors again, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Alice has 2 stacks and lost 2 more stamina (4 -> 2), Bob took more damage
        int32 aliceStaminaAfterTurn2 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        int32 bobHpAfterTurn2 = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(aliceStaminaAfterTurn2, -3, "Alice should have -3 stamina delta after turn 2");
        assertTrue(bobHpAfterTurn2 < bobHpAfterTurn1, "Bob should have taken more damage");

        // Turn 3: Alice uses Night Terrors again, Bob does nothing
        // Alice has 2 stamina but 3 stacks, so no trigger
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Alice's stamina didn't change (still at 2) and Bob's HP didn't change
        int32 aliceStaminaAfterTurn3 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        int32 bobHpAfterTurn3 = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(aliceStaminaAfterTurn3, -3, "Alice should still have -3 stamina delta (no trigger)");
        assertEq(bobHpAfterTurn3, bobHpAfterTurn2, "Bob's HP should not have changed (no damage dealt)");
    }

    function test_nightTerrorsClearsOnSwap() public {
        /**
         * Test that Night Terrors effect clears when the mon switches out.
         *
         * Setup: Both players have 2-mon teams
         * Turn 1: Alice uses Night Terrors (effect on Alice's mon 0)
         * Turn 2: Alice swaps to mon 1
         * Verify: Alice's mon 0 no longer has Night Terrors effect
         */
        SleepStatus sleepStatus = new SleepStatus();
        NightTerrors nightTerrors = new NightTerrors(ITypeCalculator(address(typeCalc)), IEffect(address(sleepStatus)));

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(nightTerrors)));

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = 1000;
        mon.stats.stamina = 10;

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
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Turn 1: Alice uses Night Terrors, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Alice's mon 0 has Night Terrors effect
        (EffectInstance[] memory aliceEffectsBeforeSwap, ) = engine.getEffects(battleKey, 0, 0);
        bool hasNightTerrorsBeforeSwap = false;
        for (uint256 i = 0; i < aliceEffectsBeforeSwap.length; i++) {
            if (address(aliceEffectsBeforeSwap[i].effect) == address(nightTerrors)) {
                hasNightTerrorsBeforeSwap = true;
                break;
            }
        }
        assertTrue(hasNightTerrorsBeforeSwap, "Alice's mon 0 should have Night Terrors effect before swap");

        // Turn 2: Alice swaps to mon 1, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(1), 0);

        // Verify Alice's mon 0 no longer has Night Terrors effect
        (EffectInstance[] memory aliceEffectsAfterSwap, ) = engine.getEffects(battleKey, 0, 0);
        bool hasNightTerrorsAfterSwap = false;
        for (uint256 i = 0; i < aliceEffectsAfterSwap.length; i++) {
            if (address(aliceEffectsAfterSwap[i].effect) == address(nightTerrors)) {
                hasNightTerrorsAfterSwap = true;
                break;
            }
        }
        assertFalse(hasNightTerrorsAfterSwap, "Alice's mon 0 should not have Night Terrors effect after swap");
    }

    function test_nightTerrorsDamageIncreasesWhenAsleep() public {
        /**
         * Test that Night Terrors deals more damage when the opponent is asleep.
         *
         * Setup: Create a sleep-inflicting move
         * Turn 1: Alice uses Night Terrors (effect on Alice), damages Bob (awake)
         * Turn 2: Alice swaps out to clear Night Terrors
         * Turn 3: Alice swaps back in
         * Turn 4: Alice uses Sleep move on Bob
         * Turn 5: Alice uses Night Terrors, damages sleeping Bob
         * Verify: Asleep damage is at least 50% more than awake damage (30/20 = 1.5)
         */
        SleepStatus sleepStatus = new SleepStatus();
        NightTerrors nightTerrors = new NightTerrors(ITypeCalculator(address(typeCalc)), IEffect(address(sleepStatus)));

        // Create a sleep-inflicting move with zero cost and zero damage
        StandardAttack sleepMove = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Sleep Move",
                EFFECT: IEffect(address(sleepStatus))
            })
        );

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(nightTerrors)));
        moves[1] = uint256(uint160(address(sleepMove)));

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = 1000;
        mon.stats.stamina = 20;

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
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Precomputed seed: Bob stays asleep through turn 5 + no crit/volatility so the awake/asleep
        // damage ratio is clean.
        mockOracle.setRNG(28);

        // Turn 1: Alice uses Night Terrors, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Check damage dealt to Bob (should be BASE_DAMAGE_PER_STACK = 20)
        int32 bobHpAfterAwakeDamage = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int32 awakeDamage = -bobHpAfterAwakeDamage;

        // Turn 2: Alice swaps out to mon 1 to clear Night Terrors, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(1), 0);

        // Turn 3: Alice swaps back to mon 0, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(0), 0);

        // Turn 4: Alice uses Sleep move on Bob, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, 0, 0);

        // Verify Bob is asleep
        (EffectInstance[] memory bobEffects, ) = engine.getEffects(battleKey, 1, 0);
        bool bobIsAsleep = false;
        for (uint256 i = 0; i < bobEffects.length; i++) {
            if (address(bobEffects[i].effect) == address(sleepStatus)) {
                bobIsAsleep = true;
                break;
            }
        }
        assertTrue(bobIsAsleep, "Bob should be asleep");

        // Get Bob's HP before asleep damage
        int32 bobHpBeforeAsleepDamage = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        // Turn 5: Alice uses Night Terrors on sleeping Bob, Bob does nothing (forced by sleep)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Check damage dealt to Bob (should be ASLEEP_DAMAGE_PER_STACK = 30)
        int32 bobHpAfterAsleepDamage = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int32 asleepDamage = bobHpBeforeAsleepDamage - bobHpAfterAsleepDamage;

        // Verify asleep damage is at least 50% more than awake damage (30/20 = 1.5)
        assertTrue(asleepDamage * 100 >= awakeDamage * 150, "Asleep damage should be at least 50% more than awake damage");
    }
}
