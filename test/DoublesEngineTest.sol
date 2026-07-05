// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IMatchmaker} from "../src/matchmaker/IMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";

import {IEngine} from "../src/IEngine.sol";

import {CustomAttack} from "./mocks/CustomAttack.sol";
import {OrderRecorderAbility} from "./mocks/OrderRecorderAbility.sol";
import {StatBoostsMove} from "./mocks/StatBoostsMove.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @dev Priority +2 ally-speed boost (+127% Temp on own side's mon from the payload low 2 bits):
///      resolves before default-priority attacks so the dynamic scheduler's re-pick is visible.
contract FastAllySpeedBoost is IMoveSet {
    function name() external pure returns (string memory) {
        return "Fast Ally Speed Boost";
    }

    function move(IEngine engine, bytes32, uint256 attackerPlayerIndex, uint256, uint256, uint256, uint16 extraData, uint256)
        external
    {
        StatBoostToApply[] memory boosts = new StatBoostToApply[](1);
        boosts[0] = StatBoostToApply({
            stat: MonStateIndexName.Speed,
            boostPercent: 127,
            boostType: StatBoostType.Multiply
        });
        engine.addStatBoost(attackerPlayerIndex, uint256(extraData) & 0x3, boosts, StatBoostFlag.Temp);
    }

    function priority(IEngine, bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY + 2;
    }

    function stamina(IEngine, bytes32, uint256, uint256) external pure returns (uint32) {
        return 0;
    }

    function moveType(IEngine, bytes32) external pure returns (Type) {
        return Type.Air;
    }

    function moveClass(IEngine, bytes32) external pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.SelfTeamIndex;
    }

    function getMeta(IEngine, bytes32, uint256, uint256) external pure returns (MoveMeta memory) {
        return MoveMeta({
            moveType: Type.Air,
            moveClass: MoveClass.Self,
            extraDataType: ExtraDataType.SelfTeamIndex,
            targetSpec: TargetSpec.None,
            priority: DEFAULT_PRIORITY + 2,
            stamina: 0,
            basePower: 0
        });
    }
}

