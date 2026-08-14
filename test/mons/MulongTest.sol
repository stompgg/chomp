// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {Engine} from "../../src/Engine.sol";
import {IEngine} from "../../src/IEngine.sol";
import {Storm} from "../../src/effects/battlefield/Storm.sol";
import {FrostbiteStatus} from "../../src/effects/status/FrostbiteStatus.sol";
import {IMatchmaker} from "../../src/matchmaker/IMatchmaker.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

import {CloudStrike} from "../../src/mons/mulong/CloudStrike.sol";
import {KingsLeisure} from "../../src/mons/mulong/KingsLeisure.sol";
import {KingsRespite} from "../../src/mons/mulong/KingsRespite.sol";
import {SummonStorm} from "../../src/mons/mulong/SummonStorm.sol";

import {defaultBattle, sideWord, targetBits} from "../abstract/SlotWire.sol";
import {CustomAttack} from "../mocks/CustomAttack.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

contract MulongTest is Test {
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);

    uint256 constant A0 = 0;
    uint256 constant A1 = 1;
    uint256 constant B0 = 2;
    uint256 constant B1 = 3;

    Engine engine;
    TestTeamRegistry registry;
    TestTypeCalculator typeCalc;
    Storm storm;
    FrostbiteStatus frostbite;
    SummonStorm summonStorm;
    KingsRespite kingsRespite;
    CloudStrike cloudStrike;
    KingsLeisure kingsLeisure;
    IMoveSet filler; // BP 40 Fire physical
    bytes32 battleKey;

    function setUp() public {
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        registry = new TestTeamRegistry();
        typeCalc = new TestTypeCalculator();
        storm = new Storm();
        frostbite = new FrostbiteStatus();
        summonStorm = new SummonStorm(storm);
        kingsRespite = new KingsRespite(typeCalc);
        cloudStrike = new CloudStrike(storm, frostbite);
        kingsLeisure = new KingsLeisure();
        filler = new CustomAttack(
            typeCalc,
            CustomAttack.Args({
                TYPE: Type.Fire, BASE_POWER: 40, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: DEFAULT_PRIORITY
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
        mon = Mon({
            stats: MonStats({
                hp: hp,
                stamina: 5,
                speed: speed,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Air,
                type2: Type.None
            }),
            ability: uint256(uint160(ability)),
            moves: moves
        });
    }

    function _withSecond(Mon memory mon, IMoveSet move1) internal pure returns (Mon memory) {
        mon.moves[1] = uint256(uint160(address(move1)));
        return mon;
    }

    function _start(Mon[] memory aTeam, Mon[] memory bTeam) internal {
        registry.setTeam(ALICE, aTeam);
        registry.setTeam(BOB, bTeam);
        Battle memory battle = defaultBattle(ALICE, BOB, registry, address(this), IMatchmaker(address(this)));
        (battleKey,) = engine.computeBattleKey(ALICE, BOB);
        engine.startBattleWithMode(battle, BATTLE_MODE_DOUBLES);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _side(uint8 m0, uint16 e0, uint8 m1, uint16 e1) internal pure returns (uint256) {
        return sideWord(m0, e0, m1, e1, uint104(1));
    }

    function _rest() internal pure returns (uint256) {
        return _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0);
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

    function _stormIsUp() internal view returns (bool up) {
        (up,,) = engine.getEffectData(battleKey, 2, 2, address(storm));
    }

    /// Mulong leads side 0 slot 0 with `mulongMove` and the given ability; everyone else is inert.
    function _field(IMoveSet mulongMove, address ability) internal {
        Mon[] memory aTeam = new Mon[](3);
        aTeam[0] = _mkMon(2000, 100, mulongMove, ability);
        aTeam[1] = _mkMon(2000, 50, filler, address(0));
        aTeam[2] = _mkMon(2000, 40, filler, address(0));
        Mon[] memory bTeam = new Mon[](3);
        bTeam[0] = _mkMon(2000, 10, filler, address(0));
        bTeam[1] = _mkMon(2000, 8, filler, address(0));
        bTeam[2] = _mkMon(2000, 5, filler, address(0));
        _start(aTeam, bTeam);
        _turn0Leads();
    }

    // ---------------------------------------------------------------------
    // King's Leisure
    // ---------------------------------------------------------------------

    /// @dev The outgoing half is a flat ATK/SpATK debuff, applied once on the first entry.
    function test_kingsLeisure_appliesAttackDebuffOnFirstEntry() public {
        _field(filler, address(kingsLeisure));
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack), -50, "ATK halved");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack), -50, "SpATK halved");
    }

    /// @dev The incoming half is a PreDamage hook. B0 hits Mulong for BP 40 into Def 100 = 40 raw,
    ///      halved to 20 while the window is up.
    function test_kingsLeisure_halvesIncomingDamage() public {
        _field(filler, address(kingsLeisure));
        engine.executeWithSlotMoves(battleKey, _rest(), _side(0, targetBits(A0), NO_OP_MOVE_INDEX, 0));
        assertEq(_hp(0, 0), -20, "incoming damage halved");
    }

    /// @dev Three active rounds, then both halves lapse together.
    function test_kingsLeisure_expiresAfterThreeActiveRounds() public {
        _field(filler, address(kingsLeisure));

        for (uint256 i; i < 3; i++) {
            engine.executeWithSlotMoves(battleKey, _rest(), _rest());
        }
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack), 0, "ATK debuff cleared at expiry"
        );
        (bool exists,,) = engine.getEffectData(battleKey, 0, 0, address(kingsLeisure));
        assertFalse(exists, "window closed");

        engine.executeWithSlotMoves(battleKey, _rest(), _side(0, targetBits(A0), NO_OP_MOVE_INDEX, 0));
        assertEq(_hp(0, 0), -40, "full damage once the window lapses");
    }

    /// @dev The countdown only advances on rounds Mulong is active, and the Perm debuff rides
    ///      through the bench rather than being dropped and re-applied. Turn 0 consumes the first
    ///      of the three, so leaving immediately after it banks the other two.
    function test_kingsLeisure_pausesWhileBenched() public {
        _field(filler, address(kingsLeisure));

        // Mulong is benched at every RoundEnd below, so none of these rounds tick the clock.
        engine.executeWithSlotMoves(battleKey, _side(SWITCH_MOVE_INDEX, 2, NO_OP_MOVE_INDEX, 0), _rest());
        engine.executeWithSlotMoves(battleKey, _rest(), _rest());
        engine.executeWithSlotMoves(battleKey, _rest(), _rest());
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack), -50, "Perm debuff survives benching"
        );

        // Back in with 2 rounds still banked: one more active round must not close the window.
        engine.executeWithSlotMoves(battleKey, _side(SWITCH_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0), _rest());
        (bool exists,,) = engine.getEffectData(battleKey, 0, 0, address(kingsLeisure));
        assertTrue(exists, "clock paused on the bench, not burned");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack), -50, "debuff still in force");
    }

    /// @dev Once spent, a later entry must not re-arm the window.
    function test_kingsLeisure_doesNotRearmAfterExpiry() public {
        _field(filler, address(kingsLeisure));
        for (uint256 i; i < 3; i++) {
            engine.executeWithSlotMoves(battleKey, _rest(), _rest());
        }

        engine.executeWithSlotMoves(battleKey, _side(SWITCH_MOVE_INDEX, 2, NO_OP_MOVE_INDEX, 0), _rest());
        engine.executeWithSlotMoves(battleKey, _side(SWITCH_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0), _rest());

        (bool exists,,) = engine.getEffectData(battleKey, 0, 0, address(kingsLeisure));
        assertFalse(exists, "once per battle");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack), 0, "no second debuff");
    }

    // ---------------------------------------------------------------------
    // Summon Storm
    // ---------------------------------------------------------------------

    /// @dev Ticks every active at end of round, the caster's own side included.
    function test_storm_damagesEveryActiveAtRoundEnd() public {
        _field(IMoveSet(address(summonStorm)), address(0));
        engine.executeWithSlotMoves(battleKey, _side(0, 0, NO_OP_MOVE_INDEX, 0), _rest());

        assertTrue(_stormIsUp(), "storm summoned");
        assertTrue(_hp(0, 0) < 0, "caster takes its own storm");
        assertTrue(_hp(0, 1) < 0, "ally hit");
        assertTrue(_hp(1, 0) < 0, "opposing slot 0 hit");
        assertTrue(_hp(1, 1) < 0, "opposing slot 1 hit");
    }

    /// @dev Runs its full duration and then lapses.
    function test_storm_expiresAfterDuration() public {
        _field(IMoveSet(address(summonStorm)), address(0));
        engine.executeWithSlotMoves(battleKey, _side(0, 0, NO_OP_MOVE_INDEX, 0), _rest());

        for (uint256 i; i < storm.DEFAULT_DURATION() - 1; i++) {
            assertTrue(_stormIsUp(), "storm still running");
            engine.executeWithSlotMoves(battleKey, _rest(), _rest());
        }
        assertFalse(_stormIsUp(), "storm expired");

        int32 settled = _hp(1, 0);
        engine.executeWithSlotMoves(battleKey, _rest(), _rest());
        assertEq(_hp(1, 0), settled, "no ticks after expiry");
    }

    /// @dev A recast refreshes the clock in place rather than stacking a second storm.
    function test_storm_recastRefreshesRatherThanStacking() public {
        _field(IMoveSet(address(summonStorm)), address(0));
        engine.executeWithSlotMoves(battleKey, _side(0, 0, NO_OP_MOVE_INDEX, 0), _rest());
        int32 afterOne = _hp(1, 0);

        engine.executeWithSlotMoves(battleKey, _side(0, 0, NO_OP_MOVE_INDEX, 0), _rest());
        int32 afterTwo = _hp(1, 0);
        assertEq(afterTwo - afterOne, afterOne, "one tick per round, not two");

        // Refreshed to full duration on the recast: still up a full duration later.
        for (uint256 i; i < storm.DEFAULT_DURATION() - 1; i++) {
            engine.executeWithSlotMoves(battleKey, _rest(), _rest());
        }
        assertFalse(_stormIsUp(), "expires a full duration after the recast");
    }

    /// @dev Damage scales off the latched caster's stats, so King's Leisure's debuff drags it down.
    function test_storm_scalesWithCastersDebuff() public {
        _field(IMoveSet(address(summonStorm)), address(0));
        engine.executeWithSlotMoves(battleKey, _side(0, 0, NO_OP_MOVE_INDEX, 0), _rest());
        int32 undebuffedTick = _hp(1, 0);

        _field(IMoveSet(address(summonStorm)), address(kingsLeisure));
        engine.executeWithSlotMoves(battleKey, _side(0, 0, NO_OP_MOVE_INDEX, 0), _rest());
        int32 debuffedTick = _hp(1, 0);

        assertTrue(debuffedTick > undebuffedTick, "halved SpATK weakens the storm");
    }

    // ---------------------------------------------------------------------
    // King's Respite
    // ---------------------------------------------------------------------

    /// @dev Arms silently, then detonates on the next rest — and the rest still regenerates stamina.
    function test_kingsRespite_firesOnNextRest() public {
        _field(IMoveSet(address(kingsRespite)), address(0));

        engine.executeWithSlotMoves(battleKey, _side(0, targetBits(B0), NO_OP_MOVE_INDEX, 0), _rest());
        assertEq(_hp(1, 0), 0, "arming does no damage");
        assertEq(_stamina(0, 0), -2, "arming costs 2 stamina");

        engine.executeWithSlotMoves(battleKey, _rest(), _rest());
        assertTrue(_hp(1, 0) < 0, "the rest detonated the strike");
        assertEq(_stamina(0, 0), -2, "the strike rides the rest for free");

        (bool exists,,) = engine.getEffectData(battleKey, 0, 0, address(kingsRespite));
        assertFalse(exists, "one-shot");
    }

    /// @dev Slot-bound: a replacement occupying the marked slot eats the strike. B0 outspeeds Mulong
    ///      so its switch resolves first — rest and switch share SWITCH_PRIORITY, so speed decides.
    function test_kingsRespite_followsTheLatchedSlot() public {
        Mon[] memory aTeam = new Mon[](3);
        aTeam[0] = _mkMon(2000, 100, IMoveSet(address(kingsRespite)), address(0));
        aTeam[1] = _mkMon(2000, 50, filler, address(0));
        aTeam[2] = _mkMon(2000, 40, filler, address(0));
        Mon[] memory bTeam = new Mon[](3);
        bTeam[0] = _mkMon(2000, 200, filler, address(0));
        bTeam[1] = _mkMon(2000, 8, filler, address(0));
        bTeam[2] = _mkMon(2000, 5, filler, address(0));
        _start(aTeam, bTeam);
        _turn0Leads();

        engine.executeWithSlotMoves(battleKey, _side(0, targetBits(B0), NO_OP_MOVE_INDEX, 0), _rest());
        engine.executeWithSlotMoves(battleKey, _rest(), _side(SWITCH_MOVE_INDEX, 2, NO_OP_MOVE_INDEX, 0));

        assertEq(_hp(1, 0), 0, "the mon that left is untouched");
        assertTrue(_hp(1, 2) < 0, "the replacement in the marked slot takes it");
    }

    // ---------------------------------------------------------------------
    // Cloud Strike
    // ---------------------------------------------------------------------

    /// @dev Storm raises Cloud Strike's power.
    function test_cloudStrike_strongerUnderStorm() public {
        _field(IMoveSet(address(cloudStrike)), address(0));
        engine.executeWithSlotMoves(battleKey, _side(0, targetBits(B0), NO_OP_MOVE_INDEX, 0), _rest());
        int32 plain = _hp(1, 0);
        assertTrue(plain < 0, "hit landed");

        // Same field, but with a storm up before the strike.
        Mon[] memory aTeam = new Mon[](3);
        aTeam[0] = _withSecond(_mkMon(2000, 100, IMoveSet(address(summonStorm)), address(0)), cloudStrike);
        aTeam[1] = _mkMon(2000, 50, filler, address(0));
        aTeam[2] = _mkMon(2000, 40, filler, address(0));
        Mon[] memory bTeam = new Mon[](3);
        bTeam[0] = _mkMon(2000, 10, filler, address(0));
        bTeam[1] = _mkMon(2000, 8, filler, address(0));
        bTeam[2] = _mkMon(2000, 5, filler, address(0));
        _start(aTeam, bTeam);
        _turn0Leads();

        engine.executeWithSlotMoves(battleKey, _side(0, 0, NO_OP_MOVE_INDEX, 0), _rest());
        int32 beforeStrike = _hp(1, 0);
        engine.executeWithSlotMoves(battleKey, _side(1, targetBits(B0), NO_OP_MOVE_INDEX, 0), _rest());
        int32 stormedStrikePlusTick = beforeStrike - _hp(1, 0);

        assertTrue(_stormIsUp(), "storm active for the strike");
        assertTrue(stormedStrikePlusTick > -plain, "storm-boosted Cloud Strike hits harder");
    }

    function test_cloudStrike_basePowerReflectsStorm() public {
        _field(IMoveSet(address(cloudStrike)), address(0));
        MoveMeta memory meta = cloudStrike.getMeta(IEngine(address(engine)), battleKey, 0, 0);
        assertEq(meta.basePower, cloudStrike.BASE_POWER(), "no storm");
    }
}
