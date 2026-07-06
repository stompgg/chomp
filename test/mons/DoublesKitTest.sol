// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {Engine} from "../../src/Engine.sol";
import {IEngineHook} from "../../src/IEngineHook.sol";
import {IRuleset} from "../../src/IRuleset.sol";
import {IMatchmaker} from "../../src/matchmaker/IMatchmaker.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {IRandomnessOracle} from "../../src/rng/IRandomnessOracle.sol";

import {Q5} from "../../src/mons/embursa/Q5.sol";
import {HitAndDip} from "../../src/mons/inutia/HitAndDip.sol";
import {Interweaving} from "../../src/mons/inutia/Interweaving.sol";

import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

/// @notice Doubles rulings on real kits (see docs/DOUBLES_KIT_RULINGS.md): Q5's slot-bound
///         detonation, pivot moves vacating the caster's slot, and mirror-slot ability debuffs.
contract DoublesKitTest is Test {
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);

    Engine engine;
    TestTeamRegistry registry;
    TestTypeCalculator typeCalc;
    bytes32 battleKey;

    function setUp() public {
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        registry = new TestTeamRegistry();
        typeCalc = new TestTypeCalculator();
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(this);
        vm.prank(ALICE);
        engine.updateMatchmakers(toAdd, new address[](0));
        vm.prank(BOB);
        engine.updateMatchmakers(toAdd, new address[](0));
    }

    function _mkMon(IMoveSet move0, uint256 ability) internal pure returns (Mon memory mon) {
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(move0)));
        mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 5,
                speed: 10,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Air,
                type2: Type.None
            }),
            ability: ability,
            moves: moves
        });
    }

    function _start(Mon[] memory aTeam, Mon[] memory bTeam) internal {
        registry.setTeam(ALICE, aTeam);
        registry.setTeam(BOB, bTeam);
        (battleKey,) = engine.computeBattleKey(ALICE, BOB);
        engine.startBattleWithMode(
            Battle({
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
            }),
            BATTLE_MODE_DOUBLES
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _side(uint8 m0, uint16 e0, uint8 m1, uint16 e1) internal pure returns (uint256) {
        return uint256(m0) | (uint256(e0) << 8) | (uint256(m1) << 24) | (uint256(e1) << 32)
            | (uint256(uint104(0xC0FFEE)) << 48);
    }

    function _target(uint256 absSlot) internal pure returns (uint16) {
        return uint16(uint256(1) << (TARGET_BITS_SHIFT + absSlot));
    }

    function _turn0() internal {
        engine.executeWithSlotMoves(
            battleKey,
            _side(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1),
            _side(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1)
        );
    }

    function _noOpTurn() internal {
        engine.executeWithSlotMoves(
            battleKey,
            _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0),
            _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
    }

    /// @dev Q5 armed at B1's slot detonates on that slot's CURRENT occupant even after the
    ///      original target switches out; the untargeted opposing slot is untouched.
    function test_q5_detonationIsSlotBound() public {
        Q5 q5 = new Q5(typeCalc);
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(IMoveSet(address(q5)), 0);
        aTeam[1] = _mkMon(IMoveSet(address(q5)), 0);
        Mon[] memory bTeam = new Mon[](3);
        bTeam[0] = _mkMon(IMoveSet(address(q5)), 0);
        bTeam[1] = _mkMon(IMoveSet(address(q5)), 0);
        bTeam[2] = _mkMon(IMoveSet(address(q5)), 0);
        _start(aTeam, bTeam);
        _turn0();

        // A0 arms Q5 at absolute slot 3 (B slot 1, occupied by B mon 1).
        engine.executeWithSlotMoves(
            battleKey,
            _side(0, _target(3), NO_OP_MOVE_INDEX, 0),
            _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );

        // B1 pivots out: mon 2 takes the doomed slot.
        engine.executeWithSlotMoves(
            battleKey,
            _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0),
            _side(NO_OP_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 2)
        );

        // Remaining countdown round starts, then the blast.
        for (uint256 i; i < 4; ++i) {
            _noOpTurn();
        }

        assertLt(engine.getMonStateForBattle(battleKey, 1, 2, MonStateIndexName.Hp), 0, "slot occupant took the blast");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Hp), 0, "the mon that fled is safe");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), 0, "untargeted slot untouched");
    }

    /// @dev Hit And Dip vacates the CASTER's slot (A slot 1), not slot 0.
    function test_hitAndDip_pivotsCasterSlot() public {
        HitAndDip hitAndDip = new HitAndDip(typeCalc);
        Mon[] memory aTeam = new Mon[](3);
        aTeam[0] = _mkMon(IMoveSet(address(hitAndDip)), 0);
        aTeam[1] = _mkMon(IMoveSet(address(hitAndDip)), 0);
        aTeam[2] = _mkMon(IMoveSet(address(hitAndDip)), 0);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(IMoveSet(address(hitAndDip)), 0);
        bTeam[1] = _mkMon(IMoveSet(address(hitAndDip)), 0);
        _start(aTeam, bTeam);
        _turn0();

        // A1 hits B0 and dips to bench mon 2.
        engine.executeWithSlotMoves(
            battleKey,
            _side(NO_OP_MOVE_INDEX, 0, 0, _target(2) | uint16(2)),
            _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );

        uint256[4] memory slots = engine.getActiveSlots(battleKey);
        assertEq(slots[0], 0, "A slot 0 untouched");
        assertEq(slots[1], 2, "caster's slot pivoted to the bench mon");
        assertLt(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), 0, "target took the hit");
    }

    /// @dev Interweaving's swap-in debuff lands on the MIRROR of Inutia's slot (A slot 1 ->
    ///      B slot 1), leaving the other opposing slot untouched.
    function test_interweaving_debuffsMirrorSlot() public {
        Interweaving interweaving = new Interweaving();
        HitAndDip filler = new HitAndDip(typeCalc);
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(IMoveSet(address(filler)), 0);
        aTeam[1] = _mkMon(IMoveSet(address(filler)), uint256(uint160(address(interweaving))));
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(IMoveSet(address(filler)), 0);
        bTeam[1] = _mkMon(IMoveSet(address(filler)), 0);
        _start(aTeam, bTeam);
        _turn0();

        assertLt(engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.Attack), 0, "mirror slot debuffed");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Attack), 0, "other slot untouched");
    }
}
