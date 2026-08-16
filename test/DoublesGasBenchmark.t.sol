// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import {Vm} from "../lib/forge-std/src/Vm.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {ZapStatus} from "../src/effects/status/ZapStatus.sol";
import {IMatchmaker} from "../src/matchmaker/IMatchmaker.sol";
import {VitalSiphon} from "../src/mons/xmon/VitalSiphon.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {MoveSlotLib} from "../src/moves/MoveSlotLib.sol";
import {StandardAttack} from "../src/moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";

import {BatchHelper} from "./abstract/BatchHelper.sol";
import {GasMeasure} from "./abstract/GasMeasure.sol";
import {defaultBattle, sideWord, targetBits} from "./abstract/SlotWire.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @title Doubles gas benchmark — 2-slot batched one-tx replay and buffer+drain
/// @notice The 2-slot analog of ProdPvPGasBenchmark: a fixed 12-turn doubles script covering
///         send-ins, a status application (Zap -> RoundStart/RoundEnd effect passes run for the
///         rest of the battle), a KO + forced-switch mask turn, and a long all-rest tail where
///         the actives carry no effects (the effect passes idle). Measured once as a single
///         batched tx (the PvE shape) and once as staged submits + drain (the PvP shape).
contract DoublesGasBenchmark is BatchHelper, GasMeasure {
    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    address p0;
    address p1;

    Engine engine;
    TestTeamRegistry registry;
    TestTypeCalculator typeCalc;
    IMoveSet weakAttack;
    IMoveSet killAttack;
    StandardAttack zapDart;
    ZapStatus zapStatus;

    bool private _measuring;
    Tally private _acc;
    uint256 private _accGas;

    function _snapshotEffectCensus(string memory name, Vm.AccountAccess[] memory accesses, bytes32 storageKey) private {
        EffectStorageTally memory effectStorage = _effectStorageTally(accesses, address(engine), storageKey);
        uint256 roundStartCalls = _countCalls(accesses, address(engine), address(0), IEffect.onRoundStart.selector);
        uint256 roundEndCalls = _countCalls(accesses, address(engine), address(0), IEffect.onRoundEnd.selector);
        uint256 afterMoveCalls = _countCalls(accesses, address(engine), address(0), IEffect.onAfterMove.selector);
        uint256 preDamageCalls = _countCalls(accesses, address(engine), address(0), IEffect.onPreDamage.selector);
        uint256 afterDamageCalls = _countCalls(accesses, address(engine), address(0), IEffect.onAfterDamage.selector);
        uint256 updateStateCalls = _countCalls(accesses, address(engine), address(0), IEffect.onUpdateMonState.selector);
        uint256 moveDecisionCallbacks =
            _countCalls(accesses, address(0), address(engine), IEngine.getMoveDecisionForSlot.selector);
        uint256 lifecycleCalls =
            roundStartCalls + roundEndCalls + afterMoveCalls + preDamageCalls + afterDamageCalls + updateStateCalls;
        uint256 nonHookHeaderReadUpperBound =
            effectStorage.headerReads > lifecycleCalls ? effectStorage.headerReads - lifecycleCalls : 0;

        vm.snapshotValue(string.concat(name, "_effectHeaderReads"), effectStorage.headerReads);
        vm.snapshotValue(string.concat(name, "_effectDataReads"), effectStorage.dataReads);
        vm.snapshotValue(string.concat(name, "_effectHeaderWrites"), effectStorage.headerWrites);
        vm.snapshotValue(string.concat(name, "_effectDataWrites"), effectStorage.dataWrites);
        vm.snapshotValue(string.concat(name, "_roundStartCalls"), roundStartCalls);
        vm.snapshotValue(string.concat(name, "_roundEndCalls"), roundEndCalls);
        vm.snapshotValue(string.concat(name, "_afterMoveCalls"), afterMoveCalls);
        vm.snapshotValue(string.concat(name, "_preDamageCalls"), preDamageCalls);
        vm.snapshotValue(string.concat(name, "_afterDamageCalls"), afterDamageCalls);
        vm.snapshotValue(string.concat(name, "_updateStateCalls"), updateStateCalls);
        vm.snapshotValue(string.concat(name, "_moveDecisionCallbacks"), moveDecisionCallbacks);
        vm.snapshotValue(string.concat(name, "_lifecycleCalls"), lifecycleCalls);
        vm.snapshotValue(string.concat(name, "_nonHookHeaderReadUpperBound"), nonHookHeaderReadUpperBound);

        console.log(
            string.concat(name, " effect header/data reads:"), effectStorage.headerReads, effectStorage.dataReads
        );
        console.log(
            string.concat(name, " RoundStart/RoundEnd/AfterMove:"), roundStartCalls, roundEndCalls, afterMoveCalls
        );
        console.log(
            string.concat(name, " PreDamage/AfterDamage/UpdateState:"),
            preDamageCalls,
            afterDamageCalls,
            updateStateCalls
        );
        console.log(string.concat(name, " moveDecision callbacks:"), moveDecisionCallbacks);
        console.log(string.concat(name, " non-hook header read upper bound:"), nonHookHeaderReadUpperBound);
    }

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);
        registry = new TestTeamRegistry();
        typeCalc = new TestTypeCalculator();
        weakAttack = new CustomAttack(
            typeCalc,
            CustomAttack.Args({
                TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: DEFAULT_PRIORITY
            })
        );
        killAttack = new CustomAttack(
            typeCalc,
            CustomAttack.Args({
                TYPE: Type.Fire, BASE_POWER: 200, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: DEFAULT_PRIORITY
            })
        );
        zapStatus = new ZapStatus();
        zapDart = new StandardAttack(
            address(this),
            typeCalc,
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Lightning,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Other,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Zap Dart",
                EFFECT: IEffect(address(zapStatus))
            })
        );
    }

    /// @dev Deployed moves carry packed static metadata, mirroring the prod catalog shape.
    function _mkMon(uint32 hp, uint32 speed, IMoveSet move1, uint256 move1Stamina)
        internal
        view
        returns (Mon memory mon)
    {
        uint256[] memory moves = new uint256[](3);
        moves[0] = MoveSlotLib.packDeployed(address(weakAttack), 1, DEFAULT_PRIORITY);
        moves[1] = MoveSlotLib.packDeployed(address(move1), move1Stamina, DEFAULT_PRIORITY);
        moves[2] = MoveSlotLib.packDeployed(address(killAttack), 1, DEFAULT_PRIORITY);
        mon = Mon({
            stats: MonStats({
                hp: hp,
                stamina: 20,
                speed: speed,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Air,
                type2: Type.None
            }),
            ability: 0,
            moves: moves
        });
    }

    function _startDoubles(address moveManager) internal returns (bytes32 battleKey) {
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(this);
        vm.prank(p0);
        engine.updateMatchmakers(toAdd, new address[](0));
        vm.prank(p1);
        engine.updateMatchmakers(toAdd, new address[](0));

        Mon[] memory aTeam = new Mon[](3);
        aTeam[0] = _mkMon(1000, 40, IMoveSet(address(zapDart)), 1);
        aTeam[1] = _mkMon(1000, 30, IMoveSet(address(zapDart)), 1);
        aTeam[2] = _mkMon(1000, 25, IMoveSet(address(zapDart)), 1);
        Mon[] memory bTeam = new Mon[](3);
        bTeam[0] = _mkMon(1000, 20, weakAttack, 1);
        bTeam[1] = _mkMon(120, 10, weakAttack, 1);
        bTeam[2] = _mkMon(1000, 5, weakAttack, 1);
        registry.setTeam(p0, aTeam);
        registry.setTeam(p1, bTeam);

        Battle memory battle = defaultBattle(p0, p1, registry, moveManager, IMatchmaker(address(this)));
        battle.ruleset = IRuleset(INLINE_STAMINA_REGEN_RULESET);
        (battleKey,) = engine.computeBattleKey(p0, p1);
        engine.startBattleWithMode(battle, BATTLE_MODE_DOUBLES);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev 12-turn script: send-ins; zap B1 while everyone trades; kill B1 (mask turn); the
    ///      replacement arrives; 8 all-rest turns with clean actives but a Zap-set steps union.
    function _scriptSides(uint64 t) internal pure returns (uint256 side0, uint256 side1) {
        uint104 s0 = uint104(uint256(keccak256(abi.encode("d0", t))));
        uint104 s1 = uint104(uint256(keccak256(abi.encode("d1", t))));
        if (t == 0) {
            side0 = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, s0);
            side1 = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, s1);
        } else if (t == 1) {
            // A0 weak -> B0; A1 zaps B1 before it acts; B side trades into A0.
            side0 = sideWord(0, targetBits(2), 1, targetBits(3), s0);
            side1 = sideWord(0, targetBits(0), 0, targetBits(0), s1);
        } else if (t == 2) {
            // A0 kills B1 (mask turn follows); everyone else rests.
            side0 = sideWord(2, targetBits(3), NO_OP_MOVE_INDEX, 0, s0);
            side1 = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, s1);
        } else if (t == 3) {
            // Forced-switch mask turn: B slot 1 sends in mon 2.
            side0 = sideWord(0, 0, 0, 0, s0);
            side1 = sideWord(0, 0, SWITCH_MOVE_INDEX, 2, s1);
        } else {
            // Steady-state tail: all four actives rest; no active carries an effect but the
            // Zap application left the RoundStart/RoundEnd union bits set for the battle.
            side0 = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, s0);
            side1 = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, s1);
        }
    }

    /// @notice PvE shape: the full 12-turn script settled in ONE executeBatchedSlotTurns tx.
    function test_doublesBatchedReplayGas() public {
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        bytes32 battleKey = _startDoubles(address(this));
        bytes32 storageKey = engine.getStorageKey(battleKey);

        uint256[] memory entries = new uint256[](24);
        for (uint64 t = 0; t < 12; t++) {
            (entries[t * 2], entries[t * 2 + 1]) = _scriptSides(t);
        }

        _beginMeasure();
        vm.cool(address(engine));
        vm.startStateDiffRecording();
        uint256 g0 = gasleft();
        engine.executeBatchedSlotTurns(battleKey, entries);
        _accGas += g0 - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        _acc = _addTally(_acc, _tally(accesses));
        engine.resetCallContext();
        _endMeasure("Doubles_Batch12");
        _snapshotEffectCensus("Doubles_Batch12", accesses, storageKey);

        assertEq(engine.getTurnIdForBattleState(battleKey), 12, "all twelve turns executed");
    }

    /// @notice PvP shape: the first 6 script turns staged as individual dual-signed submits,
    ///         then one permissionless drain.
    function test_doublesStageThenDrainGas() public {
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        bytes32 battleKey = _startDoubles(BUILTIN_DUAL_SIGNED_MANAGER);

        _beginMeasure();
        for (uint64 t = 0; t < 6; t++) {
            (uint256 side0, uint256 side1) = _scriptSides(t);
            (uint256 committerPacked, uint256 revealerPacked, bytes32 r, bytes32 vs) =
                _buildSlotTurnSubmissionForEngine(address(engine), battleKey, t, side0, side1, P0_PK, P1_PK);
            vm.cool(address(engine));
            vm.startStateDiffRecording();
            uint256 g0 = gasleft();
            vm.prank(t % 2 == 0 ? p0 : p1);
            engine.submitSlotTurnMoves(battleKey, committerPacked, revealerPacked, r, vs);
            _accGas += g0 - gasleft();
            _acc = _addTally(_acc, _tally(vm.stopAndReturnStateDiff()));
            engine.resetCallContext();
        }
        _endMeasure("Doubles_Stage6");

        _beginMeasure();
        vm.cool(address(engine));
        vm.startStateDiffRecording();
        uint256 g0 = gasleft();
        vm.prank(address(0xCAFE));
        engine.executeBuffered(battleKey);
        _accGas += g0 - gasleft();
        _acc = _addTally(_acc, _tally(vm.stopAndReturnStateDiff()));
        engine.resetCallContext();
        _endMeasure("Doubles_Drain6");

        assertEq(engine.getTurnIdForBattleState(battleKey), 6, "all six buffered turns executed");
    }

    /// @notice Real-kit shape: a burn DOT ticking all game plus VitalSiphon's engine-read-heavy
    ///         steal path every turn — the external-call surface mock attacks hide.
    function test_doublesKitBatchGas() public {
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        BurnStatus burn = new BurnStatus();
        StandardAttack burnDart = new StandardAttack(
            address(this),
            typeCalc,
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Other,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Burn Dart",
                EFFECT: IEffect(address(burn))
            })
        );
        VitalSiphon siphon = new VitalSiphon(ITypeCalculator(address(typeCalc)));

        address[] memory toAdd = new address[](1);
        toAdd[0] = address(this);
        vm.prank(p0);
        engine.updateMatchmakers(toAdd, new address[](0));
        vm.prank(p1);
        engine.updateMatchmakers(toAdd, new address[](0));

        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, IMoveSet(address(burnDart)), 1);
        aTeam[1] = _mkMon(1000, 30, IMoveSet(address(siphon)), 2);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(4000, 20, weakAttack, 1);
        bTeam[1] = _mkMon(4000, 10, weakAttack, 1);
        registry.setTeam(p0, aTeam);
        registry.setTeam(p1, bTeam);
        Battle memory battle = defaultBattle(p0, p1, registry, address(this), IMatchmaker(address(this)));
        battle.ruleset = IRuleset(INLINE_STAMINA_REGEN_RULESET);
        (bytes32 battleKey,) = engine.computeBattleKey(p0, p1);
        engine.startBattleWithMode(battle, BATTLE_MODE_DOUBLES);
        bytes32 storageKey = engine.getStorageKey(battleKey);
        vm.warp(vm.getBlockTimestamp() + 1);

        // T0 send-ins; T1 burn B0 + siphon B1 while B rests; T2-T9 siphon every turn while
        // the burn ticks (B side rests; regen keeps stamina alive).
        uint256[] memory entries = new uint256[](20);
        for (uint64 t = 0; t < 10; t++) {
            uint104 s0 = uint104(uint256(keccak256(abi.encode("k0", t))));
            uint104 s1 = uint104(uint256(keccak256(abi.encode("k1", t))));
            if (t == 0) {
                entries[0] = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, s0);
                entries[1] = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, s1);
            } else if (t == 1) {
                entries[2] = sideWord(1, targetBits(2), 1, targetBits(3), s0);
                entries[3] = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, s1);
            } else {
                entries[t * 2] = sideWord(NO_OP_MOVE_INDEX, 0, 1, targetBits(3), s0);
                entries[t * 2 + 1] = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, s1);
            }
        }

        _beginMeasure();
        vm.cool(address(engine));
        vm.startStateDiffRecording();
        uint256 g0 = gasleft();
        engine.executeBatchedSlotTurns(battleKey, entries);
        _accGas += g0 - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        _acc = _addTally(_acc, _tally(accesses));
        engine.resetCallContext();
        _endMeasure("Doubles_KitBatch10");
        _snapshotEffectCensus("Doubles_KitBatch10", accesses, storageKey);

        assertEq(engine.getTurnIdForBattleState(battleKey), 10, "all ten turns executed");
    }

    function _tailEntries(uint256 n, uint256 shape) private pure returns (uint256[] memory entries) {
        entries = new uint256[](n * 2);
        for (uint256 t; t < n; t++) {
            uint104 s0 = uint104(10_000 + 2 * t);
            uint104 s1 = uint104(10_001 + 2 * t);
            if (shape == 0) {
                entries[t * 2] = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, s0);
                entries[t * 2 + 1] = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, s1);
            } else if (shape == 1) {
                entries[t * 2] = sideWord(0, targetBits(2), NO_OP_MOVE_INDEX, 0, s0);
                entries[t * 2 + 1] = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, s1);
            } else {
                entries[t * 2] = sideWord(0, targetBits(2), 0, targetBits(3), s0);
                entries[t * 2 + 1] = sideWord(0, targetBits(0), 0, targetBits(1), s1);
            }
        }
    }

    function _measureDoublesTail(uint256 shape, uint256 n) private returns (uint256 rawGas) {
        bytes32 battleKey = _startDoubles(address(this));
        (uint256 side0, uint256 side1) = _scriptSides(0);
        uint256[] memory sendIns = new uint256[](2);
        sendIns[0] = side0;
        sendIns[1] = side1;
        engine.executeBatchedSlotTurns(battleKey, sendIns);
        engine.resetCallContext();

        uint256[] memory entries = _tailEntries(n, shape);
        vm.cool(address(engine));
        uint256 g0 = gasleft();
        engine.executeBatchedSlotTurns(battleKey, entries);
        rawGas = g0 - gasleft();
        engine.resetCallContext();
        vm.prank(p0);
        engine.forfeit(battleKey);
    }

    /// @notice Differential 2-slot pipeline matrix on the same recycled storage key and teams.
    ///         The tails vary only action shape: four rests, one attack, or four attacks.
    function test_doublesTurnFloorMatrix() public {
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);

        // Seed and free the one-key pool so every measured scenario is reused-key steady state.
        bytes32 warmup = _startDoubles(address(this));
        vm.prank(p0);
        engine.forfeit(warmup);

        uint256 n = 8;
        uint256 allRest = _measureDoublesTail(0, n);
        uint256 oneAttack = _measureDoublesTail(1, n);
        uint256 allAttack = _measureDoublesTail(2, n);

        vm.snapshotValue("DoublesFloor_AllRest8_rawGas", allRest);
        vm.snapshotValue("DoublesFloor_OneAttack8_rawGas", oneAttack);
        vm.snapshotValue("DoublesFloor_AllAttack8_rawGas", allAttack);
        vm.snapshotValue("DoublesFloor_AllRest_perTurn", allRest / n);
        vm.snapshotValue("DoublesFloor_OneAttack_perTurn", oneAttack / n);
        vm.snapshotValue("DoublesFloor_AllAttack_perTurn", allAttack / n);

        console.log("Doubles floor matrix, 8-turn tails:");
        console.log("  all rest total/per turn:", allRest, allRest / n);
        console.log("  one attack total/per turn:", oneAttack, oneAttack / n);
        console.log("  all attack total/per turn:", allAttack, allAttack / n);
    }

    // ----- GasMeasure plumbing (mirrors ProdPvPGasBenchmark) -----

    function _beginMeasure() internal {
        _measuring = true;
        delete _acc;
        _accGas = 0;
    }

    function _endMeasure(string memory name) internal returns (uint256 gasUsed) {
        _measuring = false;
        _snapScenario(name, _acc, _accGas);
        return _accGas;
    }
}
