// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {Engine} from "../../src/Engine.sol";
import {IMatchmaker} from "../../src/matchmaker/IMatchmaker.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

import {Q5} from "../../src/mons/embursa/Q5.sol";
import {Angery} from "../../src/mons/gorillax/Angery.sol";
import {RockPull} from "../../src/mons/gorillax/RockPull.sol";
import {HitAndDip} from "../../src/mons/inutia/HitAndDip.sol";
import {Interweaving} from "../../src/mons/inutia/Interweaving.sol";
import {CarrotHarvest} from "../../src/mons/sofabbi/CarrotHarvest.sol";
import {Somniphobia} from "../../src/mons/xmon/Somniphobia.sol";

import {defaultBattle, sideWord, targetBits} from "../abstract/SlotWire.sol";
import {CustomAttack} from "../mocks/CustomAttack.sol";
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
            defaultBattle(ALICE, BOB, registry, address(this), IMatchmaker(address(this))), BATTLE_MODE_DOUBLES
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _side(uint8 m0, uint16 e0, uint8 m1, uint16 e1) internal pure returns (uint256) {
        return sideWord(m0, e0, m1, e1, uint104(0xC0FFEE));
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
            battleKey, _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
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
            battleKey, _side(0, targetBits(3), NO_OP_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );

        // B1 pivots out: mon 2 takes the doomed slot.
        engine.executeWithSlotMoves(
            battleKey, _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 2)
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
            _side(NO_OP_MOVE_INDEX, 0, 0, targetBits(2) | uint16(2)),
            _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );

        uint256[4] memory slots = engine.getActiveSlots(battleKey);
        assertEq(slots[0], 0, "A slot 0 untouched");
        assertEq(slots[1], 2, "caster's slot pivoted to the bench mon");
        assertLt(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), 0, "target took the hit");
    }

    /// @dev Stats-variant mon (def/spDef stay 10 like _mkMon).
    function _mkMonEx(IMoveSet move0, uint256 ability, uint32 hp, uint32 attack, uint32 specialAttack)
        internal
        pure
        returns (Mon memory mon)
    {
        mon = _mkMon(move0, ability);
        mon.stats.hp = hp;
        mon.stats.attack = attack;
        mon.stats.specialAttack = specialAttack;
    }

    function _hp(uint256 side, uint256 mon) internal view returns (int32) {
        return engine.getMonStateForBattle(battleKey, side, mon, MonStateIndexName.Hp);
    }

    /// @dev Rock Pull's self-hit (target didn't switch) computes from the CASTER's own stats
    ///      via the damage-calc view path: a slot-1 Gorillax with Atk 120 self-hits for 324+,
    ///      not the slot-0 ally's Atk-10 ~30.
    function test_rockPull_slot1SelfHitUsesOwnStats() public {
        RockPull rockPull = new RockPull(typeCalc);
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(IMoveSet(address(rockPull)), 0);
        aTeam[1] = _mkMonEx(IMoveSet(address(rockPull)), 0, 1000, 120, 10);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(IMoveSet(address(rockPull)), 0);
        bTeam[1] = _mkMon(IMoveSet(address(rockPull)), 0);
        _start(aTeam, bTeam);
        _turn0();

        // A1 pulls at B0, which did NOT commit a switch -> the self-hit branch.
        engine.executeWithSlotMoves(
            battleKey, _side(NO_OP_MOVE_INDEX, 0, 0, targetBits(2)), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        assertLe(_hp(0, 1), -300, "self-hit uses the caster's own Atk");
        assertEq(_hp(0, 0), 0, "ally untouched");
        assertEq(_hp(1, 0), 0, "target untouched when it didn't switch");
    }

    /// @dev Somniphobia tags EVERY on-field opposing mon at cast, not just the chosen target;
    ///      the caster's own side is never tagged.
    function test_somniphobia_tagsBothOpposingLanesAtCast() public {
        Somniphobia somni = new Somniphobia();
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(IMoveSet(address(somni)), 0);
        aTeam[1] = _mkMon(IMoveSet(address(somni)), 0);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(IMoveSet(address(somni)), 0);
        bTeam[1] = _mkMon(IMoveSet(address(somni)), 0);
        _start(aTeam, bTeam);
        _turn0();

        engine.executeWithSlotMoves(
            battleKey, _side(0, targetBits(2), NO_OP_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        (bool onTarget,,) = engine.getEffectData(battleKey, 1, 0, address(somni));
        (bool onAlly,,) = engine.getEffectData(battleKey, 1, 1, address(somni));
        (bool onOwnSide,,) = engine.getEffectData(battleKey, 0, 1, address(somni));
        assertTrue(onTarget, "chosen target tagged");
        assertTrue(onAlly, "non-targeted opposing lane tagged at cast");
        assertFalse(onOwnSide, "caster's side never tagged");
    }

    /// @dev Q5's blast is computed from the ORIGINAL caster's stats even after it leaves the
    ///      field: caster SpAtk 150 vs replacement/ally SpAtk 10 (~2250 vs ~150 damage).
    function test_q5_detonatesWithOriginalCasterStats() public {
        Q5 q5 = new Q5(typeCalc);
        Mon[] memory aTeam = new Mon[](3);
        aTeam[0] = _mkMon(IMoveSet(address(q5)), 0);
        aTeam[1] = _mkMonEx(IMoveSet(address(q5)), 0, 1000, 10, 150); // the caster
        aTeam[2] = _mkMonEx(IMoveSet(address(q5)), 0, 1000, 10, 10); // its replacement
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMonEx(IMoveSet(address(q5)), 0, 5000, 10, 10);
        bTeam[1] = _mkMon(IMoveSet(address(q5)), 0);
        _start(aTeam, bTeam);
        _turn0();

        // A1 arms Q5 at B0, then pivots out before D-day.
        engine.executeWithSlotMoves(
            battleKey, _side(NO_OP_MOVE_INDEX, 0, 0, targetBits(2)), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        engine.executeWithSlotMoves(
            battleKey, _side(NO_OP_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 2), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        for (uint256 i; i < 4; ++i) {
            _noOpTurn();
        }

        // Special BP 150 off the caster's SpAtk 150 into SpDef 10 = ~2025..2475.
        assertLe(_hp(1, 0), -1000, "blast uses the original caster's SpAtk");
        assertEq(_hp(1, 1), 0, "untargeted slot untouched");
    }

    /// @dev Two hits in one round (routine in doubles) overshoot Angery's charge trigger; the
    ///      heal must still fire (>=) and consume all charges.
    function test_angery_doubleHitRoundHealsAndResets() public {
        Angery angery = new Angery();
        CustomAttack atk100 = new CustomAttack(
            typeCalc,
            CustomAttack.Args({
                TYPE: Type.Fire, BASE_POWER: 100, ACCURACY: 100, STAMINA_COST: 2, PRIORITY: DEFAULT_PRIORITY
            })
        );
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMonEx(IMoveSet(address(atk100)), uint256(uint160(address(angery))), 600, 10, 10); // heal 100
        aTeam[1] = _mkMon(IMoveSet(address(atk100)), 0);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(IMoveSet(address(atk100)), 0);
        bTeam[1] = _mkMon(IMoveSet(address(atk100)), 0);
        _start(aTeam, bTeam);
        _turn0();

        // Round 1: both B mons hit A0 for 100 each — 2 charges, below the trigger.
        engine.executeWithSlotMoves(
            battleKey, _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0), _side(0, targetBits(0), 0, targetBits(0))
        );
        assertEq(_hp(0, 0), -200, "no heal below the trigger");

        // Round 2: two more hits overshoot to 4 charges — the heal (maxHp/6 = 100) still fires.
        engine.executeWithSlotMoves(
            battleKey, _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0), _side(0, targetBits(0), 0, targetBits(0))
        );
        assertEq(_hp(0, 0), -300, "overshoot heal fired and charges consumed");
    }

    /// @dev Two same-side Carrot Harvests roll independent coins. Salts precomputed offline:
    ///      turn 0 (0xC0FFEE) procs mon 0 only; turn 1 (side-0 salt 12) again procs mon 0 only.
    function test_carrotHarvest_sameSideInstancesRollIndependently() public {
        CarrotHarvest carrot = new CarrotHarvest();
        uint256 carrotAbility = uint256(uint160(address(carrot)));
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(IMoveSet(address(0)), carrotAbility);
        aTeam[1] = _mkMon(IMoveSet(address(0)), carrotAbility);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(IMoveSet(address(0)), 0);
        bTeam[1] = _mkMon(IMoveSet(address(0)), 0);
        _start(aTeam, bTeam);
        _turn0();

        engine.executeWithSlotMoves(
            battleKey,
            sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, uint104(12)),
            sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, uint104(0xC0FFEE))
        );
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), 2, "mon 0 procced both rounds"
        );
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Stamina), 0, "mon 1 procced neither"
        );
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
