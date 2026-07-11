// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {IMatchmaker} from "../src/matchmaker/IMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";

import {BatchHelper} from "./abstract/BatchHelper.sol";
import {defaultBattle, sideWord, targetBits} from "./abstract/SlotWire.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @notice Guards the flow-equivalence invariant clients depend on: a battle scripted with the
///         same moves and salts must reach a byte-identical end state whether it is executed
///         per turn (the flow munch simulates locally), staged into the built-in buffer and
///         drained, or settled in one batched tx. Every gas change to the batched/drain loops
///         must keep this green.
contract FlowEquivalenceTest is Test, BatchHelper {
    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    address p0;
    address p1;

    TestTeamRegistry registry;
    TestTypeCalculator typeCalc;
    IMoveSet weakAttack; // BP 10
    IMoveSet killAttack; // BP 200

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
    }

    function _mkMon(uint32 hp, uint32 speed) internal view returns (Mon memory mon) {
        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(weakAttack)));
        moves[1] = uint256(uint160(address(killAttack)));
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

    /// @dev Fresh engine + battle per flow so every run starts from identical cold state.
    function _freshBattle(address moveManager, uint8 battleMode) internal returns (Engine engine, bytes32 battleKey) {
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(this);
        vm.prank(p0);
        engine.updateMatchmakers(toAdd, new address[](0));
        vm.prank(p1);
        engine.updateMatchmakers(toAdd, new address[](0));

        Mon[] memory aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40);
        aTeam[1] = _mkMon(1000, 30);
        Mon[] memory bTeam = new Mon[](3);
        bTeam[0] = _mkMon(200, 10); // dies to weak (T1) + kill (T3)
        bTeam[1] = _mkMon(1000, 8);
        bTeam[2] = _mkMon(1000, 6);
        registry.setTeam(p0, aTeam);
        registry.setTeam(p1, bTeam);

        Battle memory battle = defaultBattle(p0, p1, registry, moveManager, IMatchmaker(address(this)));
        (battleKey,) = engine.computeBattleKey(p0, p1);
        engine.startBattleWithMode(battle, battleMode);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _stateHash(Engine engine, bytes32 battleKey) internal view returns (bytes32) {
        (, BattleData memory data) = engine.getBattle(battleKey);
        MonState[] memory s0 = engine.getMonStatesForSide(battleKey, 0);
        MonState[] memory s1 = engine.getMonStatesForSide(battleKey, 1);
        return keccak256(
            abi.encode(
                data.turnId,
                data.winnerIndex,
                data.activeMonIndex,
                data.activeMonExt,
                data.playerSwitchForTurnFlag,
                s0,
                s1
            )
        );
    }

    // ---------------------------------------------------------------------
    // Singles: per-turn execute vs one-tx batch vs buffer+drain
    // ---------------------------------------------------------------------
    // Script (salts per (turn, player) are identical across flows):
    //   T0 both send in mon 0; T1 both weak-attack; T2 p0 rests / p1 weak-attacks;
    //   T3 p0 kills p1's mon 0 -> forced switch; T4 p1 switches to mon 1; T5 both weak-attack.

    function _salt(uint64 turn, uint256 player) internal pure returns (uint104) {
        return uint104(1 + turn * 2 + player);
    }

    struct SinglesTurn {
        uint8 p0m;
        uint16 p0e;
        uint8 p1m;
        uint16 p1e;
        bool singlePlayer; // forced-switch turn: only p1 acts in this script
    }

    function _singlesScript() internal pure returns (SinglesTurn[] memory plan) {
        plan = new SinglesTurn[](6);
        plan[0] = SinglesTurn(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0, false);
        plan[1] = SinglesTurn(0, 0, 0, 0, false);
        plan[2] = SinglesTurn(NO_OP_MOVE_INDEX, 0, 0, 0, false);
        plan[3] = SinglesTurn(1, 0, 0, 0, false); // p0 kill -> B mon 0 KO'd
        plan[4] = SinglesTurn(NO_OP_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, true);
        plan[5] = SinglesTurn(0, 0, 0, 0, false);
    }

    function test_singles_perTurnBatchedAndDrainAgree() public {
        SinglesTurn[] memory plan = _singlesScript();

        // Flow A: per-turn execute (what clients simulate locally).
        (Engine eA, bytes32 kA) = _freshBattle(address(this), BATTLE_MODE_SINGLES);
        for (uint64 t = 0; t < plan.length; t++) {
            SinglesTurn memory turn = plan[t];
            if (turn.singlePlayer) {
                eA.executeWithSingleMove(kA, turn.p1m, _salt(t, 1), turn.p1e);
            } else {
                eA.executeWithMoves(kA, turn.p0m, _salt(t, 0), turn.p0e, turn.p1m, _salt(t, 1), turn.p1e);
            }
            eA.resetCallContext(); // each turn ran as its own tx in this flow
        }
        bytes32 hashA = _stateHash(eA, kA);

        // Flow B: one batched tx.
        (Engine eB, bytes32 kB) = _freshBattle(address(this), BATTLE_MODE_SINGLES);
        uint256[] memory entries = new uint256[](plan.length);
        for (uint64 t = 0; t < plan.length; t++) {
            SinglesTurn memory turn = plan[t];
            entries[t] = uint256(turn.p0m) | (uint256(turn.p0e) << 8) | (uint256(_salt(t, 0)) << 24)
                | (uint256(turn.p1m) << 128) | (uint256(turn.p1e) << 136) | (uint256(_salt(t, 1)) << 152);
        }
        eB.executeBatchedTurns(kB, entries);
        assertEq(_stateHash(eB, kB), hashA, "batched end state must equal per-turn end state");

        // Flow C: built-in buffer then permissionless drain.
        (Engine eC, bytes32 kC) = _freshBattle(BUILTIN_DUAL_SIGNED_MANAGER, BATTLE_MODE_SINGLES);
        for (uint64 t = 0; t < plan.length; t++) {
            SinglesTurn memory turn = plan[t];
            (uint256 packedMoves, bytes32 r, bytes32 vs) = _buildTurnSubmissionForEngine(
                address(eC), kC, t, turn.p0m, turn.p0e, _salt(t, 0), turn.p1m, turn.p1e, _salt(t, 1), P0_PK, P1_PK
            );
            vm.prank(t % 2 == 0 ? p0 : p1);
            eC.submitTurnMoves(kC, packedMoves, r, vs);
        }
        vm.prank(address(0xCAFE));
        eC.executeBuffered(kC);
        eC.resetCallContext();
        assertEq(_stateHash(eC, kC), hashA, "drained end state must equal per-turn end state");
    }

    // ---------------------------------------------------------------------
    // Doubles: per-turn slot execute vs one-tx slot batch vs slot buffer+drain
    // ---------------------------------------------------------------------
    // Script: T0 send-ins (0,1 each side); T1 A0 kills B0, others weak-attack ->
    // forced switch for B slot 0; T2 mask turn (B0 -> mon 2); T3 everyone rests.

    function _doublesSides(uint64 t) internal pure returns (uint256 side0, uint256 side1) {
        if (t == 0) {
            side0 = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, _salt(0, 0));
            side1 = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, _salt(0, 1));
        } else if (t == 1) {
            side0 = sideWord(1, targetBits(2), 0, targetBits(3), _salt(1, 0));
            side1 = sideWord(0, targetBits(0), 0, targetBits(0), _salt(1, 1));
        } else if (t == 2) {
            side0 = sideWord(0, 0, 0, 0, _salt(2, 0));
            side1 = sideWord(SWITCH_MOVE_INDEX, 2, 0, 0, _salt(2, 1));
        } else {
            side0 = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, _salt(3, 0));
            side1 = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, _salt(3, 1));
        }
    }

    function test_doubles_perTurnBatchedAndDrainAgree() public {
        // Flow A: per-turn slot execute.
        (Engine eA, bytes32 kA) = _freshBattle(address(this), BATTLE_MODE_DOUBLES);
        for (uint64 t = 0; t < 4; t++) {
            (uint256 s0, uint256 s1) = _doublesSides(t);
            eA.executeWithSlotMoves(kA, s0, s1);
            eA.resetCallContext();
        }
        bytes32 hashA = _stateHash(eA, kA);

        // Flow B: one batched tx.
        (Engine eB, bytes32 kB) = _freshBattle(address(this), BATTLE_MODE_DOUBLES);
        uint256[] memory entries = new uint256[](8);
        for (uint64 t = 0; t < 4; t++) {
            (entries[t * 2], entries[t * 2 + 1]) = _doublesSides(t);
        }
        eB.executeBatchedSlotTurns(kB, entries);
        assertEq(_stateHash(eB, kB), hashA, "slot-batched end state must equal per-turn end state");

        // Flow C: slot buffer then drain.
        (Engine eC, bytes32 kC) = _freshBattle(BUILTIN_DUAL_SIGNED_MANAGER, BATTLE_MODE_DOUBLES);
        for (uint64 t = 0; t < 4; t++) {
            (uint256 s0, uint256 s1) = _doublesSides(t);
            (uint256 committerPacked, uint256 revealerPacked, bytes32 r, bytes32 vs) =
                _buildSlotTurnSubmissionForEngine(address(eC), kC, t, s0, s1, P0_PK, P1_PK);
            vm.prank(t % 2 == 0 ? p0 : p1);
            eC.submitSlotTurnMoves(kC, committerPacked, revealerPacked, r, vs);
        }
        vm.prank(address(0xCAFE));
        eC.executeBuffered(kC);
        eC.resetCallContext();
        assertEq(_stateHash(eC, kC), hashA, "slot-drained end state must equal per-turn end state");
    }
}