/// @notice Doubles (2-slot) engine core: dynamic scheduler, per-action KO continuation, fizzle,
///         forced-switch masks, exhausted slots, bench collisions, per-slot regen. Mocks only.
contract DoublesEngineTest is Test {
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);

    // Absolute slots
    uint256 constant A0 = 0;
    uint256 constant A1 = 1;
    uint256 constant B0 = 2;
    uint256 constant B1 = 3;

    Engine engine;
    TestTeamRegistry registry;
    TestTypeCalculator typeCalc;
    OrderRecorderAbility recorder;
    IMoveSet weakAttack; // BP 10, stamina 2, default priority
    IMoveSet killAttack; // BP 100, stamina 2, default priority
    IMoveSet fastAttack; // BP 10, stamina 2, priority +2
    StatBoostsMove boostMove;
    bytes32 battleKey;

    function setUp() public {
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        registry = new TestTeamRegistry();
        typeCalc = new TestTypeCalculator();
        recorder = new OrderRecorderAbility();
        weakAttack = new CustomAttack(
            typeCalc,
            CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 2, PRIORITY: DEFAULT_PRIORITY})
        );
        killAttack = new CustomAttack(
            typeCalc,
            CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 100, ACCURACY: 100, STAMINA_COST: 2, PRIORITY: DEFAULT_PRIORITY})
        );
        fastAttack = new CustomAttack(
            typeCalc,
            CustomAttack.Args({
                TYPE: Type.Fire,
                BASE_POWER: 10,
                ACCURACY: 100,
                STAMINA_COST: 2,
                PRIORITY: DEFAULT_PRIORITY + 2
            })
        );
        boostMove = new StatBoostsMove();

        address[] memory toAdd = new address[](1);
        toAdd[0] = address(this);
        address[] memory toRemove = new address[](0);
        vm.prank(ALICE);
        engine.updateMatchmakers(toAdd, toRemove);
        vm.prank(BOB);
        engine.updateMatchmakers(toAdd, toRemove);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _mkMon(uint32 hp, uint32 speed, IMoveSet move0) internal view returns (Mon memory mon) {
        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(move0)));
        moves[1] = uint256(uint160(address(boostMove)));
        mon = Mon({
            stats: MonStats({
                hp: hp,
                stamina: 5,
                speed: speed,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Air,
                type2: Type.None
            }),
            ability: uint256(uint160(address(recorder))),
            moves: moves
        });
    }

    function _startDoubles(Mon[] memory aTeam, Mon[] memory bTeam, address ruleset) internal {
        registry.setTeam(ALICE, aTeam);
        registry.setTeam(BOB, bTeam);
        Battle memory battle = Battle({
            p0: ALICE,
            p0TeamIndex: 0,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: registry,
            rngOracle: IRandomnessOracle(address(0)),
            ruleset: IRuleset(ruleset),
            moveManager: address(this),
            matchmaker: IMatchmaker(address(this)),
            engineHooks: new IEngineHook[](0)
        });
        (battleKey,) = engine.computeBattleKey(ALICE, BOB);
        engine.startBattleV2(battle, BATTLE_MODE_DOUBLES);
        // Game over in the same block as start reverts; every test may finish the battle.
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev Wire word per side: [m0 8 | e0 16 | m1 8 | e1 16 | salt 104].
    function _side(uint8 m0, uint16 e0, uint8 m1, uint16 e1) internal pure returns (uint256) {
        return uint256(m0) | (uint256(e0) << 8) | (uint256(m1) << 24) | (uint256(e1) << 32)
            | (uint256(uint104(0xABCDEF)) << 48);
    }

    /// @dev extraData for a targeted attack: target nibble (bit per absolute slot) + payload.
    function _target(uint256 absSlot) internal pure returns (uint16) {
        return uint16((uint16(1) << (TARGET_BITS_SHIFT + absSlot)));
    }

    function _turn0(uint16 a0Lead, uint16 a1Lead, uint16 b0Lead, uint16 b1Lead) internal {
        engine.executeWithSlotMoves(
            battleKey,
            _side(SWITCH_MOVE_INDEX, a0Lead, SWITCH_MOVE_INDEX, a1Lead),
            _side(SWITCH_MOVE_INDEX, b0Lead, SWITCH_MOVE_INDEX, b1Lead)
        );
    }

    function _assertSlots(uint256 s0, uint256 s1, uint256 s2, uint256 s3) internal view {
        uint256[4] memory slots = engine.getActiveSlots(battleKey);
        assertEq(slots[0], s0, "A0 lane");
        assertEq(slots[1], s1, "A1 lane");
        assertEq(slots[2], s2, "B0 lane");
        assertEq(slots[3], s3, "B1 lane");
    }

    /// @dev Asserts the sequence of AfterMove records (ignoring RoundStart/RoundEnd entries)
    ///      matches the expected (side, mon) pairs exactly.
    function _assertActionOrder(uint256, uint256[2][] memory expected) internal view {
        uint256 seen;
        for (uint256 i; i < recorder.count(); ++i) {
            (EffectStep step, uint256 side, uint256 mon) = recorder.entryAt(i);
            if (step != EffectStep.AfterMove) continue;
            assertTrue(seen < expected.length, "more actions than expected");
            assertEq(side, expected[seen][0], "action order: side");
            assertEq(mon, expected[seen][1], "action order: mon");
            seen++;
        }
        assertEq(seen, expected.length, "action count");
    }

    function _pair(uint256 side, uint256 mon) internal pure returns (uint256[2] memory p) {
        p[0] = side;
        p[1] = mon;
    }

    /// @dev Standard 4v4-ish teams: A speeds 40/30/25/24 (hp 1000), B speeds 20/10/9/8.
    function _standardTeams() internal view returns (Mon[] memory aTeam, Mon[] memory bTeam) {
        aTeam = new Mon[](4);
        aTeam[0] = _mkMon(1000, 40, weakAttack);
        aTeam[1] = _mkMon(1000, 30, weakAttack);
        aTeam[2] = _mkMon(1000, 25, weakAttack);
        aTeam[3] = _mkMon(1000, 24, weakAttack);
        bTeam = new Mon[](4);
        bTeam[0] = _mkMon(1000, 20, weakAttack);
        bTeam[1] = _mkMon(1000, 10, weakAttack);
        bTeam[2] = _mkMon(1000, 9, weakAttack);
        bTeam[3] = _mkMon(1000, 8, weakAttack);
    }

    // ---------------------------------------------------------------------
    // Turn 0 + ordering
    // ---------------------------------------------------------------------

    function test_turn0_sendIns_fillLanes() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        _startDoubles(aTeam, bTeam, address(0));
        _turn0(0, 1, 0, 1);
        _assertSlots(0, 1, 0, 1);

        // Abilities activate after all send-ins; the RoundEnd pass then records all four
        // actives in speed order (D29).
        assertEq(recorder.count(), 4, "four round-end records");
        (EffectStep step, uint256 side, uint256 mon) = recorder.entryAt(0);
        assertEq(uint8(step), uint8(EffectStep.RoundEnd));
        assertEq(side, 0);
        assertEq(mon, 0); // A0: speed 40
        (, side, mon) = recorder.entryAt(1);
        assertEq(side, 0);
        assertEq(mon, 1); // A1: speed 30
        (, side, mon) = recorder.entryAt(2);
        assertEq(side, 1);
        assertEq(mon, 0); // B0: speed 20
        (, side, mon) = recorder.entryAt(3);
        assertEq(side, 1);
        assertEq(mon, 1); // B1: speed 10
    }

    function test_turn0_nonSwitchSubmission_coerced() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        _startDoubles(aTeam, bTeam, address(0));
        // A submits attacks on turn 0 — engine coerces both lanes to legal send-ins.
        engine.executeWithSlotMoves(
            battleKey,
            _side(0, _target(B0), 0, _target(B0)),
            _side(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1)
        );
        uint256[4] memory slots = engine.getActiveSlots(battleKey);
        assertTrue(slots[0] != EMPTY_ACTIVE_LANE && slots[1] != EMPTY_ACTIVE_LANE, "A lanes filled");
        assertTrue(slots[0] != slots[1], "distinct A leads");
    }

    function test_actionOrder_speedThenPriority() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        bTeam[1] = _mkMon(1000, 10, fastAttack); // B1: slowest but priority +2 attack
        _startDoubles(aTeam, bTeam, address(0));
        _turn0(0, 1, 0, 1);
        recorder.clear();

        // Everyone attacks A0/B0 weakly; B1 uses the priority attack -> acts first.
        engine.executeWithSlotMoves(
            battleKey,
            _side(0, _target(B0), 0, _target(B0)),
            _side(0, _target(A0), 0, _target(A0))
        );
        uint256[2][] memory expected = new uint256[2][](4);
        expected[0] = _pair(1, 1); // B1 (priority)
        expected[1] = _pair(0, 0); // A0 speed 40
        expected[2] = _pair(0, 1); // A1 speed 30
        expected[3] = _pair(1, 0); // B0 speed 20
        _assertActionOrder(0, expected);
    }

    function test_dynamicSpeed_boostReordersRemainingActors() public {
        FastAllySpeedBoost fastBoost = new FastAllySpeedBoost();
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, IMoveSet(address(fastBoost)));
        aTeam[1] = _mkMon(1000, 5, weakAttack); // slowest before the boost
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(1000, 20, weakAttack);
        bTeam[1] = _mkMon(1000, 10, weakAttack);
        _startDoubles(aTeam, bTeam, address(0));
        _turn0(0, 1, 0, 1);
        recorder.clear();

        // A0 (priority +2 boost) acts first and raises ally A1's speed +127% (5 -> 11); the
        // re-evaluated order then puts A1 behind B0 (20) but ahead of B1 (10).
        // Locked-at-turn-start ordering would have run A1 last (D1).
        engine.executeWithSlotMoves(
            battleKey,
            _side(0, uint16(1), 0, _target(B0)),
            _side(0, _target(A0), 0, _target(A0))
        );
        uint256[2][] memory expected = new uint256[2][](4);
        expected[0] = _pair(0, 0); // A0 boosts A1 (priority)
        expected[1] = _pair(1, 0); // B0 speed 20
        expected[2] = _pair(0, 1); // A1 now speed 11 — jumped ahead of B1
        expected[3] = _pair(1, 1); // B1 speed 10
        _assertActionOrder(0, expected);
    }

    // ---------------------------------------------------------------------
    // Mid-turn KO, fizzle, ally targeting
    // ---------------------------------------------------------------------

    function test_midTurnKO_turnContinues_koedActorLosesAction() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        bTeam[0] = _mkMon(100, 20, weakAttack); // B0 dies to one killAttack
        aTeam[0] = _mkMon(1000, 40, killAttack);
        _startDoubles(aTeam, bTeam, address(0));
        _turn0(0, 1, 0, 1);
        recorder.clear();

        engine.executeWithSlotMoves(
            battleKey,
            _side(0, _target(B0), 0, _target(B1)),
            _side(0, _target(A0), 0, _target(A0))
        );

        // A0 kills B0; A1 and B1 still act (D1/D7); B0's action is simply lost.
        uint256[2][] memory expected = new uint256[2][](3);
        expected[0] = _pair(0, 0);
        expected[1] = _pair(0, 1);
        expected[2] = _pair(1, 1);
        _assertActionOrder(0, expected);
        // B0 never acted: no stamina spent.
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), 0, "B0 stamina unspent");
        // Forced-switch mask for B slot 0 (absolute slot 2).
        assertEq(engine.getBattleContext(battleKey).playerSwitchForTurnFlag, uint8(0x80 | (1 << B0)), "switch mask");
    }

    function test_fizzle_targetKOdMidTurn_staminaSpent() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        bTeam[0] = _mkMon(100, 20, weakAttack);
        aTeam[0] = _mkMon(1000, 40, killAttack);
        _startDoubles(aTeam, bTeam, address(0));
        _turn0(0, 1, 0, 1);

        // Both A slots target B0; A0 kills it, A1's attack fizzles (D2) but the stamina is spent.
        engine.executeWithSlotMoves(
            battleKey,
            _side(0, _target(B0), 0, _target(B0)),
            _side(0, _target(A0), 0, _target(A0))
        );
        assertEq(engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Stamina), -2, "A1 stamina spent");
        // B0 took exactly A0's 100 (the fizzled hit added nothing).
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -100, "only A0's damage landed");
    }

    function test_allyTargeting_damagesOwnSlot() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        _startDoubles(aTeam, bTeam, address(0));
        _turn0(0, 1, 0, 1);

        // A0 punches its ally A1 (D4).
        engine.executeWithSlotMoves(
            battleKey,
            _side(0, _target(A1), NO_OP_MOVE_INDEX, 0),
            _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        assertEq(engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Hp), -10, "ally took the hit");
    }

    // ---------------------------------------------------------------------
    // Forced switches, exhausted slots, collisions
    // ---------------------------------------------------------------------

    function test_forcedSwitchTurn_onlyMaskedSlotActs() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        bTeam[0] = _mkMon(100, 20, weakAttack);
        aTeam[0] = _mkMon(1000, 40, killAttack);
        _startDoubles(aTeam, bTeam, address(0));
        _turn0(0, 1, 0, 1);
        engine.executeWithSlotMoves(
            battleKey, _side(0, _target(B0), 0, _target(B1)), _side(0, _target(A0), 0, _target(A0))
        );
        assertEq(engine.getBattleContext(battleKey).playerSwitchForTurnFlag, uint8(0x80 | (1 << B0)));
        recorder.clear();

        // Only B slot 0 acts: replacement mon 2 comes in; no effect passes run on mask turns.
        engine.executeWithSlotMoves(battleKey, _side(0, 0, 0, 0), _side(SWITCH_MOVE_INDEX, 2, 0, 0));
        _assertSlots(0, 1, 2, 1);
        assertEq(recorder.count(), 0, "mask turns run no round/aftermove passes");
        assertEq(engine.getBattleContext(battleKey).playerSwitchForTurnFlag, 2, "back to a full turn");
    }

    function test_dualKO_bothSlotsSwitchBlind() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        bTeam[0] = _mkMon(100, 20, weakAttack);
        bTeam[1] = _mkMon(100, 10, weakAttack);
        aTeam[0] = _mkMon(1000, 40, killAttack);
        aTeam[1] = _mkMon(1000, 30, killAttack);
        _startDoubles(aTeam, bTeam, address(0));
        _turn0(0, 1, 0, 1);

        engine.executeWithSlotMoves(
            battleKey, _side(0, _target(B0), 0, _target(B1)), _side(0, _target(A0), 0, _target(A0))
        );
        assertEq(
            engine.getBattleContext(battleKey).playerSwitchForTurnFlag,
            uint8(0x80 | (1 << B0) | (1 << B1)),
            "both B slots masked"
        );

        engine.executeWithSlotMoves(battleKey, _side(0, 0, 0, 0), _side(SWITCH_MOVE_INDEX, 2, SWITCH_MOVE_INDEX, 3));
        _assertSlots(0, 1, 2, 3);
    }

    function test_exhaustedSlot_skippedAndBattleContinues() public {
        (Mon[] memory aTeam,) = _standardTeams();
        aTeam[0] = _mkMon(1000, 40, killAttack);
        Mon[] memory bTeam = new Mon[](2); // both active, no bench
        bTeam[0] = _mkMon(100, 20, weakAttack);
        bTeam[1] = _mkMon(1000, 10, weakAttack);
        _startDoubles(aTeam, bTeam, address(0));
        _turn0(0, 1, 0, 1);

        // A0 kills B0. No replacement exists -> no mask; the slot is exhausted (D6).
        engine.executeWithSlotMoves(
            battleKey, _side(0, _target(B0), NO_OP_MOVE_INDEX, 0), _side(0, _target(A0), 0, _target(A0))
        );
        assertEq(engine.getBattleContext(battleKey).playerSwitchForTurnFlag, 2, "no switch turn: exhausted");
        recorder.clear();

        // Next full turn: B0's lane carries NO_OP filler; only three actors run.
        engine.executeWithSlotMoves(
            battleKey,
            _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0),
            _side(NO_OP_MOVE_INDEX, 0, 0, _target(A0))
        );
        uint256 afterMoves;
        for (uint256 i; i < recorder.count(); ++i) {
            (EffectStep step,,) = recorder.entryAt(i);
            if (step == EffectStep.AfterMove) {
                afterMoves++;
            }
        }
        assertEq(afterMoves, 3, "exhausted slot never acts");
    }

    function test_doublesBenchCollision_secondSwitchNoOps() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        _startDoubles(aTeam, bTeam, address(0));
        _turn0(0, 1, 0, 1);

        // Both A slots try to grab bench mon 2; A0 (faster) wins, A1's switch no-ops.
        engine.executeWithSlotMoves(
            battleKey,
            _side(SWITCH_MOVE_INDEX, 2, SWITCH_MOVE_INDEX, 2),
            _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        _assertSlots(2, 1, 0, 1);
    }

    function test_switchToAllyActiveMon_noOps() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        _startDoubles(aTeam, bTeam, address(0));
        _turn0(0, 1, 0, 1);

        engine.executeWithSlotMoves(
            battleKey,
            _side(SWITCH_MOVE_INDEX, 1, NO_OP_MOVE_INDEX, 0),
            _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        _assertSlots(0, 1, 0, 1);
    }

    // ---------------------------------------------------------------------
    // Regen + game over
    // ---------------------------------------------------------------------

    function test_regen_perSlotRestAndRoundEnd() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        _startDoubles(aTeam, bTeam, INLINE_STAMINA_REGEN_RULESET);
        _turn0(0, 1, 0, 1);

        // Turn 1: everyone attacks (cost 2), round-end regen +1 -> all at -1.
        engine.executeWithSlotMoves(
            battleKey, _side(0, _target(B0), 0, _target(B0)), _side(0, _target(A0), 0, _target(A0))
        );
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -1);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Stamina), -1);

        // Turn 2: A0 rests (+1 on AfterMove, +1 at round end -> back to 0 ... capped at 0 by
        // delta<0 guard); the attackers land at -1-2+1 = -2.
        engine.executeWithSlotMoves(
            battleKey, _side(NO_OP_MOVE_INDEX, 0, 0, _target(B0)), _side(0, _target(A0), 0, _target(A0))
        );
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), 0, "rest + regen");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Stamina), -2, "attacker");
    }

    function test_sideWipe_winnerStopsRemainingActions() public {
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, killAttack);
        aTeam[1] = _mkMon(1000, 30, killAttack);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(100, 20, weakAttack);
        bTeam[1] = _mkMon(100, 10, weakAttack);
        _startDoubles(aTeam, bTeam, address(0));
        _turn0(0, 1, 0, 1);
        recorder.clear();

        address winner = engine.executeWithSlotMoves(
            battleKey, _side(0, _target(B0), 0, _target(B1)), _side(0, _target(A0), 0, _target(A0))
        );
        assertEq(winner, ALICE, "side wipe -> side 0 wins");
        assertEq(engine.getWinner(battleKey), ALICE);
        // A0 acted; A1's killing blow ended the game before its AfterMove pass; B never acted.
        uint256 afterMoves;
        for (uint256 i; i < recorder.count(); ++i) {
            (EffectStep step,,) = recorder.entryAt(i);
            if (step == EffectStep.AfterMove) afterMoves++;
        }
        assertEq(afterMoves, 1, "remaining actions stop at game over");
    }

    function test_singlesModeUnaffected_startBattleV2Guards() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        registry.setTeam(ALICE, aTeam);
        registry.setTeam(BOB, bTeam);
        Battle memory battle = Battle({
            p0: ALICE,
            p0TeamIndex: 0,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: registry,
            rngOracle: IRandomnessOracle(address(0)),
            ruleset: IRuleset(address(0)),
            moveManager: address(this),
            matchmaker: IMatchmaker(address(this)),
            engineHooks: new IEngineHook[](0)
        });
        vm.expectRevert(Engine.InvalidBattleConfig.selector);
        engine.startBattleV2(battle, 3); // unknown mode

        battle.moveManager = BUILTIN_DUAL_SIGNED_MANAGER;
        vm.expectRevert(Engine.InvalidBattleConfig.selector);
        engine.startBattleV2(battle, BATTLE_MODE_DOUBLES); // builtin buffer flow is phase E
    }
}
