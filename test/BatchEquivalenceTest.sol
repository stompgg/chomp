// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {BattleOfferLib} from "../src/matchmaker/BattleOfferLib.sol";
import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";

import {IEngine} from "../src/IEngine.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IValidator} from "../src/IValidator.sol";

import {TypeCalculator} from "../src/types/TypeCalculator.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";

import {BatchHelper} from "./abstract/BatchHelper.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

/// @notice Equivalence harness for OPT_PLAN §11 Phase 2: running the same scripted turn
///         sequence through legacy `executeWithDualSignedMoves` (per-turn) vs the batched
///         `submitTurnMoves` + `executeBuffered` flow must produce byte-identical end state.
contract BatchEquivalenceTest is BatchHelper {

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 2;

    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    address p0;
    address p1;

    Engine engine;
    SignedCommitManager mgr;
    SignedMatchmaker maker;
    ITypeCalculator typeCalc;
    TestTeamRegistry registry;
    StandardAttackFactory attackFactory;

    IMoveSet moveA;
    IMoveSet moveB;

    struct TurnPlan {
        uint8 p0Move;
        uint16 p0Extra;
        uint8 p1Move;
        uint16 p1Extra;
    }

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        mgr = new SignedCommitManager(IEngine(address(engine)));
        maker = new SignedMatchmaker(engine);
        typeCalc = new TypeCalculator();
        registry = new TestTeamRegistry();
        attackFactory = new StandardAttackFactory(typeCalc);

        moveA = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 30, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "A", EFFECT: IEffect(address(0))
            })
        );
        moveB = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 25, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "B", EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = _createMon();
        mon.moves = new uint256[](MOVES_PER_MON);
        mon.moves[0] = uint256(uint160(address(moveA)));
        mon.moves[1] = uint256(uint160(address(moveB)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        registry.setTeam(p0, team);
        registry.setTeam(p1, team);
    }

    function _createMon() internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 20,
                speed: 10,
                attack: 30,
                defense: 10,
                specialAttack: 30,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: new uint256[](0),
            ability: 0
        });
    }

    function _startBattle() internal returns (bytes32) {
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(maker);
        address[] memory makersToRemove = new address[](0);
        vm.prank(p0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.prank(p1);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        (bytes32 battleKey, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);

        BattleOffer memory offer = BattleOffer({
            battle: Battle({
                p0: p0,
                p0TeamIndex: 0,
                p1: p1,
                p1TeamIndex: 0,
                teamRegistry: registry,
                validator: IValidator(address(0)),
                rngOracle: IRandomnessOracle(address(0)),
                ruleset: IRuleset(INLINE_STAMINA_REGEN_RULESET),
                moveManager: address(mgr),
                matchmaker: maker,
                engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: nonce
        });

        bytes32 digest = maker.hashTypedData(BattleOfferLib.hashBattleOffer(offer));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(P0_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(p1);
        maker.startGame(offer, sig);

        return battleKey;
    }

    /// @dev Legacy per-turn execute via `executeWithDualSignedMoves` (current production path).
    function _runLegacy(bytes32 battleKey, TurnPlan[] memory plan) internal {
        for (uint256 i = 0; i < plan.length; i++) {
            uint64 turnId = uint64(engine.getTurnIdForBattleState(battleKey));
            uint104 cSalt = uint104(uint256(keccak256(abi.encode("legacy-c", battleKey, turnId))));
            uint104 rSalt = uint104(uint256(keccak256(abi.encode("legacy-r", battleKey, turnId))));

            uint8 cMove; uint16 cExtra; uint8 rMove; uint16 rExtra;
            uint256 cPk; uint256 rPk;
            if (turnId % 2 == 0) {
                cMove = plan[i].p0Move; cExtra = plan[i].p0Extra; cPk = P0_PK;
                rMove = plan[i].p1Move; rExtra = plan[i].p1Extra; rPk = P1_PK;
            } else {
                cMove = plan[i].p1Move; cExtra = plan[i].p1Extra; cPk = P1_PK;
                rMove = plan[i].p0Move; rExtra = plan[i].p0Extra; rPk = P0_PK;
            }
            bytes32 cHash = keccak256(abi.encodePacked(cMove, cSalt, cExtra));
            bytes memory rSig =
                _signDualReveal(address(mgr), rPk, battleKey, turnId, cHash, rMove, rSalt, rExtra);

            vm.prank(vm.addr(cPk));
            mgr.executeWithDualSignedMoves(battleKey, cMove, cSalt, cExtra, rMove, rSalt, rExtra, rSig);
            engine.resetCallContext();
        }
    }

    /// @dev Batched: submit each plan turn into the buffer, then drain in one executeBuffered call.
    function _runBatched(bytes32 battleKey, TurnPlan[] memory plan) internal {
        for (uint256 i = 0; i < plan.length; i++) {
            uint64 turnId = uint64(i); // batched starts at 0 since this is a fresh battle
            _submitTurnMoves(
                mgr, battleKey, turnId,
                plan[i].p0Move, plan[i].p0Extra,
                plan[i].p1Move, plan[i].p1Extra,
                P0_PK, P1_PK
            );
        }
        _executeBuffered(engine, mgr, battleKey);
    }

    /// @dev Compare every observable piece of state between two battles.
    function _assertBattlesEqual(bytes32 keyA, bytes32 keyB, string memory label) internal {
        assertEq(engine.getTurnIdForBattleState(keyA), engine.getTurnIdForBattleState(keyB),
            string.concat(label, ": turnId"));
        assertEq(engine.getPlayerSwitchForTurnFlagForBattleState(keyA),
                 engine.getPlayerSwitchForTurnFlagForBattleState(keyB),
            string.concat(label, ": playerSwitchForTurnFlag"));
        (, BattleData memory dataA) = engine.getBattle(keyA);
        (, BattleData memory dataB) = engine.getBattle(keyB);
        assertEq(dataA.prevPlayerSwitchForTurnFlag, dataB.prevPlayerSwitchForTurnFlag,
            string.concat(label, ": prevPlayerSwitchForTurnFlag"));
        assertEq(engine.getKOBitmap(keyA, 0), engine.getKOBitmap(keyB, 0),
            string.concat(label, ": p0 KO bitmap"));
        assertEq(engine.getKOBitmap(keyA, 1), engine.getKOBitmap(keyB, 1),
            string.concat(label, ": p1 KO bitmap"));
        assertEq(uint256(uint160(engine.getWinner(keyA))), uint256(uint160(engine.getWinner(keyB))),
            string.concat(label, ": winner"));

        uint256[] memory aActiveA = engine.getActiveMonIndexForBattleState(keyA);
        uint256[] memory aActiveB = engine.getActiveMonIndexForBattleState(keyB);
        assertEq(aActiveA[0], aActiveB[0], string.concat(label, ": p0 activeMon"));
        assertEq(aActiveA[1], aActiveB[1], string.concat(label, ": p1 activeMon"));

        for (uint256 side = 0; side < 2; side++) {
            for (uint256 monIdx = 0; monIdx < MONS_PER_TEAM; monIdx++) {
                assertEq(
                    engine.getMonStateForBattle(keyA, side, monIdx, MonStateIndexName.Hp),
                    engine.getMonStateForBattle(keyB, side, monIdx, MonStateIndexName.Hp),
                    string.concat(label, ": hpDelta")
                );
                assertEq(
                    engine.getMonStateForBattle(keyA, side, monIdx, MonStateIndexName.Stamina),
                    engine.getMonStateForBattle(keyB, side, monIdx, MonStateIndexName.Stamina),
                    string.concat(label, ": staminaDelta")
                );
            }
        }
    }

    /// @dev Two-turn equivalence (the smallest interesting case: turn 0 = lead-in, turn 1 = trade).
    function test_equivalence_2_turns() public {
        TurnPlan[] memory plan = new TurnPlan[](2);
        plan[0] = TurnPlan({p0Move: SWITCH_MOVE_INDEX, p0Extra: 0, p1Move: SWITCH_MOVE_INDEX, p1Extra: 0});
        plan[1] = TurnPlan({p0Move: 0, p0Extra: 0, p1Move: 1, p1Extra: 0});

        bytes32 legacyKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runLegacy(legacyKey, plan);

        bytes32 batchedKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runBatched(batchedKey, plan);

        _assertBattlesEqual(legacyKey, batchedKey, "B=2");
    }

    /// @dev 4-turn batch.
    function test_equivalence_4_turns() public {
        TurnPlan[] memory plan = new TurnPlan[](4);
        plan[0] = TurnPlan({p0Move: SWITCH_MOVE_INDEX, p0Extra: 0, p1Move: SWITCH_MOVE_INDEX, p1Extra: 0});
        plan[1] = TurnPlan({p0Move: 0, p0Extra: 0, p1Move: 1, p1Extra: 0});
        plan[2] = TurnPlan({p0Move: 1, p0Extra: 0, p1Move: 0, p1Extra: 0});
        plan[3] = TurnPlan({p0Move: 0, p0Extra: 0, p1Move: 0, p1Extra: 0});

        bytes32 legacyKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runLegacy(legacyKey, plan);

        bytes32 batchedKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runBatched(batchedKey, plan);

        _assertBattlesEqual(legacyKey, batchedKey, "B=4");
    }

    /// @dev 8-turn batch covering NO_OPs + a mix of damage moves.
    function test_equivalence_8_turns() public {
        TurnPlan[] memory plan = new TurnPlan[](8);
        plan[0] = TurnPlan({p0Move: SWITCH_MOVE_INDEX, p0Extra: 0, p1Move: SWITCH_MOVE_INDEX, p1Extra: 0});
        plan[1] = TurnPlan({p0Move: 0, p0Extra: 0, p1Move: 1, p1Extra: 0});
        plan[2] = TurnPlan({p0Move: 1, p0Extra: 0, p1Move: 0, p1Extra: 0});
        plan[3] = TurnPlan({p0Move: NO_OP_MOVE_INDEX, p0Extra: 0, p1Move: 0, p1Extra: 0});
        plan[4] = TurnPlan({p0Move: 0, p0Extra: 0, p1Move: NO_OP_MOVE_INDEX, p1Extra: 0});
        plan[5] = TurnPlan({p0Move: 1, p0Extra: 0, p1Move: 1, p1Extra: 0});
        plan[6] = TurnPlan({p0Move: 0, p0Extra: 0, p1Move: 1, p1Extra: 0});
        plan[7] = TurnPlan({p0Move: 1, p0Extra: 0, p1Move: 0, p1Extra: 0});

        bytes32 legacyKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runLegacy(legacyKey, plan);

        bytes32 batchedKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runBatched(batchedKey, plan);

        _assertBattlesEqual(legacyKey, batchedKey, "B=8");
    }

    /// @dev Multi-batch in one battle: submit 2, execute, submit 2, execute (counter accounting check).
    function test_equivalence_multiBatch() public {
        TurnPlan[] memory firstBatch = new TurnPlan[](2);
        firstBatch[0] = TurnPlan({p0Move: SWITCH_MOVE_INDEX, p0Extra: 0, p1Move: SWITCH_MOVE_INDEX, p1Extra: 0});
        firstBatch[1] = TurnPlan({p0Move: 0, p0Extra: 0, p1Move: 1, p1Extra: 0});

        TurnPlan[] memory secondBatch = new TurnPlan[](2);
        secondBatch[0] = TurnPlan({p0Move: 1, p0Extra: 0, p1Move: 0, p1Extra: 0});
        secondBatch[1] = TurnPlan({p0Move: 0, p0Extra: 0, p1Move: 1, p1Extra: 0});

        // --- legacy: all four turns in one go ---
        TurnPlan[] memory allFour = new TurnPlan[](4);
        for (uint256 i = 0; i < 2; i++) allFour[i] = firstBatch[i];
        for (uint256 i = 0; i < 2; i++) allFour[i + 2] = secondBatch[i];

        bytes32 legacyKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runLegacy(legacyKey, allFour);

        // --- batched: two separate submit-then-execute cycles ---
        bytes32 batchedKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        for (uint256 i = 0; i < firstBatch.length; i++) {
            _submitTurnMoves(
                mgr, batchedKey, uint64(i),
                firstBatch[i].p0Move, firstBatch[i].p0Extra,
                firstBatch[i].p1Move, firstBatch[i].p1Extra,
                P0_PK, P1_PK
            );
        }
        _executeBuffered(engine, mgr, batchedKey);

        (uint64 ex1, uint64 buf1,) = mgr.getBufferStatus(batchedKey);
        assertEq(ex1, 2, "executed after first batch");
        assertEq(buf1, 0, "buffered after first drain");

        for (uint256 i = 0; i < secondBatch.length; i++) {
            _submitTurnMoves(
                mgr, batchedKey, uint64(2 + i),
                secondBatch[i].p0Move, secondBatch[i].p0Extra,
                secondBatch[i].p1Move, secondBatch[i].p1Extra,
                P0_PK, P1_PK
            );
        }
        _executeBuffered(engine, mgr, batchedKey);

        (uint64 ex2, uint64 buf2,) = mgr.getBufferStatus(batchedKey);
        assertEq(ex2, 4, "executed after second batch");
        assertEq(buf2, 0, "buffered after second drain");

        _assertBattlesEqual(legacyKey, batchedKey, "multi-batch");
    }
}
