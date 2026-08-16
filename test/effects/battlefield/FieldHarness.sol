// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/Constants.sol";
import "../../../src/Enums.sol";
import "../../../src/Structs.sol";

import {DefaultRuleset} from "../../../src/DefaultRuleset.sol";
import {Engine} from "../../../src/Engine.sol";
import {IRuleset} from "../../../src/IRuleset.sol";
import {IEffect} from "../../../src/effects/IEffect.sol";
import {IMatchmaker} from "../../../src/matchmaker/IMatchmaker.sol";
import {IMoveSet} from "../../../src/moves/IMoveSet.sol";

import {defaultBattle, sideWord, targetBits} from "../../abstract/SlotWire.sol";
import {CustomAttack} from "../../mocks/CustomAttack.sol";
import {TestTeamRegistry} from "../../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../../mocks/TestTypeCalculator.sol";

/// @dev Shared plumbing for the battlefield-field tests: this contract is both the matchmaker and
///      the move manager, so every turn's salts (and therefore the field rng) are chosen directly.
///      Mock mons only — these are engine-level tests.
abstract contract FieldHarness is Test {
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);
    address constant CARL = address(0x3);
    address constant DAVE = address(0x4);

    // Absolute slots
    uint256 constant A0 = 0;
    uint256 constant A1 = 1;
    uint256 constant B0 = 2;
    uint256 constant B1 = 3;

    Engine engine;
    TestTeamRegistry registry;
    TestTypeCalculator typeCalc;
    IMoveSet weakAttack; // BP 10, 1 stamina
    IMoveSet killAttack; // BP 1000, 1 stamina
    IMoveSet costlyAttack; // BP 10, 2 stamina — separates the two inline-regen halves
    bytes32 battleKey;

    function _setUpHarness() internal {
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
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
                TYPE: Type.Fire, BASE_POWER: 1000, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: DEFAULT_PRIORITY
            })
        );

        costlyAttack = new CustomAttack(
            typeCalc,
            CustomAttack.Args({
                TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 2, PRIORITY: DEFAULT_PRIORITY
            })
        );

        address[] memory toAdd = new address[](1);
        toAdd[0] = address(this);
        address[4] memory seats = [ALICE, BOB, CARL, DAVE];
        for (uint256 i; i < 4; ++i) {
            vm.prank(seats[i]);
            engine.updateMatchmakers(toAdd, new address[](0));
        }
    }

    /// @dev A ruleset carrying `field` plus the inline-regen marker the field ships with.
    function _ruleset(IEffect field, address regenMarker) internal returns (IRuleset) {
        IEffect[] memory effects = new IEffect[](2);
        effects[0] = IEffect(regenMarker);
        effects[1] = field;
        return new DefaultRuleset(engine, effects);
    }

    function _mkMon(uint32 hp, uint32 stamina, uint32 speed, IMoveSet move0) internal pure returns (Mon memory mon) {
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(move0)));
        mon = Mon({
            stats: MonStats({
                hp: hp,
                stamina: stamina,
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

    function _mkTeam(uint256 size, uint32 hp, uint32 stamina, uint32 speed, IMoveSet move0)
        internal
        pure
        returns (Mon[] memory team)
    {
        team = new Mon[](size);
        for (uint256 i; i < size; ++i) {
            team[i] = _mkMon(hp, stamina, speed, move0);
        }
    }

    function _battle(address p0, address p1, IRuleset ruleset) internal view returns (Battle memory battle) {
        battle = defaultBattle(p0, p1, registry, address(this), IMatchmaker(address(this)));
        battle.ruleset = ruleset;
    }

    function _startSingles(Mon[] memory aTeam, Mon[] memory bTeam, IRuleset ruleset) internal {
        registry.setTeam(ALICE, aTeam);
        registry.setTeam(BOB, bTeam);
        (battleKey,) = engine.computeBattleKey(ALICE, BOB);
        engine.startBattle(_battle(ALICE, BOB, ruleset));
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _startDoubles(Mon[] memory aTeam, Mon[] memory bTeam, IRuleset ruleset) internal {
        registry.setTeam(ALICE, aTeam);
        registry.setTeam(BOB, bTeam);
        (battleKey,) = engine.computeBattleKey(ALICE, BOB);
        engine.startBattleWithMode(_battle(ALICE, BOB, ruleset), BATTLE_MODE_DOUBLES);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev Multi seats each bring their own 4-mon team; side 0 = ALICE + CARL, side 1 = BOB + DAVE.
    function _startMulti(IRuleset ruleset) internal {
        registry.setTeam(ALICE, _mkTeam(4, 1000, 5, 40, weakAttack));
        registry.setTeam(CARL, _mkTeam(4, 1000, 5, 30, weakAttack));
        registry.setTeam(BOB, _mkTeam(4, 1000, 5, 20, weakAttack));
        registry.setTeam(DAVE, _mkTeam(4, 1000, 5, 10, weakAttack));
        Battle memory battle = _battle(ALICE, BOB, ruleset);
        battle.p2 = CARL;
        battle.p3 = DAVE;
        (battleKey,) = engine.computePartyKey(ALICE, BOB, CARL, DAVE);
        engine.startBattleWithMode(battle, BATTLE_MODE_MULTI);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // --- turn drivers -----------------------------------------------------

    function _singlesTurn(uint8 aMove, uint16 aExtra, uint104 aSalt, uint8 bMove, uint16 bExtra, uint104 bSalt)
        internal
    {
        engine.executeWithMoves(battleKey, aMove, aSalt, aExtra, bMove, bSalt, bExtra);
    }

    /// @dev Singles turn 0: both sides send in roster mon 0.
    function _singlesLeads(uint104 salt) internal {
        _singlesTurn(SWITCH_MOVE_INDEX, 0, salt, SWITCH_MOVE_INDEX, 0, 0);
    }

    function _slotTurn(uint256 side0, uint256 side1) internal {
        engine.executeWithSlotMoves(battleKey, side0, side1);
    }

    /// @dev 2-slot turn 0: each slot sends in the lead of its own roster range.
    function _slotLeads(uint256 slot1Mon, uint104 salt) internal {
        _slotTurn(
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, uint16(slot1Mon), salt),
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, uint16(slot1Mon), 0)
        );
    }

    /// @dev Every slot rests, with side 0 carrying the turn salt.
    function _restTurn(uint104 salt) internal {
        _slotTurn(
            sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, salt),
            sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, 0)
        );
    }

    // --- reads ------------------------------------------------------------

    function _statusClass(uint256 side, uint256 monIndex) internal view returns (uint256) {
        return engine.getMonStatusClass(battleKey, side, monIndex);
    }

    function _stamina(uint256 side, uint256 monIndex) internal view returns (int32) {
        return engine.getMonStateForBattle(battleKey, side, monIndex, MonStateIndexName.Stamina);
    }

    function _active(uint256 absSlot) internal view returns (uint256) {
        return engine.getActiveSlots(battleKey)[absSlot];
    }
}
