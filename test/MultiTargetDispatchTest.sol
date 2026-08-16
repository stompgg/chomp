// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {IMatchmaker} from "../src/matchmaker/IMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";

import {defaultBattle, sideWord, targetBits} from "./abstract/SlotWire.sol";
import {SpreadAttack} from "./mocks/SpreadAttack.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @notice Engine.dispatchCustomAttackMulti — the spread variant that honors `targetBits` as a full
///         slot mask. Single-target dispatch is untouched by that addition; these pin the new path's
///         target resolution, skip rules, per-target rolls and game-over bail.
contract MultiTargetDispatchTest is Test {
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);

    // Absolute slots
    uint256 constant A0 = 0;
    uint256 constant A1 = 1;
    uint256 constant B0 = 2;
    uint256 constant B1 = 3;

    // Atk 10 into Def 10 at BP 10 with volatility 0 => 10 damage, absent a crit.
    int32 constant BASE_HIT = 10;

    // critRate 0 still crits when critRoll % 100 == 0 (~1%), so the rng-neutral comparisons below
    // need a salt where neither dispatch path crits. Found offline by probing the engine's stream;
    // hardcoded so the test carries no search loop.
    uint104 constant NO_CRIT_SALT = 1;

    Engine engine;
    TestTeamRegistry registry;
    TestTypeCalculator typeCalc;
    IMoveSet spread; // BP 10, acc 100, vol 0, crit 0 — multi
    IMoveSet single; // identical, single-target
    IMoveSet spreadVolatile; // BP 10, acc 100, vol 10 — multi
    IMoveSet spreadCoinflip; // BP 10, acc 50, vol 0 — multi
    IMoveSet spreadLethal; // BP 500, acc 100, vol 0 — multi
    bytes32 battleKey;

    function setUp() public {
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        registry = new TestTeamRegistry();
        typeCalc = new TestTypeCalculator();

        spread = _mk(10, 100, 0, true);
        single = _mk(10, 100, 0, false);
        spreadVolatile = _mk(10, 100, DEFAULT_VOL, true);
        spreadCoinflip = _mk(10, 50, 0, true);
        spreadLethal = _mk(500, 100, 0, true);

        address[] memory toAdd = new address[](1);
        toAdd[0] = address(this);
        vm.prank(ALICE);
        engine.updateMatchmakers(toAdd, new address[](0));
        vm.prank(BOB);
        engine.updateMatchmakers(toAdd, new address[](0));
    }

    function _mk(uint32 basePower, uint32 accuracy, uint256 volatility, bool useMulti) internal returns (IMoveSet) {
        return IMoveSet(
            address(
                new SpreadAttack(
                    SpreadAttack.Args({
                        TYPE: Type.Air,
                        MOVE_CLASS: MoveClass.Physical,
                        BASE_POWER: basePower,
                        ACCURACY: accuracy,
                        VOLATILITY: volatility,
                        CRIT_RATE: 0,
                        STAMINA_COST: 1,
                        USE_MULTI: useMulti
                    })
                )
            )
        );
    }

    function _mkMon(uint32 hp, uint32 speed, uint32 attack, IMoveSet move0) internal pure returns (Mon memory mon) {
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(move0)));
        mon = Mon({
            stats: MonStats({
                hp: hp,
                stamina: 5,
                speed: speed,
                attack: attack,
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

    function _startDoubles(Mon[] memory aTeam, Mon[] memory bTeam) internal {
        registry.setTeam(ALICE, aTeam);
        registry.setTeam(BOB, bTeam);
        Battle memory battle = defaultBattle(ALICE, BOB, registry, address(this), IMatchmaker(address(this)));
        (battleKey,) = engine.computeBattleKey(ALICE, BOB);
        engine.startBattleWithMode(battle, BATTLE_MODE_DOUBLES);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _side(uint8 m0, uint16 e0, uint8 m1, uint16 e1) internal pure returns (uint256) {
        return sideWord(m0, e0, m1, e1, NO_CRIT_SALT);
    }

    function _rest() internal pure returns (uint256) {
        return sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, NO_CRIT_SALT);
    }

    function _turn0Leads() internal {
        engine.executeWithSlotMoves(
            battleKey,
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, NO_CRIT_SALT),
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, NO_CRIT_SALT)
        );
    }

    function _hp(uint256 side, uint256 mon) internal view returns (int32) {
        return engine.getMonStateForBattle(battleKey, side, mon, MonStateIndexName.Hp);
    }

    /// Four 1000 HP mons, A0 carrying `aLead`, everyone else inert.
    function _standardField(IMoveSet aLead) internal {
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, aLead);
        aTeam[1] = _mkMon(1000, 30, 10, single);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(1000, 20, 10, single);
        bTeam[1] = _mkMon(1000, 10, 10, single);
        _startDoubles(aTeam, bTeam);
        _turn0Leads();
    }

    // ---------------------------------------------------------------------
    // Equivalence with the single-target path
    // ---------------------------------------------------------------------

    /// @dev The guardrail. Multi with a one-bit mask must resolve the same target and land the same
    ///      damage as dispatchCustomAttack with that bit. The two paths derive their combat hash
    ///      differently by design (multi folds the slot in so spread targets roll independently), so
    ///      this runs rng-neutral — volatility 0, accuracy 100, non-critting salt — to isolate target
    ///      resolution, context building, type scaling and damage application.
    function test_multi_singleBitMask_matchesSingleTargetDispatch() public {
        _standardField(spread);
        engine.executeWithSlotMoves(battleKey, _side(0, targetBits(B0), NO_OP_MOVE_INDEX, 0), _rest());
        int32 multiDamage = _hp(1, 0);
        assertEq(multiDamage, -BASE_HIT, "spread path, one target");
        assertEq(_hp(1, 1), 0, "no bleed onto the unmasked slot");

        _standardField(single);
        engine.executeWithSlotMoves(battleKey, _side(0, targetBits(B0), NO_OP_MOVE_INDEX, 0), _rest());
        assertEq(_hp(1, 0), multiDamage, "single-target path lands identical damage");
        assertEq(_hp(1, 1), 0, "no bleed onto the unmasked slot");
    }

    // ---------------------------------------------------------------------
    // Mask handling
    // ---------------------------------------------------------------------

    /// @dev The whole point: every set bit takes a hit, including the attacker's own side.
    function test_multi_hitsEverySetSlot() public {
        _standardField(spread);
        uint16 all = targetBits(A0) | targetBits(A1) | targetBits(B0) | targetBits(B1);
        engine.executeWithSlotMoves(battleKey, _side(0, all, NO_OP_MOVE_INDEX, 0), _rest());

        assertEq(_hp(0, 0), -BASE_HIT, "attacker hits itself when masked");
        assertEq(_hp(0, 1), -BASE_HIT, "ally hit");
        assertEq(_hp(1, 0), -BASE_HIT, "opposing slot 0 hit");
        assertEq(_hp(1, 1), -BASE_HIT, "opposing slot 1 hit");
    }

    /// @dev A partial mask must leave unmasked slots untouched.
    function test_multi_partialMaskSkipsUnmaskedSlots() public {
        _standardField(spread);
        engine.executeWithSlotMoves(
            battleKey, _side(0, targetBits(B0) | targetBits(B1), NO_OP_MOVE_INDEX, 0), _rest()
        );

        assertEq(_hp(1, 0), -BASE_HIT, "masked");
        assertEq(_hp(1, 1), -BASE_HIT, "masked");
        assertEq(_hp(0, 0), 0, "unmasked attacker untouched");
        assertEq(_hp(0, 1), 0, "unmasked ally untouched");
    }

    /// @dev An empty mask is a no-op, not a revert.
    function test_multi_emptyMaskIsNoOp() public {
        _standardField(spread);
        engine.executeWithSlotMoves(battleKey, _side(0, 0, NO_OP_MOVE_INDEX, 0), _rest());

        assertEq(_hp(0, 0), 0, "nothing hit");
        assertEq(_hp(0, 1), 0, "nothing hit");
        assertEq(_hp(1, 0), 0, "nothing hit");
        assertEq(_hp(1, 1), 0, "nothing hit");
    }

    /// @dev A side fielding one mon leaves its slot-1 lane empty; the sweep must skip that lane and
    ///      still hit the rest of the mask.
    function test_multi_skipsEmptyLane() public {
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, spread);
        aTeam[1] = _mkMon(1000, 30, 10, single);
        Mon[] memory bTeam = new Mon[](1);
        bTeam[0] = _mkMon(1000, 20, 10, single);
        _startDoubles(aTeam, bTeam);
        engine.executeWithSlotMoves(
            battleKey,
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, NO_CRIT_SALT),
            sideWord(SWITCH_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, NO_CRIT_SALT)
        );
        assertEq(engine.getActiveSlots(battleKey)[B1], EMPTY_ACTIVE_LANE, "B1 lane is empty");

        uint16 all = targetBits(A0) | targetBits(A1) | targetBits(B0) | targetBits(B1);
        engine.executeWithSlotMoves(
            battleKey, _side(0, all, NO_OP_MOVE_INDEX, 0), sideWord(NO_OP_MOVE_INDEX, 0, 0, 0, NO_CRIT_SALT)
        );

        assertEq(_hp(0, 0), -BASE_HIT, "occupied lanes still hit");
        assertEq(_hp(0, 1), -BASE_HIT, "occupied lanes still hit");
        assertEq(_hp(1, 0), -BASE_HIT, "occupied lanes still hit");
    }

    // ---------------------------------------------------------------------
    // Per-target rolls
    // ---------------------------------------------------------------------

    /// @dev Targets must not share one roll. With volatility the four hits land on at least two
    ///      distinct damage values; a shared hash would make them uniform.
    function test_multi_targetsRollIndependently() public {
        _standardField(spreadVolatile);
        uint16 all = targetBits(A0) | targetBits(A1) | targetBits(B0) | targetBits(B1);
        engine.executeWithSlotMoves(battleKey, _side(0, all, NO_OP_MOVE_INDEX, 0), _rest());

        int32 d0 = _hp(0, 0);
        int32 d1 = _hp(0, 1);
        int32 d2 = _hp(1, 0);
        int32 d3 = _hp(1, 1);
        assertTrue(d0 < 0 && d1 < 0 && d2 < 0 && d3 < 0, "all four took damage");
        assertTrue(d0 != d1 || d0 != d2 || d0 != d3, "volatility rolls are not shared across slots");
    }

    /// @dev Accuracy is rolled per target, so a coinflip spread must be able to split hit and miss
    ///      within one cast.
    function test_multi_accuracyRolledPerTarget() public {
        _standardField(spreadCoinflip);
        uint16 all = targetBits(A0) | targetBits(A1) | targetBits(B0) | targetBits(B1);
        engine.executeWithSlotMoves(battleKey, _side(0, all, NO_OP_MOVE_INDEX, 0), _rest());

        uint256 hits;
        if (_hp(0, 0) < 0) hits++;
        if (_hp(0, 1) < 0) hits++;
        if (_hp(1, 0) < 0) hits++;
        if (_hp(1, 1) < 0) hits++;
        assertTrue(hits > 0 && hits < 4, "a 50% spread split hit and miss across slots");
    }

    // ---------------------------------------------------------------------
    // KO and game-over handling
    // ---------------------------------------------------------------------

    /// @dev A mon already KO'd when the sweep runs must be skipped rather than hit again.
    function test_multi_skipsAlreadyKOdTarget() public {
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, spread); // slowest of side 0's actors
        aTeam[1] = _mkMon(1000, 50, 10, spreadLethal); // acts first, kills B1
        Mon[] memory bTeam = new Mon[](3);
        bTeam[0] = _mkMon(1000, 20, 10, single);
        bTeam[1] = _mkMon(100, 10, 10, single); // dies to A1
        bTeam[2] = _mkMon(1000, 5, 10, single);
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        uint16 all = targetBits(B0) | targetBits(B1);
        engine.executeWithSlotMoves(
            battleKey, _side(0, all, 0, targetBits(B1)), sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, NO_CRIT_SALT)
        );

        assertTrue(
            engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.IsKnockedOut) != 0, "B1 was KO'd this turn"
        );
        // The lethal hit alone; a sweep that failed to skip the corpse would read -510.
        assertEq(_hp(1, 1), -500, "KO'd mon took no further damage from the later sweep");
        assertEq(_hp(1, 0), -BASE_HIT, "the live target still took its hit");
    }

    /// @dev When a sweep hit ends the battle, the remaining targets must not be processed.
    function test_multi_stopsOnceBattleIsOver() public {
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, spreadLethal);
        aTeam[1] = _mkMon(1000, 30, 10, single);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(100, 20, 10, single);
        bTeam[1] = _mkMon(100, 10, 10, single);
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        uint16 all = targetBits(B0) | targetBits(B1);
        engine.executeWithSlotMoves(
            battleKey, _side(0, all, NO_OP_MOVE_INDEX, 0), sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, NO_CRIT_SALT)
        );

        assertEq(engine.getWinner(battleKey), ALICE, "sweep ended the battle");
    }
}
