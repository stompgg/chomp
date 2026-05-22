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

/// @notice Tallies SSTORE / SLOAD access patterns across an N-turn game, comparing legacy
///         per-turn execution vs single-tx batched execution. Shows EXACTLY which slots cost
///         what and where the architectural overhead lives.
contract BatchAccessProfileTest is BatchHelper {

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

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 100000, stamina: 20, speed: 10,
                attack: 30, defense: 10, specialAttack: 30, specialDefense: 10,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](MOVES_PER_MON),
            ability: 0
        });
        mon.moves[0] = uint256(uint160(address(moveA)));
        mon.moves[1] = uint256(uint160(address(moveB)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        registry.setTeam(p0, team);
        registry.setTeam(p1, team);
    }

    function _startBattle() internal returns (bytes32) {
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(maker);
        address[] memory makersToRemove = new address[](0);
        vm.prank(p0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.prank(p1);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        (bytes32 key, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);

        BattleOffer memory offer = BattleOffer({
            battle: Battle({
                p0: p0, p0TeamIndex: 0, p1: p1, p1TeamIndex: 0,
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
        return key;
    }

    /// @dev One legacy per-turn execute (sigs built + executeWithDualSignedMoves).
    function _legacyTurn(bytes32 battleKey, uint8 p0Move, uint8 p1Move) internal {
        uint64 t = uint64(engine.getTurnIdForBattleState(battleKey));
        uint104 cSalt = uint104(uint256(keccak256(abi.encode("c", battleKey, t))));
        uint104 rSalt = uint104(uint256(keccak256(abi.encode("r", battleKey, t))));
        uint8 cMove; uint16 cExtra; uint8 rMove; uint16 rExtra;
        uint256 cPk; uint256 rPk;
        if (t % 2 == 0) {
            cMove = p0Move; cExtra = 0; cPk = P0_PK;
            rMove = p1Move; rExtra = 0; rPk = P1_PK;
        } else {
            cMove = p1Move; cExtra = 0; cPk = P1_PK;
            rMove = p0Move; rExtra = 0; rPk = P0_PK;
        }
        bytes32 cHash = keccak256(abi.encodePacked(cMove, cSalt, cExtra));
        bytes memory cSig = _signCommit(address(mgr), cPk, cHash, battleKey, t);
        bytes memory rSig =
            _signDualReveal(address(mgr), rPk, battleKey, t, cHash, rMove, rSalt, rExtra);
        mgr.executeWithDualSignedMoves(battleKey, cMove, cSalt, cExtra, rMove, rSalt, rExtra, cSig, rSig);
        engine.resetCallContext();
    }

    function _submit(bytes32 battleKey, uint64 t, uint8 p0Move, uint8 p1Move) internal {
        _submitTurnMoves(mgr, battleKey, t, p0Move, 0, p1Move, 0, P0_PK, P1_PK);
    }

    struct Tally {
        uint256 totalSload;
        uint256 totalSstore;
        uint256 coldSload;
        uint256 warmSload;
        uint256 coldSstore;
        uint256 warmSstore;
        uint256 zeroToNonzeroSstore;
        uint256 nonzeroToNonzeroSstore;
        uint256 noopSstore;
        uint256 uniqueSlots;
    }

    /// @dev Aggregate access counts from a state-diff recording.
    /// `txBoundary == true` resets cold/warm classification per call (legacy: each turn is its own tx).
    function _tally(Vm.AccountAccess[] memory accesses) internal pure returns (Tally memory t) {
        bytes32[] memory keys = new bytes32[](2048);
        uint8[] memory writes = new uint8[](2048);
        bool[] memory reads = new bool[](2048);
        uint256 keyCount;
        for (uint256 i; i < accesses.length; i++) {
            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                bytes32 key = keccak256(abi.encode(a.account, a.slot));
                uint256 idx = keyCount;
                for (uint256 k; k < keyCount; k++) {
                    if (keys[k] == key) { idx = k; break; }
                }
                if (idx == keyCount) {
                    keys[idx] = key;
                    keyCount++;
                }
                if (a.isWrite) {
                    t.totalSstore++;
                    writes[idx]++;
                    if (a.previousValue == bytes32(0) && a.newValue != bytes32(0)) t.zeroToNonzeroSstore++;
                    else if (a.previousValue != bytes32(0) && a.newValue != bytes32(0) && a.previousValue != a.newValue) t.nonzeroToNonzeroSstore++;
                    else if (a.previousValue == a.newValue) t.noopSstore++;
                    if (writes[idx] == 1 && !reads[idx]) t.coldSstore++;
                    else t.warmSstore++;
                } else {
                    t.totalSload++;
                    if (!reads[idx] && writes[idx] == 0) {
                        t.coldSload++;
                        reads[idx] = true;
                    } else {
                        t.warmSload++;
                    }
                }
            }
        }
        t.uniqueSlots = keyCount;
    }

    function _addTally(Tally memory acc, Tally memory delta) internal pure returns (Tally memory) {
        acc.totalSload += delta.totalSload;
        acc.totalSstore += delta.totalSstore;
        acc.coldSload += delta.coldSload;
        acc.warmSload += delta.warmSload;
        acc.coldSstore += delta.coldSstore;
        acc.warmSstore += delta.warmSstore;
        acc.zeroToNonzeroSstore += delta.zeroToNonzeroSstore;
        acc.nonzeroToNonzeroSstore += delta.nonzeroToNonzeroSstore;
        acc.noopSstore += delta.noopSstore;
        acc.uniqueSlots += delta.uniqueSlots;
        return acc;
    }

    function _printTally(string memory label, Tally memory t) internal {
        console.log(label);
        console.log("  Total SLOADs                   :", t.totalSload);
        console.log("    Cold (first-touch in tx)     :", t.coldSload);
        console.log("    Warm                         :", t.warmSload);
        console.log("  Total SSTOREs                  :", t.totalSstore);
        console.log("    Cold (first-touch in tx)     :", t.coldSstore);
        console.log("    Warm                         :", t.warmSstore);
        console.log("      zero -> nonzero            :", t.zeroToNonzeroSstore);
        console.log("      nonzero -> nonzero (diff)  :", t.nonzeroToNonzeroSstore);
        console.log("      no-op (same value)         :", t.noopSstore);
        console.log("  Sum of unique slots / call     :", t.uniqueSlots);
    }

    /// @notice Run N turns via legacy (each turn its own tx-equivalent diff frame), sum
    ///         tallies. Each turn pays its own cold SLOADs since transient clears per tx.
    function _measureLegacy(uint256 nTurns) internal returns (Tally memory total) {
        bytes32 battleKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Lead-in switch (not counted)
        _legacyTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX);

        for (uint64 i = 0; i < nTurns; i++) {
            uint8 p0Move = i % 2 == 0 ? 0 : 1;
            uint8 p1Move = i % 2 == 0 ? 1 : 0;
            vm.startStateDiffRecording();
            _legacyTurn(battleKey, p0Move, p1Move);
            Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
            total = _addTally(total, _tally(diffs));
        }
    }

    /// @notice Submit N turns, then run executeBuffered in ONE diff frame so cold/warm classification
    ///         matches what the EVM actually does in a single tx (slots warm across sub-turns).
    function _measureBatchedSubmitsThenExecute(uint256 nTurns)
        internal
        returns (Tally memory totalSubmit, Tally memory totalExecute)
    {
        bytes32 battleKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        _legacyTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX);
        uint64 startTurn = uint64(engine.getTurnIdForBattleState(battleKey));

        // Submissions: each is its own tx, so tally per-submission then sum.
        for (uint64 i = 0; i < nTurns; i++) {
            uint8 p0Move = i % 2 == 0 ? 0 : 1;
            uint8 p1Move = i % 2 == 0 ? 1 : 0;
            vm.startStateDiffRecording();
            _submit(battleKey, startTurn + i, p0Move, p1Move);
            Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
            totalSubmit = _addTally(totalSubmit, _tally(diffs));
        }

        // ExecuteBuffered: single tx for all N sub-turns. Cold SLOADs paid once.
        vm.startStateDiffRecording();
        mgr.executeBuffered(battleKey);
        engine.resetCallContext();
        Vm.AccountAccess[] memory execDiffs = vm.stopAndReturnStateDiff();
        totalExecute = _tally(execDiffs);
    }

    /// @notice Concrete comparison for an end-of-game scenario (8 damage trades).
    function test_accessProfile_endOfGame_8turns() public {
        Tally memory legacy = _measureLegacy(8);
        (Tally memory submit, Tally memory exec) = _measureBatchedSubmitsThenExecute(8);

        console.log("");
        console.log("======================================================");
        console.log("  END-OF-GAME ACCESS PROFILE: 8 DAMAGE-TRADE TURNS");
        console.log("======================================================");
        console.log("");
        _printTally("LEGACY (8 turns x per-turn execute, summed across separate-tx frames):", legacy);
        console.log("");
        _printTally("BATCHED SUBMISSIONS (8 submits x per-tx frame, summed):", submit);
        console.log("");
        _printTally("BATCHED EXECUTE (single tx, 8 sub-turns):", exec);
        console.log("");

        Tally memory batchedTotal = _addTally(submit, exec);
        _printTally("BATCHED TOTAL (submissions + execute):", batchedTotal);

        console.log("");
        console.log("======================================================");
        console.log("  DELTA (batched - legacy):");
        console.log("======================================================");
        if (batchedTotal.totalSload >= legacy.totalSload) {
            console.log("  SLOADs  more  :", batchedTotal.totalSload - legacy.totalSload);
        } else {
            console.log("  SLOADs  fewer :", legacy.totalSload - batchedTotal.totalSload);
        }
        if (batchedTotal.totalSstore >= legacy.totalSstore) {
            console.log("  SSTOREs more  :", batchedTotal.totalSstore - legacy.totalSstore);
        } else {
            console.log("  SSTOREs fewer :", legacy.totalSstore - batchedTotal.totalSstore);
        }
        if (batchedTotal.coldSload >= legacy.coldSload) {
            console.log("  Cold SLOADs more  :", batchedTotal.coldSload - legacy.coldSload);
        } else {
            console.log("  Cold SLOADs FEWER :", legacy.coldSload - batchedTotal.coldSload);
        }
        if (batchedTotal.zeroToNonzeroSstore >= legacy.zeroToNonzeroSstore) {
            console.log("  z->nz SSTOREs more  :", batchedTotal.zeroToNonzeroSstore - legacy.zeroToNonzeroSstore);
        } else {
            console.log("  z->nz SSTOREs fewer :", legacy.zeroToNonzeroSstore - batchedTotal.zeroToNonzeroSstore);
        }
        if (batchedTotal.nonzeroToNonzeroSstore >= legacy.nonzeroToNonzeroSstore) {
            console.log("  nz->nz SSTOREs more :", batchedTotal.nonzeroToNonzeroSstore - legacy.nonzeroToNonzeroSstore);
        } else {
            console.log("  nz->nz SSTOREs fewer:", legacy.nonzeroToNonzeroSstore - batchedTotal.nonzeroToNonzeroSstore);
        }
    }

    /// @notice Same comparison but for a smaller 4-turn game.
    function test_accessProfile_endOfGame_4turns() public {
        Tally memory legacy = _measureLegacy(4);
        (Tally memory submit, Tally memory exec) = _measureBatchedSubmitsThenExecute(4);
        Tally memory batchedTotal = _addTally(submit, exec);

        console.log("");
        console.log("=== END-OF-GAME ACCESS PROFILE: 4 turns ===");
        _printTally("LEGACY (4 turns summed):", legacy);
        _printTally("BATCHED SUBMITS (4 summed):", submit);
        _printTally("BATCHED EXECUTE (1 tx):", exec);
        _printTally("BATCHED TOTAL:", batchedTotal);
    }
}
