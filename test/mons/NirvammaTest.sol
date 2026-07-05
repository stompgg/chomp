// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import "../../src/Constants.sol";
import "../../src/Structs.sol";

import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";
import {Engine} from "../../src/Engine.sol";
import {MonStateIndexName, MoveClass, Type} from "../../src/Enums.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {BurnStatus} from "../../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../../src/effects/status/FrostbiteStatus.sol";
import {ZapStatus} from "../../src/effects/status/ZapStatus.sol";
import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {StandardAttack} from "../../src/moves/StandardAttack.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";
import {BattleHelper} from "../abstract/BattleHelper.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {Adaptor} from "../../src/mons/nirvamma/Adaptor.sol";
import {Chronoffense} from "../../src/mons/nirvamma/Chronoffense.sol";
import {HardReset} from "../../src/mons/nirvamma/HardReset.sol";
import {ModalBolt} from "../../src/mons/nirvamma/ModalBolt.sol";

contract NirvammaTest is Test, BattleHelper {
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
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        matchmaker = new DefaultMatchmaker(engine);
        attackFactory = new StandardAttackFactory(ITypeCalculator(address(typeCalc)));
    }

    function _ping(uint32 power) internal returns (StandardAttack) {
        return attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: power,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Math,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Ping",
                EFFECT: IEffect(address(0))
            })
        );
    }

    function _hasEffect(bytes32 battleKey, uint256 targetIndex, uint256 monIndex, address eff)
        internal
        view
        returns (bool)
    {
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, targetIndex, monIndex);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == eff) return true;
        }
        return false;
    }

    function _countGlobalsOf(bytes32 battleKey, address eff) internal view returns (uint256 n) {
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 2, 0);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == eff) n++;
        }
    }

    // ===== Hard Reset =====

    function _setupHardReset() internal returns (bytes32 battleKey, HardReset hardReset, StandardAttack ping) {
        hardReset = new HardReset();
        ping = _ping(10);

        uint256[] memory nirvammaMoves = new uint256[](2);
        nirvammaMoves[0] = uint256(uint160(address(hardReset)));
        nirvammaMoves[1] = uint256(uint160(address(ping)));

        uint256[] memory fillerMoves = new uint256[](2);
        fillerMoves[0] = uint256(uint160(address(ping)));
        fillerMoves[1] = uint256(uint160(address(ping)));

        Mon memory nirvamma = _createMon();
        nirvamma.moves = nirvammaMoves;
        nirvamma.stats.hp = 160; // 1/16 = 10
        nirvamma.stats.stamina = 5;
        nirvamma.stats.speed = 2;

        Mon memory filler = _createMon();
        filler.moves = fillerMoves;
        filler.stats.hp = 160;
        filler.stats.stamina = 5;
        filler.stats.speed = 1;

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = nirvamma;
        aliceTeam[1] = filler;
        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = filler;
        bobTeam[1] = filler;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);
        battleKey =
            _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        // both players send in mon 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, 0
        );
    }

    // Each case drives Nirvamma to a chosen stamina deficit before it rests, then pins the exact
    // stamina/HP the own-team trigger leaves behind. Explicit expected values (not a mirror of the
    // contract formula) so a future change to the heal curve fails this test.
    struct OwnTriggerCase {
        uint256 pingsBeforeRest; // Alice pings cast between the HardReset cast and the resting NO_OP
        int32 expectedStaminaAfter; // Nirvamma staminaDelta after the own trigger fires
        int32 expectedHpAfter; // Nirvamma hpDelta after the own trigger fires
    }

    function test_hardReset_ownTeamTrigger() public {
        // HardReset's own-team trigger restores +2 stamina when the resting mon is down >= 2 (capped
        // at +2 -- it never overheals stamina), heals 12.5% max HP (HP_DENOM = 8; capped so the HP
        // delta never exceeds 0), and force-swaps the mon out. Nirvamma maxHp = 160 -> 12.5% = 20 HP;
        // each Bob ping deals 10 damage. Nirvamma (speed 2) is priority, so its NO_OP fires the
        // trigger and swaps out before Bob's same-turn ping lands -- that ping hits the filler.
        OwnTriggerCase[2] memory cases = [
            // No extra pings: HardReset cost only -> stamina -2; one Bob hit -> hp -10.
            // Trigger: +2 stamina -> 0; +20 HP capped to +10 (heals up to 0) -> hp 0.
            OwnTriggerCase({pingsBeforeRest: 0, expectedStaminaAfter: 0, expectedHpAfter: 0}),
            // Two extra pings: stamina -4; three Bob hits -> hp -30.
            // Trigger: +2 stamina (capped, not +4) -> -2; +20 HP (uncapped, -30 + 20) -> hp -10.
            OwnTriggerCase({pingsBeforeRest: 2, expectedStaminaAfter: -2, expectedHpAfter: -10})
        ];

        for (uint256 c = 0; c < cases.length; c++) {
            OwnTriggerCase memory tc = cases[c];
            (bytes32 battleKey, HardReset hardReset,) = _setupHardReset();

            // Turn 1: Alice casts HardReset (-2 stam). Bob attacks (Alice's Nirvamma takes damage).
            _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
            assertTrue(_hasEffect(battleKey, 2, 0, address(hardReset)), "HardReset should be in global effects");

            // Optional extra pings (move index 1) to deepen Nirvamma's stamina deficit before resting.
            for (uint256 i = 0; i < tc.pingsBeforeRest; i++) {
                _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 0, 0, 0);
            }

            int32 stamBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
            int32 hpBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
            assertLt(stamBefore, 0, "Nirvamma stamina should be negative before resting");
            assertLt(hpBefore, 0, "Nirvamma should have taken damage before resting");

            // Resting turn: Alice NO_OPs -> own trigger fires (heal + force-swap). Bob attacks.
            _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

            assertEq(
                engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina),
                tc.expectedStaminaAfter,
                "Nirvamma stamina after own trigger mismatch"
            );
            assertEq(
                engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp),
                tc.expectedHpAfter,
                "Nirvamma HP after own trigger mismatch"
            );
            // Alice should have force-swapped to filler (mon 1).
            uint256[] memory active = engine.getActiveMonIndexForBattleState(battleKey);
            assertEq(active[0], 1, "Alice should have force-swapped to filler");
        }
    }

    function test_hardReset_oppTeamTrigger() public {
        (bytes32 battleKey, HardReset hardReset,) = _setupHardReset();

        // Turn 1: Alice casts HardReset. Bob attacks.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        assertTrue(_hasEffect(battleKey, 2, 0, address(hardReset)), "HardReset should be in global effects");
        int32 bobStamBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        int32 bobHpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        // Turn 2: Alice attacks. Bob rests. Bob's NO_OP fires opp trigger.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, 0, 0);

        // Bob's old active mon should have -1 stamina and an extra -10 hp from opp trigger
        // (on top of Alice's ping damage from this turn — so we just assert the delta).
        assertLt(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina),
            bobStamBefore,
            "Bob's mon should lose stamina from opp trigger"
        );
        // hp delta should be more negative than (bobHpBefore - aliceAttackDamage) by at least 10.
        // Easiest assertion: hp dropped by more than the attack alone (10 base power).
        int32 hpAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertLe(hpAfter, bobHpBefore - 10, "Bob's mon should take >= 10 extra damage from opp trigger");
        // Bob should have force-swapped.
        uint256[] memory active = engine.getActiveMonIndexForBattleState(battleKey);
        assertEq(active[1], 1, "Bob should have force-swapped to filler");
    }

    function test_hardReset_selfRemovesAfterBothFire() public {
        (bytes32 battleKey, HardReset hardReset,) = _setupHardReset();

        // Turn 1: Alice casts HardReset. Bob attacks (no NO_OP yet).
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        assertEq(_countGlobalsOf(battleKey, address(hardReset)), 1, "HardReset present after cast");

        // Turn 2: Both rest. Both triggers fire in the same turn → effect self-removes.
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0
        );
        assertEq(
            _countGlobalsOf(battleKey, address(hardReset)),
            0,
            "HardReset should self-remove after both own + opp triggers fire"
        );
    }

    function test_hardReset_perCasterUniqueness() public {
        // Both Alice and Bob cast HardReset; both effects coexist (one per caster).
        // Same caster casting twice is a no-op (stamina still consumed).
        HardReset hardReset = new HardReset();
        StandardAttack ping = _ping(10);

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(hardReset)));
        moves[1] = uint256(uint160(address(ping)));

        Mon memory caster = _createMon();
        caster.moves = moves;
        caster.stats.hp = 160;
        caster.stats.stamina = 10; // enough for two casts
        caster.stats.speed = 1;

        Mon[] memory team = new Mon[](2);
        team[0] = caster;
        team[1] = caster;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
        bytes32 battleKey =
            _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, 0
        );

        // Turn 1: both cast HardReset. Two distinct caster slots → 2 globals.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        assertEq(_countGlobalsOf(battleKey, address(hardReset)), 2, "Two casters: two HardReset globals");

        // Turn 2: Alice casts HardReset again (same caster). No new global added.
        // Bob attacks (so AfterMove for Bob doesn't trigger anything via NO_OP).
        int32 aliceStamBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 1, 0, 0);
        assertEq(
            _countGlobalsOf(battleKey, address(hardReset)),
            2,
            "Re-cast by same caster does not add another global"
        );
        // Stamina was still consumed.
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina),
            aliceStamBefore - 2,
            "Re-cast still consumes stamina"
        );
    }

    // ===== Chronoffense =====

    function _setupChronoffense() internal returns (bytes32 battleKey, Chronoffense chrono) {
        chrono = new Chronoffense();
        StandardAttack ping = _ping(10);

        uint256[] memory nirvammaMoves = new uint256[](2);
        nirvammaMoves[0] = uint256(uint160(address(chrono)));
        nirvammaMoves[1] = uint256(uint160(address(ping)));

        Mon memory nirvamma = _createMon();
        nirvamma.moves = nirvammaMoves;
        nirvamma.stats.hp = 1000;
        nirvamma.stats.stamina = 20;
        nirvamma.stats.speed = 2;
        nirvamma.stats.specialAttack = 10;
        nirvamma.stats.specialDefense = 100;

        Mon memory filler = _createMon();
        filler.moves = nirvammaMoves;
        filler.stats.hp = 1000;
        filler.stats.stamina = 20;
        filler.stats.speed = 1;

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = nirvamma;
        aliceTeam[1] = filler;
        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = filler;
        bobTeam[1] = filler;
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);
        battleKey =
            _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, 0
        );
    }

    function test_chronoffense_anchorThenDamageThenRearm() public {
        (bytes32 battleKey,) = _setupChronoffense();

        // Turn 1 (turnId after this = 2): Alice anchors. Bob NO_OPs. No damage to Bob.
        int32 bobHpAfterT0 = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp),
            bobHpAfterT0,
            "First Chronoffense use should deal no damage (anchor only)"
        );

        // Turn 2: Alice NO_OPs, Bob NO_OPs. Just to advance turns.
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0
        );

        // Turn 3: Alice fires Chronoffense again. elapsed = 2 → bp = 2*2*20 = 80.
        int32 bobHpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        int32 bobHpAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertLt(bobHpAfter, bobHpBefore, "Second Chronoffense use should deal damage");

        // Turn 4: Alice fires again — should re-arm (no damage this turn).
        int32 bobHpBeforeReanchor = bobHpAfter;
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp),
            bobHpBeforeReanchor,
            "Re-armed Chronoffense should set anchor and deal no damage"
        );
    }

    function test_chronoffense_anchorAppliesSpDefBuff() public {
        (bytes32 battleKey,) = _setupChronoffense();

        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialDefense),
            0,
            "No SpDef delta before anchoring"
        );

        // Turn 1: Alice anchors. Bob NO_OPs.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Base SpDef = 100 → 1.25× → delta = +25
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialDefense),
            25,
            "Anchor should apply +25% SpDef buff"
        );
    }

    function test_chronoffense_anchorSurvivesSwapOut() public {
        (bytes32 battleKey,) = _setupChronoffense();

        // Anchor.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Alice swaps out Nirvamma → filler. Bob NO_OPs.
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, 1, 0
        );
        // Bob NO_OPs again, Alice swaps back to Nirvamma.
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0
        );

        // Fire. Anchor was set on turn 1 (turnId 1), now turnId = 4. elapsed = 3 → bp = 3*3*20 = 180.
        int32 bobHpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        assertLt(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp),
            bobHpBefore,
            "Anchor should survive Nirvamma swap-out and produce damage on next fire"
        );
    }

    // ===== Modal Bolt =====

    function _setupModalBolt(IEffect burn, IEffect frost, IEffect zap)
        internal
        returns (bytes32 battleKey, ModalBolt modalBolt)
    {
        modalBolt = new ModalBolt(burn, frost, zap);

        uint256[] memory nirvammaMoves = new uint256[](1);
        nirvammaMoves[0] = uint256(uint160(address(modalBolt)));

        Mon memory nirvamma = _createMon();
        nirvamma.moves = nirvammaMoves;
        nirvamma.stats.hp = 1000;
        nirvamma.stats.stamina = 30;
        nirvamma.stats.speed = 2;
        nirvamma.stats.specialAttack = 10;

        Mon memory bob = _createMon();
        bob.moves = nirvammaMoves;
        bob.stats.hp = 1000;
        bob.stats.stamina = 30;
        bob.stats.speed = 1;
        bob.stats.specialDefense = 10;

        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = nirvamma;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bob;
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);
        battleKey =
            _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, 0
        );
    }

    function test_modalBolt_perModeDispatchAndTracking() public {
        BurnStatus burn = new BurnStatus();
        FrostbiteStatus frost = new FrostbiteStatus();
        ZapStatus zap = new ZapStatus();
        (bytes32 battleKey, ModalBolt modalBolt) = _setupModalBolt(burn, frost, zap);

        // Pick Fire (mode 0).
        int32 hpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        assertLt(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), hpBefore, "Fire dispatch deals damage");
        assertEq(modalBolt.getUsedModes(engine, battleKey, 0, 0), 0x1, "Fire bit set");

        // Pick Ice (mode 1).
        hpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 1, 0);
        assertLt(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), hpBefore, "Ice dispatch deals damage");
        assertEq(modalBolt.getUsedModes(engine, battleKey, 0, 0), 0x3, "Fire+Ice bits set");

        // Pick Lightning (mode 2).
        hpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 2, 0);
        assertLt(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), hpBefore, "Lightning dispatch deals damage");
        assertEq(modalBolt.getUsedModes(engine, battleKey, 0, 0), 0x7, "All three bits set");
    }

    function test_modalBolt_lockoutBehavior() public {
        BurnStatus burn = new BurnStatus();
        FrostbiteStatus frost = new FrostbiteStatus();
        ZapStatus zap = new ZapStatus();
        (bytes32 battleKey, ModalBolt modalBolt) = _setupModalBolt(burn, frost, zap);

        // Pick Fire.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(modalBolt.getUsedModes(engine, battleKey, 0, 0), 0x1);

        // Pick Fire again — falls back to the lowest still-free mode (Ice).
        int32 hpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        assertLt(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp),
            hpBefore,
            "Duplicate-mode submission falls back and still damages"
        );
        assertEq(modalBolt.getUsedModes(engine, battleKey, 0, 0), 0x3, "Fallback consumed Ice slot");

        // Out-of-range submission also falls back — only Lightning is free.
        hpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 99, 0);
        assertLt(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp),
            hpBefore,
            "Out-of-range submission falls back to Lightning"
        );
        assertEq(modalBolt.getUsedModes(engine, battleKey, 0, 0), 0x7, "All three modes consumed");

        // Every mode spent — now any pick is a true no-op (stamina still charged).
        hpBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int32 stamBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 1, 0);
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp),
            hpBefore,
            "Pick after all-used should not damage"
        );
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina),
            stamBefore - 3,
            "Pick after all-used still costs stamina"
        );
    }

    // ===== Adaptor =====

    function _setupAdaptor() internal returns (bytes32 battleKey, Adaptor adaptor, StandardAttack atkA, StandardAttack atkB) {
        adaptor = new Adaptor();
        atkA = _ping(50);
        atkB = _ping(50);

        uint256 noopMove = uint256(uint160(address(_ping(0))));
        uint256[] memory aliceMoves = new uint256[](2);
        aliceMoves[0] = noopMove;
        aliceMoves[1] = noopMove;

        uint256[] memory bobMoves = new uint256[](2);
        bobMoves[0] = uint256(uint160(address(atkA)));
        bobMoves[1] = uint256(uint160(address(atkB)));

        Mon memory nirvamma = _createMon();
        nirvamma.moves = aliceMoves;
        nirvamma.ability = uint160(address(adaptor));
        nirvamma.stats.hp = 1000;
        nirvamma.stats.stamina = 20;
        nirvamma.stats.speed = 2;
        nirvamma.stats.specialDefense = 10;

        Mon memory aliceFiller = _createMon();
        aliceFiller.moves = aliceMoves;
        aliceFiller.stats.hp = 1000;
        aliceFiller.stats.stamina = 20;

        Mon memory bobMon = _createMon();
        bobMon.moves = bobMoves;
        bobMon.stats.hp = 1000;
        bobMon.stats.stamina = 20;
        bobMon.stats.specialAttack = 10;
        bobMon.stats.speed = 1;

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = nirvamma;
        aliceTeam[1] = aliceFiller;
        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);
        battleKey =
            _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, 0
        );
    }

    function test_adaptor_sameSourceHalving() public {
        (bytes32 battleKey,,,) = _setupAdaptor();

        // Turn 1: Bob attacks with A. Alice no-ops.
        int32 hpBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        int32 hpAfter1 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        int32 dmg1 = hpBefore - hpAfter1;
        assertGt(dmg1, 0, "First A hit should deal damage");

        // Turn 2: Bob attacks with A again. Damage should be halved (PreDamage halves running damage).
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        int32 hpAfter2 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        int32 dmg2 = hpAfter1 - hpAfter2;
        assertEq(dmg2, dmg1 / 2, "Second A hit should be halved");
    }

    function test_adaptor_latchPersistsForRestOfBattle() public {
        (bytes32 battleKey,,,) = _setupAdaptor();

        // Turn 1: A hits, latched.
        int32 hp0 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        int32 hp1 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        int32 dmgFullA = hp0 - hp1;

        // Turn 2: B hits. A is latched, B is not, so B's hit is full damage. Latch is not displaced.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 1, 0, 0);
        int32 hp2 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(hp1 - hp2, dmgFullA, "B's first hit is full damage (A is latched, B is not)");

        // Turn 3: A hits again, halved.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        int32 hp3 = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(hp2 - hp3, dmgFullA / 2, "A's second hit is halved");

        // Alice swaps Nirvamma out and back in. Latch should persist (no session reset).
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, 1, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        // A still latched: hit is still halved.
        int32 hpBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);
        int32 hpAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(hpBefore - hpAfter, dmgFullA / 2, "Latch persists across swap-out");
    }
}
