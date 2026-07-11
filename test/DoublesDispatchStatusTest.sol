// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {Overclock} from "../src/effects/battlefield/Overclock.sol";
import {SleepStatus} from "../src/effects/status/SleepStatus.sol";
import {ZapStatus} from "../src/effects/status/ZapStatus.sol";
import {IMatchmaker} from "../src/matchmaker/IMatchmaker.sol";
import {Gachachacha} from "../src/mons/sofabbi/Gachachacha.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {StandardAttack} from "../src/moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";

import {MoveSlotLib} from "../src/moves/MoveSlotLib.sol";

import {defaultBattle, sideWord, targetBits} from "./abstract/SlotWire.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {StatBoostsMove} from "./mocks/StatBoostsMove.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @dev Casts Overclock for the attacker's side (Overclock is applied by moves in prod kits).
contract OverclockCastMove is IMoveSet {
    Overclock immutable OC;

    constructor(Overclock oc) {
        OC = oc;
    }

    function name() external pure returns (string memory) {
        return "Overclock Cast";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256,
        uint256,
        uint256,
        uint16,
        uint256
    ) external {
        OC.applyOverclock(engine, battleKey, attackerPlayerIndex);
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 1;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Lightning;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}

/// @dev Metadata getters revert: a battle only executes with this move if the engine reads
///      the word's packed stamina/priority instead of staticcalling.
contract RevertingMetaAttack is IMoveSet {
    function name() external pure returns (string memory) {
        return "Reverting Meta";
    }

    function move(
        IEngine engine,
        bytes32,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256,
        uint16,
        uint256 rng
    ) external {
        engine.dispatchStandardAttack(
            attackerPlayerIndex,
            attackerMonIndex,
            targetBits,
            10,
            100,
            0,
            Type.Fire,
            MoveClass.Physical,
            0,
            0,
            IEffect(address(0)),
            rng
        );
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        revert("META_CALLED");
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        revert("META_CALLED");
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Fire;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function getMeta(IEngine, bytes32, uint256, uint256) external pure returns (MoveMeta memory) {
        revert("META_CALLED");
    }
}

/// @notice Doubles regressions for slot-aware damage dispatch, per-slot combat rng, and
///         status application onto slot-1 mons.
contract DoublesDispatchStatusTest is Test {
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
    IMoveSet weakAttack; // BP 10, acc 100
    IMoveSet killAttack; // BP 100, acc 100
    IMoveSet attack70; // BP 10, acc 70
    StandardAttack sleepDart; // BP 0, applies Sleep at 100%
    StandardAttack zapDart; // BP 0, applies Zap at 100%
    SleepStatus sleepStatus;
    ZapStatus zapStatus;
    Overclock overclock;
    OverclockCastMove overclockCast;
    StatBoostsMove boostMove;
    bytes32 battleKey;

    function setUp() public {
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        registry = new TestTeamRegistry();
        typeCalc = new TestTypeCalculator();
        weakAttack = new CustomAttack(
            typeCalc,
            CustomAttack.Args({
                TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 2, PRIORITY: DEFAULT_PRIORITY
            })
        );
        killAttack = new CustomAttack(
            typeCalc,
            CustomAttack.Args({
                TYPE: Type.Fire, BASE_POWER: 100, ACCURACY: 100, STAMINA_COST: 2, PRIORITY: DEFAULT_PRIORITY
            })
        );
        attack70 = new CustomAttack(
            typeCalc,
            CustomAttack.Args({
                TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 70, STAMINA_COST: 2, PRIORITY: DEFAULT_PRIORITY
            })
        );
        sleepStatus = new SleepStatus();
        zapStatus = new ZapStatus();
        sleepDart = _mkDart(sleepStatus, "Sleep Dart");
        zapDart = _mkDart(zapStatus, "Zap Dart");
        overclock = new Overclock();
        overclockCast = new OverclockCastMove(overclock);
        boostMove = new StatBoostsMove();

        address[] memory toAdd = new address[](1);
        toAdd[0] = address(this);
        vm.prank(ALICE);
        engine.updateMatchmakers(toAdd, new address[](0));
        vm.prank(BOB);
        engine.updateMatchmakers(toAdd, new address[](0));
    }

    function _mkDart(IEffect effect, string memory dartName) internal returns (StandardAttack) {
        return new StandardAttack(
            address(this),
            typeCalc,
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Cosmic,
                EFFECT_ACCURACY: 100,
                MOVE_CLASS: MoveClass.Other,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: dartName,
                EFFECT: effect
            })
        );
    }

    function _mkMon(uint32 hp, uint32 speed, uint32 attack, IMoveSet move0) internal view returns (Mon memory mon) {
        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(move0)));
        moves[1] = uint256(uint160(address(boostMove)));
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
        return sideWord(m0, e0, m1, e1, uint104(0xABCDEF));
    }

    function _turn0Leads() internal {
        engine.executeWithSlotMoves(
            battleKey,
            _side(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1),
            _side(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1)
        );
    }

    function _hp(uint256 side, uint256 mon) internal view returns (int32) {
        return engine.getMonStateForBattle(battleKey, side, mon, MonStateIndexName.Hp);
    }

    function _stamina(uint256 side, uint256 mon) internal view returns (int32) {
        return engine.getMonStateForBattle(battleKey, side, mon, MonStateIndexName.Stamina);
    }

    // ---------------------------------------------------------------------
    // Dispatch attacker resolution
    // ---------------------------------------------------------------------

    /// @dev A slot-1 attacker's deployed move must be computed from ITS stats, not the
    ///      slot-0 ally's. A1 has Atk 120 vs the ally's 10: BP 10 into Def 10 = 120 damage.
    function test_dispatch_slot1AttackerUsesOwnStats() public {
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, weakAttack);
        aTeam[1] = _mkMon(1000, 30, 120, weakAttack);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(1000, 20, 10, weakAttack);
        bTeam[1] = _mkMon(1000, 10, 10, weakAttack);
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        engine.executeWithSlotMoves(
            battleKey, _side(NO_OP_MOVE_INDEX, 0, 0, targetBits(B0)), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        assertEq(_hp(1, 0), -120, "damage uses the slot-1 attacker's own Atk");
    }

    /// @dev Stat boosts on the slot-1 attacker feed its dispatch damage: +50% on Atk 120
    ///      -> 180 -> BP 10 into Def 10 = 180 damage.
    function test_dispatch_slot1AttackerBoostFeedsDamage() public {
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, weakAttack);
        aTeam[1] = _mkMon(1000, 30, 120, weakAttack);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(1000, 20, 10, weakAttack);
        bTeam[1] = _mkMon(1000, 10, 10, weakAttack);
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        // A1 boosts its own Attack +50% (payload [amount 50 | stat Attack | mon 1]).
        uint16 boostPayload = uint16((50 << 5) | (uint16(uint8(MonStateIndexName.Attack)) << 2) | 1);
        engine.executeWithSlotMoves(
            battleKey, _side(NO_OP_MOVE_INDEX, 0, 1, boostPayload), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        engine.executeWithSlotMoves(
            battleKey, _side(NO_OP_MOVE_INDEX, 0, 0, targetBits(B0)), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        assertEq(_hp(1, 0), -180, "boosted slot-1 Atk feeds dispatch damage");
    }

    /// @dev Same-side attackers must not share combat rolls. Salt precomputed offline
    ///      (keccak walk of the engine's rng stream): side-0 salt 9 / side-1 salt 0 gives
    ///      A0 an accuracy roll of 12 (hit at 70) and A1 a roll of 89 (miss) — impossible
    ///      pre-fix, where both slots shared one roll.
    function test_dispatch_sameSideSlotsRollIndependently() public {
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, attack70);
        aTeam[1] = _mkMon(1000, 30, 10, attack70);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(1000, 20, 10, weakAttack);
        bTeam[1] = _mkMon(1000, 10, 10, weakAttack);
        _startDoubles(aTeam, bTeam);
        engine.executeWithSlotMoves(
            battleKey,
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, uint104(0xAAA)),
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, uint104(0xBBB))
        );

        engine.executeWithSlotMoves(
            battleKey,
            sideWord(0, targetBits(B0), 0, targetBits(B1), uint104(9)),
            sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, uint104(0))
        );
        assertEq(_hp(1, 0), -10, "A0's roll hits");
        assertEq(_hp(1, 1), 0, "A1's roll misses independently");
    }

    /// @dev Gachachacha's damage band lands on the CHOSEN slot (pre-fix it always resolved
    ///      the opposing slot 0). Salt precomputed offline: side-0 salt 1 rolls chance 52
    ///      (normal band) for a slot-1 Sofabbi.
    function test_gachachacha_doubles_normalBandHitsChosenSlot() public {
        Gachachacha gacha = new Gachachacha(ITypeCalculator(address(typeCalc)));
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, weakAttack);
        aTeam[1] = _mkMon(1000, 30, 10, IMoveSet(address(gacha)));
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(1000, 20, 10, weakAttack);
        bTeam[1] = _mkMon(1000, 10, 10, weakAttack);
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        // A1 rolls the gacha at B1; everyone else rests.
        engine.executeWithSlotMoves(
            battleKey,
            sideWord(NO_OP_MOVE_INDEX, 0, 0, targetBits(B1), uint104(1)),
            sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, uint104(0))
        );
        assertTrue(_hp(1, 1) < 0, "band damage lands on the chosen slot");
        assertEq(_hp(1, 0), 0, "opposing slot 0 untouched");
        assertEq(_hp(0, 0), 0, "own side untouched");
        assertEq(_hp(0, 1), 0, "caster untouched in the normal band");
    }

    /// @dev Gachachacha's self-KO band hits Sofabbi's OWN slot (pre-fix a slot-1 Sofabbi's
    ///      max-HP self-hit landed on its ally). Salt precomputed offline: side-0 salt 49
    ///      rolls chance 201 (self-KO band).
    function test_gachachacha_doubles_selfKOBandHitsOwnSlot() public {
        Gachachacha gacha = new Gachachacha(ITypeCalculator(address(typeCalc)));
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, weakAttack);
        aTeam[1] = _mkMon(1000, 30, 10, IMoveSet(address(gacha)));
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(1000, 20, 10, weakAttack);
        bTeam[1] = _mkMon(1000, 10, 10, weakAttack);
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        engine.executeWithSlotMoves(
            battleKey,
            sideWord(NO_OP_MOVE_INDEX, 0, 0, targetBits(B1), uint104(49)),
            sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, uint104(0))
        );
        assertTrue(_hp(0, 1) < 0, "self-KO hit lands on Sofabbi's own slot");
        assertEq(_hp(0, 0), 0, "ally untouched by the self-KO band");
        assertEq(_hp(1, 0), 0, "no damage to the opposing side");
        assertEq(_hp(1, 1), 0, "no damage to the chosen target in the self-KO band");
    }

    // ---------------------------------------------------------------------
    // Status onto slot-1 mons
    // ---------------------------------------------------------------------

    /// @dev Sleeping a slot-1 mon that hasn't acted cancels its pending move this turn.
    function test_sleep_slot1TargetMidTurn_cancelsPendingMove() public {
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, IMoveSet(address(sleepDart)));
        aTeam[1] = _mkMon(1000, 30, 10, weakAttack);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(1000, 20, 10, weakAttack);
        bTeam[1] = _mkMon(1000, 10, 10, weakAttack);
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        // A0 sleeps B1 before it acts; B1's committed attack on A0 must not run.
        engine.executeWithSlotMoves(
            battleKey, _side(0, targetBits(B1), NO_OP_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0, 0, targetBits(A0))
        );
        assertEq(_hp(0, 0), 0, "slept slot-1 mon's move was cancelled");
        assertEq(_stamina(1, 1), 0, "cancelled move costs no stamina");
        (bool exists,,) = engine.getEffectData(battleKey, 1, 1, address(sleepStatus));
        assertTrue(exists, "sleep effect persists on the slot-1 mon");
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 1, MonStateIndexName.ShouldSkipTurn),
            0,
            "sleep is not a skip flag"
        );
    }

    /// @dev Zapping a slot-1 mon that hasn't acted skips it this turn; the flag is consumed
    ///      (next turn it acts normally).
    function test_zap_slot1TargetNotYetActed_skipsThisTurnOnly() public {
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, IMoveSet(address(zapDart)));
        aTeam[1] = _mkMon(1000, 30, 10, weakAttack);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(1000, 20, 10, weakAttack);
        bTeam[1] = _mkMon(1000, 10, 10, weakAttack);
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        engine.executeWithSlotMoves(
            battleKey, _side(0, targetBits(B1), NO_OP_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0, 0, targetBits(A0))
        );
        assertEq(_hp(0, 0), 0, "zapped slot-1 mon lost its action");
        assertEq(_stamina(1, 1), 0, "skipped action costs no stamina");

        // Zap removed at round end (already skipped); next turn B1 attacks normally.
        engine.executeWithSlotMoves(
            battleKey, _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0, 0, targetBits(A0))
        );
        assertTrue(_hp(0, 0) < 0, "flag consumed: B1 acts the following turn");
    }

    /// @dev Zapping a mon that ALREADY acted must not leave a skip flag that eats the
    ///      forced switch after it gets KO'd the same turn. B0 commits a regular-priority
    ///      attack so the old slot-0 priority compare would have (wrongly) set the flag.
    function test_zap_alreadyActedVictim_doesNotEatForcedSwitch() public {
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, IMoveSet(address(zapDart)));
        aTeam[1] = _mkMon(1000, 30, 10, killAttack);
        Mon[] memory bTeam = new Mon[](3);
        bTeam[0] = _mkMon(1000, 20, 10, weakAttack);
        bTeam[1] = _mkMon(100, 50, 10, weakAttack); // fastest: acts before the zap
        bTeam[2] = _mkMon(1000, 5, 10, weakAttack); // bench replacement
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        // Order: B1 (50) attacks, A0 (40) zaps the already-acted B1, A1 (30) kills B1,
        // B0 (20) attacks.
        engine.executeWithSlotMoves(
            battleKey, _side(0, targetBits(B1), 0, targetBits(B1)), _side(0, targetBits(A0), 0, targetBits(A0))
        );
        assertEq(engine.getBattleContext(battleKey).playerSwitchForTurnFlag, uint8(0x80 | (1 << B1)), "B1 must switch");

        // The committed replacement lands (pre-fix a lingering ShouldSkipTurn ate it).
        engine.executeWithSlotMoves(battleKey, _side(0, 0, 0, 0), _side(0, 0, SWITCH_MOVE_INDEX, 2));
        assertEq(engine.getActiveSlots(battleKey)[B1], 2, "forced switch landed");
        assertEq(engine.getBattleContext(battleKey).playerSwitchForTurnFlag, 2, "back to a full turn");
    }

    /// @dev Zapping a NOT-yet-acted mon that then gets KO'd the same turn leaves an
    ///      unconsumed skip flag; the forced-switch send-in must still land (the engine
    ///      clears the flag instead of letting it eat the coerced switch).
    function test_zap_unactedVictimKOdSameTurn_forcedSwitchStillLands() public {
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, 10, IMoveSet(address(zapDart)));
        aTeam[1] = _mkMon(1000, 30, 10, killAttack);
        Mon[] memory bTeam = new Mon[](3);
        bTeam[0] = _mkMon(1000, 20, 10, weakAttack);
        bTeam[1] = _mkMon(100, 10, 10, weakAttack); // slowest: zapped and KO'd before acting
        bTeam[2] = _mkMon(1000, 5, 10, weakAttack); // bench replacement
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        // Order: A0 (40) zaps B1 (skip flag set), A1 (30) kills B1 (flag never consumed).
        engine.executeWithSlotMoves(
            battleKey, _side(0, targetBits(B1), 0, targetBits(B1)), _side(0, targetBits(A0), 0, targetBits(A0))
        );
        assertEq(engine.getBattleContext(battleKey).playerSwitchForTurnFlag, uint8(0x80 | (1 << B1)), "B1 must switch");

        engine.executeWithSlotMoves(battleKey, _side(0, 0, 0, 0), _side(0, 0, SWITCH_MOVE_INDEX, 2));
        assertEq(engine.getActiveSlots(battleKey)[B1], 2, "lingering skip flag must not eat the send-in");
        assertEq(engine.getBattleContext(battleKey).playerSwitchForTurnFlag, 2, "back to a full turn");
    }

    // ---------------------------------------------------------------------
    // Overclock across both lanes
    // ---------------------------------------------------------------------

    /// @dev Overclock boosts BOTH occupied lanes at apply and removes the boost from both
    ///      current occupants at expiry (including a mon that switched in mid-window).
    function test_overclock_appliesAndExpiresAcrossBothLanes() public {
        Mon[] memory aTeam = new Mon[](3);
        aTeam[0] = _mkMon(1000, 40, 10, IMoveSet(address(overclockCast)));
        aTeam[1] = _mkMon(1000, 20, 10, weakAttack);
        aTeam[2] = _mkMon(1000, 32, 10, weakAttack); // switches in mid-window
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMon(1000, 12, 10, weakAttack);
        bTeam[1] = _mkMon(1000, 8, 10, weakAttack);
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        // Cast turn: +25% Speed / -25% SpDef on BOTH side-0 lanes (duration 3 -> 2).
        engine.executeWithSlotMoves(
            battleKey, _side(0, 0, NO_OP_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Speed), 10, "A0 boosted at apply");
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Speed), 5, "slot-1 ally boosted at apply"
        );
        assertTrue(
            engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.SpecialDefense) < 0, "SpDef debuff on ally"
        );

        // Mid-window: A0 swaps to mon 2, which picks the boost up on switch-in (2 -> 1).
        engine.executeWithSlotMoves(
            battleKey, _side(SWITCH_MOVE_INDEX, 2, NO_OP_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        assertEq(engine.getMonStateForBattle(battleKey, 0, 2, MonStateIndexName.Speed), 8, "switch-in boosted");

        // Expiry round: the removal must strip BOTH current occupants.
        engine.executeWithSlotMoves(
            battleKey, _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        assertEq(engine.getMonStateForBattle(battleKey, 0, 2, MonStateIndexName.Speed), 0, "lane-0 occupant unboosted");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.Speed), 0, "lane-1 occupant unboosted");
        assertEq(
            engine.getMonStateForBattle(battleKey, 0, 1, MonStateIndexName.SpecialDefense), 0, "SpDef restored on ally"
        );
    }

    // ---------------------------------------------------------------------
    // Battle key guard
    // ---------------------------------------------------------------------

    function test_computeBattleKey_rejectsDuplicateSeats() public {
        vm.expectRevert(Engine.InvalidBattleConfig.selector);
        engine.computeBattleKey(ALICE, ALICE);
    }

    // ---------------------------------------------------------------------
    // Packed deployed-move metadata
    // ---------------------------------------------------------------------

    function _mkMonWord(uint32 hp, uint32 speed, uint256 move0Word) internal pure returns (Mon memory mon) {
        uint256[] memory moves = new uint256[](1);
        moves[0] = move0Word;
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
            ability: 0,
            moves: moves
        });
    }

    /// @dev With packed metadata the engine must execute a whole turn (priority lock +
    ///      stamina gate) without ever staticcalling the move's reverting getters.
    function test_packedMoveMeta_skipsMetadataCalls() public {
        uint256 word = MoveSlotLib.packDeployed(address(new RevertingMetaAttack()), 1, DEFAULT_PRIORITY);
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMonWord(1000, 40, word);
        aTeam[1] = _mkMonWord(1000, 30, word);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMonWord(1000, 20, word);
        bTeam[1] = _mkMonWord(1000, 10, word);
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        engine.executeWithSlotMoves(
            battleKey, _side(0, targetBits(B0), NO_OP_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        assertEq(_hp(1, 0), -10, "turn executed off packed metadata alone");
        assertEq(_stamina(0, 0), -1, "packed stamina cost applied");
    }

    /// @dev The dynamic sentinel (0xF) must fall back to the live metadata calls.
    function test_packedMoveMeta_dynamicSentinelCallsLive() public {
        uint256 word =
            MoveSlotLib.packDeployed(address(weakAttack), MOVE_META_DYNAMIC, MOVE_META_DYNAMIC);
        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMonWord(1000, 40, word);
        aTeam[1] = _mkMonWord(1000, 30, word);
        Mon[] memory bTeam = new Mon[](2);
        bTeam[0] = _mkMonWord(1000, 20, word);
        bTeam[1] = _mkMonWord(1000, 10, word);
        _startDoubles(aTeam, bTeam);
        _turn0Leads();

        engine.executeWithSlotMoves(
            battleKey, _side(0, targetBits(B0), NO_OP_MOVE_INDEX, 0), _side(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0)
        );
        assertEq(_hp(1, 0), -10, "sentinel falls back to live metadata");
        assertEq(_stamina(0, 0), -2, "live stamina cost (2) applied");
    }
}
