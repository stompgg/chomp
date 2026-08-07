// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {Engine} from "../../src/Engine.sol";
import {IEngine} from "../../src/IEngine.sol";
import {BlessedStatus} from "../../src/effects/status/BlessedStatus.sol";
import {IMatchmaker} from "../../src/matchmaker/IMatchmaker.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

import {ChosenOne} from "../../src/mons/glob/ChosenOne.sol";
import {GetSlippery} from "../../src/mons/glob/GetSlippery.sol";
import {HolyMolt} from "../../src/mons/glob/HolyMolt.sol";

import {defaultBattle, sideWord, targetBits} from "../abstract/SlotWire.sol";
import {CustomAttack} from "../mocks/CustomAttack.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

contract GlobTest is Test {
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);

    uint256 constant A0 = 0;
    uint256 constant B0 = 2;

    Engine engine;
    TestTeamRegistry registry;
    TestTypeCalculator typeCalc;
    BlessedStatus blessed;
    HolyMolt holyMolt;
    GetSlippery getSlippery;
    ChosenOne chosenOne;
    IMoveSet filler;
    bytes32 battleKey;

    function setUp() public {
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        registry = new TestTeamRegistry();
        typeCalc = new TestTypeCalculator();
        blessed = new BlessedStatus();
        holyMolt = new HolyMolt(blessed);
        getSlippery = new GetSlippery();
        chosenOne = new ChosenOne(blessed);
        filler = new CustomAttack(
            typeCalc,
            CustomAttack.Args({
                TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: DEFAULT_PRIORITY
            })
        );

        address[] memory toAdd = new address[](1);
        toAdd[0] = address(this);
        vm.prank(ALICE);
        engine.updateMatchmakers(toAdd, new address[](0));
        vm.prank(BOB);
        engine.updateMatchmakers(toAdd, new address[](0));
    }

    function _mkMon(uint32 hp, uint32 speed, IMoveSet move0, address ability) internal pure returns (Mon memory mon) {
        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(move0)));
        moves[1] = 0;
        mon = Mon({
            stats: MonStats({
                hp: hp,
                stamina: 5,
                speed: speed,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Liquid,
                type2: Type.Faith
            }),
            ability: uint256(uint160(ability)),
            moves: moves
        });
    }

    function _mkMonWithSecond(uint32 hp, uint32 speed, IMoveSet move0, IMoveSet move1, address ability)
        internal
        pure
        returns (Mon memory mon)
    {
        mon = _mkMon(hp, speed, move0, ability);
        mon.moves[1] = uint256(uint160(address(move1)));
    }

    function _start(Mon[] memory aTeam, Mon[] memory bTeam) internal {
        registry.setTeam(ALICE, aTeam);
        registry.setTeam(BOB, bTeam);
        Battle memory battle = defaultBattle(ALICE, BOB, registry, address(this), IMatchmaker(address(this)));
        (battleKey,) = engine.computeBattleKey(ALICE, BOB);
        engine.startBattleWithMode(battle, BATTLE_MODE_DOUBLES);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// Glob acts from slot 0; its ally idles in slot 1.
    function _side(uint8 m, uint16 e) internal pure returns (uint256) {
        return sideWord(m, e, NO_OP_MOVE_INDEX, 0, uint104(1));
    }

    function _turn0Leads() internal {
        engine.executeWithSlotMoves(
            battleKey,
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, uint104(1)),
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, uint104(1))
        );
    }

    function _hp(uint256 side, uint256 mon) internal view returns (int32) {
        return engine.getMonStateForBattle(battleKey, side, mon, MonStateIndexName.Hp);
    }

    function _stamina(uint256 side, uint256 mon) internal view returns (int32) {
        return engine.getMonStateForBattle(battleKey, side, mon, MonStateIndexName.Stamina);
    }

    /// Glob leads slot 0 with `globMove`; Bob is inert. Mon 2 is the bench for switch tests.
    function _standardField(IMoveSet globMove) internal {
        Mon[] memory aTeam = new Mon[](3);
        aTeam[0] = _mkMon(1000, 100, globMove, address(chosenOne));
        aTeam[1] = _mkMon(1000, 50, filler, address(0));
        aTeam[2] = _mkMon(1000, 40, filler, address(0));
        Mon[] memory bTeam = new Mon[](3);
        bTeam[0] = _mkMon(1000, 10, filler, address(0));
        bTeam[1] = _mkMon(1000, 8, filler, address(0));
        bTeam[2] = _mkMon(1000, 5, filler, address(0));
        _start(aTeam, bTeam);
        _turn0Leads();
    }

    // ---------------------------------------------------------------------
    // Chosen One
    // ---------------------------------------------------------------------

    /// @dev Blessed on the first entry. The ability is not @inline-ability tagged — it applies a
    ///      different effect than itself, so the inline path could not express it.
    function test_chosenOne_blessesOnFirstSwitchIn() public {
        _standardField(filler);
        (bool exists,,) = engine.getEffectData(battleKey, 0, 0, address(blessed));
        assertTrue(exists, "Glob entered Blessed");
    }

    /// @dev Once per battle: a second entry must not re-bless.
    function test_chosenOne_doesNotRearmOnLaterSwitchIn() public {
        _standardField(filler);

        // Spend the blessing on an incoming hit, then cycle Glob out and back.
        engine.executeWithSlotMoves(battleKey, _side(NO_OP_MOVE_INDEX, 0), _side(0, targetBits(A0)));
        (bool spent,,) = engine.getEffectData(battleKey, 0, 0, address(blessed));
        assertFalse(spent, "blessing absorbed the hit and cleared");

        engine.executeWithSlotMoves(battleKey, _side(SWITCH_MOVE_INDEX, 2), _side(NO_OP_MOVE_INDEX, 0));
        engine.executeWithSlotMoves(battleKey, _side(SWITCH_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0));

        (bool exists,,) = engine.getEffectData(battleKey, 0, 0, address(blessed));
        assertFalse(exists, "Chosen One is once per battle");
    }

    // ---------------------------------------------------------------------
    // Holy Molt
    // ---------------------------------------------------------------------

    /// @dev Free on the first cast, then +1 stamina per cast, capped.
    function test_holyMolt_staminaCostEscalatesToCap() public {
        _standardField(IMoveSet(address(holyMolt)));

        assertEq(holyMolt.stamina(IEngine(address(engine)), battleKey, 0, 0), 0, "first cast is free");
        engine.executeWithSlotMoves(battleKey, _side(0, 0), _side(NO_OP_MOVE_INDEX, 0));
        assertEq(holyMolt.stamina(IEngine(address(engine)), battleKey, 0, 0), 1, "second cast costs 1");
        engine.executeWithSlotMoves(battleKey, _side(0, 0), _side(NO_OP_MOVE_INDEX, 0));
        assertEq(holyMolt.stamina(IEngine(address(engine)), battleKey, 0, 0), 2, "third cast costs 2");
        engine.executeWithSlotMoves(battleKey, _side(0, 0), _side(NO_OP_MOVE_INDEX, 0));
        assertEq(holyMolt.stamina(IEngine(address(engine)), battleKey, 0, 0), 3, "fourth cast costs 3");
        engine.executeWithSlotMoves(battleKey, _side(0, 0), _side(NO_OP_MOVE_INDEX, 0));
        assertEq(
            holyMolt.stamina(IEngine(address(engine)), battleKey, 0, 0), 3, "cost caps at MAX_STAMINA_COST"
        );
    }

    /// @dev The counter is battle-scoped, not switch-in-scoped.
    function test_holyMolt_costPersistsAcrossSwitchOut() public {
        _standardField(IMoveSet(address(holyMolt)));
        engine.executeWithSlotMoves(battleKey, _side(0, 0), _side(NO_OP_MOVE_INDEX, 0));
        assertEq(holyMolt.stamina(IEngine(address(engine)), battleKey, 0, 0), 1, "one cast spent");

        engine.executeWithSlotMoves(battleKey, _side(SWITCH_MOVE_INDEX, 2), _side(NO_OP_MOVE_INDEX, 0));
        engine.executeWithSlotMoves(battleKey, _side(SWITCH_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0));

        assertEq(holyMolt.stamina(IEngine(address(engine)), battleKey, 0, 0), 1, "cost survives a bench cycle");
    }

    /// @dev Halves current HP, so repeated casts can never self-KO.
    function test_holyMolt_halvesCurrentHpAndCannotSelfKO() public {
        _standardField(IMoveSet(address(holyMolt)));

        engine.executeWithSlotMoves(battleKey, _side(0, 0), _side(NO_OP_MOVE_INDEX, 0));
        assertEq(_hp(0, 0), -500, "first molt halves 1000");
        engine.executeWithSlotMoves(battleKey, _side(0, 0), _side(NO_OP_MOVE_INDEX, 0));
        assertEq(_hp(0, 0), -750, "second molt halves the remaining 500");

        // Drive it down until integer division would floor to zero.
        for (uint256 i; i < 12; i++) {
            engine.executeWithSlotMoves(battleKey, _side(0, 0), _side(NO_OP_MOVE_INDEX, 0));
        }
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut), 0, "Holy Molt cannot self-KO"
        );
        assertTrue(engine.getMonCurrentValue(battleKey, 0, 0, MonStateIndexName.Hp) > 0, "always leaves at least 1 HP");
    }

    /// @dev Re-blessing while already Blessed is an engine-level no-op (status lane gate), but the
    ///      cast still costs its stamina and still sheds HP.
    function test_holyMolt_recastWhileBlessedStillCosts() public {
        _standardField(IMoveSet(address(holyMolt)));
        (bool blessedAtStart,,) = engine.getEffectData(battleKey, 0, 0, address(blessed));
        assertTrue(blessedAtStart, "Chosen One blessing is up");

        engine.executeWithSlotMoves(battleKey, _side(0, 0), _side(NO_OP_MOVE_INDEX, 0));
        (bool stillBlessed,,) = engine.getEffectData(battleKey, 0, 0, address(blessed));
        assertTrue(stillBlessed, "still exactly one blessing");
        assertEq(_hp(0, 0), -500, "HP cost still paid");
    }

    // ---------------------------------------------------------------------
    // Get Slippery
    // ---------------------------------------------------------------------

    function test_getSlippery_boostsAttackAndSpeed() public {
        Mon[] memory aTeam = new Mon[](3);
        aTeam[0] = _mkMonWithSecond(1000, 100, IMoveSet(address(getSlippery)), filler, address(chosenOne));
        aTeam[1] = _mkMon(1000, 50, filler, address(0));
        aTeam[2] = _mkMon(1000, 40, filler, address(0));
        Mon[] memory bTeam = new Mon[](3);
        bTeam[0] = _mkMon(1000, 10, filler, address(0));
        bTeam[1] = _mkMon(1000, 8, filler, address(0));
        bTeam[2] = _mkMon(1000, 5, filler, address(0));
        _start(aTeam, bTeam);
        _turn0Leads();

        engine.executeWithSlotMoves(battleKey, _side(0, 0), _side(NO_OP_MOVE_INDEX, 0));

        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack), 50, "+50% of Atk 100");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Speed), 50, "+50% of Speed 100");
        assertEq(_stamina(0, 0), -2, "costs 2 stamina");
    }
}
