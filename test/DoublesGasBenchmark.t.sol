// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {ZapStatus} from "../src/effects/status/ZapStatus.sol";
import {IMatchmaker} from "../src/matchmaker/IMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {StandardAttack} from "../src/moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";

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

    function _mkMon(uint32 hp, uint32 speed, IMoveSet move1) internal view returns (Mon memory mon) {
        uint256[] memory moves = new uint256[](3);
        moves[0] = uint256(uint160(address(weakAttack)));
        moves[1] = uint256(uint160(address(move1)));
        moves[2] = uint256(uint160(address(killAttack)));
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
        aTeam[0] = _mkMon(1000, 40, zapDart);
        aTeam[1] = _mkMon(1000, 30, zapDart);
        aTeam[2] = _mkMon(1000, 25, zapDart);
        Mon[] memory bTeam = new Mon[](3);
        bTeam[0] = _mkMon(1000, 20, weakAttack);
        bTeam[1] = _mkMon(120, 10, weakAttack);
        bTeam[2] = _mkMon(1000, 5, weakAttack);
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
        _acc = _addTally(_acc, _tally(vm.stopAndReturnStateDiff()));
        engine.resetCallContext();
        _endMeasure("Doubles_Batch12");

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
