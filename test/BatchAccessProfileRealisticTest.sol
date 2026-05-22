// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {DefaultRuleset} from "../src/DefaultRuleset.sol";
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {BattleOfferLib} from "../src/matchmaker/BattleOfferLib.sol";
import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";

import {IEngine} from "../src/IEngine.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IValidator} from "../src/IValidator.sol";

import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";
import {StaminaRegen} from "../src/effects/StaminaRegen.sol";
import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../src/effects/status/FrostbiteStatus.sol";
import {StatBoosts} from "../src/effects/StatBoosts.sol";

import {TypeCalculator} from "../src/types/TypeCalculator.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

import {CustomAttack} from "./mocks/CustomAttack.sol";
import {EffectAttack} from "./mocks/EffectAttack.sol";
import {StatBoostsMove} from "./mocks/StatBoostsMove.sol";

import {BatchHelper} from "./abstract/BatchHelper.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

/// @notice Realistic-game access profile: mirrors the move sequence from
///         `InlineEngineGasTest.test_consecutiveBattleGas` — 4-mon teams, mixed move types
///         (burn / frostbite / stat-boost / damage), multiple KOs and forced switches.
///         Runs the same game via legacy (executeWithDualSignedMoves per turn) AND batched
///         (submitTurnMoves × N + executeBuffered) for TWO consecutive battles, then tallies
///         the SECOND battle (steady-state, where engine storageKey and manager buffer slots
///         are warmed from battle 1).
contract BatchAccessProfileRealisticTest is BatchHelper {

    uint256 constant MONS_PER_TEAM = 4;
    uint256 constant MOVES_PER_MON = 4;

    // Move indices on each mon (mirrors InlineEngineGasTest layout):
    uint8 constant MOVE_BURN     = 0;
    uint8 constant MOVE_FROST    = 1;
    uint8 constant MOVE_STATBST  = 2;
    uint8 constant MOVE_DAMAGE   = 3;

    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    address p0;
    address p1;

    Engine engine;
    SignedCommitManager mgr;
    SignedMatchmaker maker;
    ITypeCalculator typeCalc;
    TestTeamRegistry registry;
    DefaultRuleset ruleset;

    // Two-player turn (flag == 2): both players act.
    // Single-player switch turn (flag == 0 or 1): non-acting half is NO_OP.
    struct TurnPlan {
        uint8 p0Move;
        uint16 p0Extra;
        uint8 p1Move;
        uint16 p1Extra;
        bool isSinglePlayer; // true if this turn was a forced switch in the original test
        uint8 actingPlayer;  // 0 or 1, only used if isSinglePlayer == true
    }

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        mgr = new SignedCommitManager(IEngine(address(engine)));
        maker = new SignedMatchmaker(engine);
        typeCalc = new TestTypeCalculator();
        registry = new TestTeamRegistry();

        StatBoosts statBoosts = new StatBoosts();
        IMoveSet burnMove =
            new EffectAttack(new BurnStatus(statBoosts), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet frostbiteMove =
            new EffectAttack(new FrostbiteStatus(statBoosts), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet statBoostMove = new StatBoostsMove(statBoosts);
        IMoveSet damageMove = new CustomAttack(
            ITypeCalculator(address(typeCalc)),
            CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 1})
        );

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1, stamina: 5, speed: 1, attack: 10, defense: 1,
                specialAttack: 10, specialDefense: 1,
                type1: Type.Yin, type2: Type.None
            }),
            moves: new uint256[](MOVES_PER_MON),
            ability: 0
        });
        mon.moves[MOVE_BURN]    = uint256(uint160(address(burnMove)));
        mon.moves[MOVE_FROST]   = uint256(uint160(address(frostbiteMove)));
        mon.moves[MOVE_STATBST] = uint256(uint160(address(statBoostMove)));
        mon.moves[MOVE_DAMAGE]  = uint256(uint160(address(damageMove)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        registry.setTeam(p0, team);
        registry.setTeam(p1, team);

        IEffect[] memory globals = new IEffect[](1);
        globals[0] = new StaminaRegen();
        ruleset = new DefaultRuleset(IEngine(address(engine)), globals);
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
                ruleset: IRuleset(address(ruleset)),
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

    /// @dev Builds the 14-turn move sequence from InlineEngineGasTest's Battle 1.
    function _buildBattlePlan() internal pure returns (TurnPlan[] memory plan) {
        // _packStatBoost layout from BattleHelper: [boostAmount:8 | statIndex:4 | monIndex:3 | playerIndex:1].
        // packStatBoost(targetPlayer, targetMon, statIndex, boost) values for the canonical sequence.
        uint16 sb_p1_m0_atk_90 = _staticPackStatBoost(1, 0, uint256(MonStateIndexName.Attack), 90);
        uint16 sb_p0_m1_atk_90 = _staticPackStatBoost(0, 1, uint256(MonStateIndexName.Attack), 90);
        uint16 sb_p0_m0_atk_90 = _staticPackStatBoost(0, 0, uint256(MonStateIndexName.Attack), 90);
        uint16 sb_p1_m1_atk_90 = _staticPackStatBoost(1, 1, uint256(MonStateIndexName.Attack), 90);

        plan = new TurnPlan[](14);
        plan[ 0] = TurnPlan({p0Move: SWITCH_MOVE_INDEX, p0Extra: 0, p1Move: SWITCH_MOVE_INDEX, p1Extra: 0, isSinglePlayer: false, actingPlayer: 0});
        plan[ 1] = TurnPlan({p0Move: MOVE_BURN,    p0Extra: 0,                  p1Move: MOVE_FROST,        p1Extra: 0,                  isSinglePlayer: false, actingPlayer: 0});
        plan[ 2] = TurnPlan({p0Move: SWITCH_MOVE_INDEX, p0Extra: 1,             p1Move: MOVE_STATBST,      p1Extra: sb_p1_m0_atk_90,    isSinglePlayer: false, actingPlayer: 0});
        plan[ 3] = TurnPlan({p0Move: MOVE_STATBST, p0Extra: sb_p0_m1_atk_90,    p1Move: MOVE_DAMAGE,       p1Extra: 0,                  isSinglePlayer: false, actingPlayer: 0});
        plan[ 4] = TurnPlan({p0Move: SWITCH_MOVE_INDEX, p0Extra: 0,             p1Move: NO_OP_MOVE_INDEX,  p1Extra: 0,                  isSinglePlayer: true,  actingPlayer: 0});
        plan[ 5] = TurnPlan({p0Move: MOVE_STATBST, p0Extra: sb_p0_m0_atk_90,    p1Move: NO_OP_MOVE_INDEX,  p1Extra: 0,                  isSinglePlayer: false, actingPlayer: 0});
        plan[ 6] = TurnPlan({p0Move: MOVE_DAMAGE,  p0Extra: 0,                  p1Move: NO_OP_MOVE_INDEX,  p1Extra: 0,                  isSinglePlayer: false, actingPlayer: 0});
        plan[ 7] = TurnPlan({p0Move: NO_OP_MOVE_INDEX, p0Extra: 0,              p1Move: SWITCH_MOVE_INDEX, p1Extra: 1,                  isSinglePlayer: true,  actingPlayer: 1});
        plan[ 8] = TurnPlan({p0Move: NO_OP_MOVE_INDEX, p0Extra: 0,              p1Move: MOVE_STATBST,      p1Extra: sb_p1_m1_atk_90,    isSinglePlayer: false, actingPlayer: 0});
        plan[ 9] = TurnPlan({p0Move: NO_OP_MOVE_INDEX, p0Extra: 0,              p1Move: MOVE_DAMAGE,       p1Extra: 0,                  isSinglePlayer: false, actingPlayer: 0});
        plan[10] = TurnPlan({p0Move: SWITCH_MOVE_INDEX, p0Extra: 2,             p1Move: NO_OP_MOVE_INDEX,  p1Extra: 0,                  isSinglePlayer: true,  actingPlayer: 0});
        plan[11] = TurnPlan({p0Move: NO_OP_MOVE_INDEX, p0Extra: 0,              p1Move: MOVE_DAMAGE,       p1Extra: 0,                  isSinglePlayer: false, actingPlayer: 0});
        plan[12] = TurnPlan({p0Move: SWITCH_MOVE_INDEX, p0Extra: 3,             p1Move: NO_OP_MOVE_INDEX,  p1Extra: 0,                  isSinglePlayer: true,  actingPlayer: 0});
        plan[13] = TurnPlan({p0Move: NO_OP_MOVE_INDEX, p0Extra: 0,              p1Move: MOVE_DAMAGE,       p1Extra: 0,                  isSinglePlayer: false, actingPlayer: 0});
    }

    function _staticPackStatBoost(uint256 playerIndex, uint256 monIndex, uint256 statIndex, int32 boostAmount)
        internal pure returns (uint16)
    {
        return uint16(
            (playerIndex & 0x1)
            | ((monIndex & 0x7) << 1)
            | ((statIndex & 0xF) << 4)
            | ((uint256(uint8(int8(boostAmount))) & 0xFF) << 8)
        );
    }

    /// @dev Run one turn via legacy single-tx flow.
    function _legacyTurn(bytes32 battleKey, TurnPlan memory plan) internal {
        uint64 t = uint64(engine.getTurnIdForBattleState(battleKey));
        uint104 cSalt = uint104(uint256(keccak256(abi.encode("c", battleKey, t))));
        uint104 rSalt = uint104(uint256(keccak256(abi.encode("r", battleKey, t))));

        if (plan.isSinglePlayer) {
            uint8 move = plan.actingPlayer == 0 ? plan.p0Move : plan.p1Move;
            uint16 extra = plan.actingPlayer == 0 ? plan.p0Extra : plan.p1Extra;
            uint104 salt = plan.actingPlayer == 0 ? cSalt : rSalt;
            address player = plan.actingPlayer == 0 ? p0 : p1;
            vm.prank(player);
            mgr.executeSinglePlayerMove(battleKey, move, salt, extra);
            engine.resetCallContext();
            return;
        }

        uint8 cMove; uint16 cExtra; uint8 rMove; uint16 rExtra;
        uint256 cPk; uint256 rPk;
        if (t % 2 == 0) {
            cMove = plan.p0Move; cExtra = plan.p0Extra; cPk = P0_PK;
            rMove = plan.p1Move; rExtra = plan.p1Extra; rPk = P1_PK;
        } else {
            cMove = plan.p1Move; cExtra = plan.p1Extra; cPk = P1_PK;
            rMove = plan.p0Move; rExtra = plan.p0Extra; rPk = P0_PK;
        }
        bytes32 cHash = keccak256(abi.encodePacked(cMove, cSalt, cExtra));
        bytes memory rSig =
            _signDualReveal(address(mgr), rPk, battleKey, t, cHash, rMove, rSalt, rExtra);
        vm.prank(vm.addr(cPk));
        mgr.executeWithDualSignedMoves(battleKey, cMove, cSalt, cExtra, rMove, rSalt, rExtra, rSig);
        engine.resetCallContext();
    }

    function _submitTurn(bytes32 battleKey, uint64 t, TurnPlan memory plan) internal {
        _submitTurnMoves(mgr, battleKey, t, plan.p0Move, plan.p0Extra, plan.p1Move, plan.p1Extra, P0_PK, P1_PK);
    }

    struct Tally {
        uint256 totalSload;
        uint256 totalSstore;
        uint256 coldSload;
        uint256 warmSload;
        uint256 coldSstore;
        uint256 warmSstore;
        uint256 zeroToNonzero;
        uint256 nonzeroToNonzero;
        uint256 noop;
        uint256 unique;
    }

    function _tally(Vm.AccountAccess[] memory accesses) internal pure returns (Tally memory t) {
        bytes32[] memory keys = new bytes32[](4096);
        uint16[] memory writes = new uint16[](4096);
        bool[] memory reads = new bool[](4096);
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
                if (idx == keyCount) { keys[idx] = key; keyCount++; }
                if (a.isWrite) {
                    t.totalSstore++;
                    writes[idx]++;
                    if (a.previousValue == bytes32(0) && a.newValue != bytes32(0)) t.zeroToNonzero++;
                    else if (a.previousValue != bytes32(0) && a.newValue != bytes32(0) && a.previousValue != a.newValue) t.nonzeroToNonzero++;
                    else if (a.previousValue == a.newValue) t.noop++;
                    if (writes[idx] == 1 && !reads[idx]) t.coldSstore++;
                    else t.warmSstore++;
                } else {
                    t.totalSload++;
                    if (!reads[idx] && writes[idx] == 0) { t.coldSload++; reads[idx] = true; }
                    else t.warmSload++;
                }
            }
        }
        t.unique = keyCount;
    }

    function _addTally(Tally memory a, Tally memory b) internal pure returns (Tally memory o) {
        o.totalSload = a.totalSload + b.totalSload;
        o.totalSstore = a.totalSstore + b.totalSstore;
        o.coldSload = a.coldSload + b.coldSload;
        o.warmSload = a.warmSload + b.warmSload;
        o.coldSstore = a.coldSstore + b.coldSstore;
        o.warmSstore = a.warmSstore + b.warmSstore;
        o.zeroToNonzero = a.zeroToNonzero + b.zeroToNonzero;
        o.nonzeroToNonzero = a.nonzeroToNonzero + b.nonzeroToNonzero;
        o.noop = a.noop + b.noop;
        o.unique = a.unique + b.unique;
    }

    function _printTally(string memory label, Tally memory t) internal {
        console.log(label);
        console.log("  SLOADs  total:", t.totalSload);
        console.log("     cold       :", t.coldSload);
        console.log("     warm       :", t.warmSload);
        console.log("  SSTOREs total:", t.totalSstore);
        console.log("     cold       :", t.coldSstore);
        console.log("     warm       :", t.warmSstore);
        console.log("       z->nz   :", t.zeroToNonzero);
        console.log("       nz->nz  :", t.nonzeroToNonzero);
        console.log("       no-op   :", t.noop);
        console.log("  unique slots :", t.unique);
    }

    /// @dev Run a full game via legacy flow, summing per-turn tallies (each turn is its own tx).
    function _measureLegacyGame(bytes32 battleKey, TurnPlan[] memory plan) internal returns (Tally memory total) {
        for (uint256 i; i < plan.length; i++) {
            vm.startStateDiffRecording();
            _legacyTurn(battleKey, plan[i]);
            Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
            total = _addTally(total, _tally(diffs));
        }
    }

    /// @dev Run a full game via batched flow: N submissions (each its own tx) + 1 executeBuffered.
    function _measureBatchedGame(bytes32 battleKey, TurnPlan[] memory plan)
        internal
        returns (Tally memory submitTotal, Tally memory exec)
    {
        for (uint64 i; i < plan.length; i++) {
            vm.startStateDiffRecording();
            _submitTurn(battleKey, uint64(i), plan[i]);
            Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
            submitTotal = _addTally(submitTotal, _tally(diffs));
        }
        vm.startStateDiffRecording();
        mgr.executeBuffered(battleKey);
        engine.resetCallContext();
        Vm.AccountAccess[] memory execDiffs = vm.stopAndReturnStateDiff();
        exec = _tally(execDiffs);
    }

    /// @notice The headline test. Mirrors `InlineEngineGasTest.test_consecutiveBattleGas`'s
    ///         Battle 1 sequence — 14 turns with switches, KOs, status effects, and stat boosts.
    ///         Runs the SAME sequence via legacy AND batched, twice (cold + steady-state), and
    ///         prints the steady-state access tally for both.
    function test_realisticGameAccessProfile_steadyState() public {
        TurnPlan[] memory plan = _buildBattlePlan();
        vm.warp(vm.getBlockTimestamp() + 1);

        // ---- LEGACY ----
        // Battle 1 (cold): warm up engine storageKey + state.
        bytes32 lKey1 = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runLegacyWithoutMeasurement(lKey1, plan);

        // Verify battle 1 actually ended (game-over fired -> _freeStorageKey was called).
        // Without this, battle 2 wouldn't reuse battle 1's storageKey and the "steady state"
        // measurement would actually be measuring cold slots.
        require(engine.getWinner(lKey1) != address(0), "STEADY-STATE PRECONDITION: battle 1 must end");

        // Battle 2 (steady state): measure. Assert storageKey reuse — battle 2 should land in
        // the same storage slots battle 1 freed at game-over, so SSTORE writes hit warm
        // nonzero->nonzero (~2.9k) instead of cold zero->nonzero (~22.1k).
        bytes32 lKey2 = _startBattle();
        require(
            engine.getStorageKey(lKey1) == engine.getStorageKey(lKey2),
            "STEADY-STATE PRECONDITION: legacy battle 2 should reuse battle 1's storageKey"
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        Tally memory legacy = _measureLegacyGame(lKey2, plan);

        // ---- BATCHED ----
        // Need fresh engine for fair comparison so we don't carry warm-up from legacy battles.
        // We mirror the same two-battle pattern: battle 1 cold, battle 2 steady.
        _resetForBatched();
        bytes32 bKey1 = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runBatchedWithoutMeasurement(bKey1, plan);

        require(engine.getWinner(bKey1) != address(0), "STEADY-STATE PRECONDITION: batched battle 1 must end");

        bytes32 bKey2 = _startBattle();
        require(
            engine.getStorageKey(bKey1) == engine.getStorageKey(bKey2),
            "STEADY-STATE PRECONDITION: batched battle 2 should reuse battle 1's storageKey"
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        (Tally memory submit, Tally memory exec) = _measureBatchedGame(bKey2, plan);
        Tally memory batchedTotal = _addTally(submit, exec);

        console.log("");
        console.log("===============================================================");
        console.log("  REALISTIC GAME (14 turns, mirror of test_consecutiveBattleGas)");
        console.log("  STEADY STATE (measured on Battle 2 of each flow)");
        console.log("===============================================================");
        console.log("");
        _printTally("LEGACY (executeWithDualSignedMoves x N, summed):", legacy);
        console.log("");
        _printTally("BATCHED SUBMISSIONS (submitTurnMoves x N, summed):", submit);
        console.log("");
        _printTally("BATCHED EXECUTE (one executeBuffered call):", exec);
        console.log("");
        _printTally("BATCHED TOTAL (submissions + execute):", batchedTotal);
        console.log("");
        console.log("===============================================================");
        console.log("  DELTA (batched - legacy):");
        console.log("===============================================================");
        _printDelta("SSTOREs total ", batchedTotal.totalSstore, legacy.totalSstore);
        _printDelta("  z->nz       ", batchedTotal.zeroToNonzero, legacy.zeroToNonzero);
        _printDelta("  nz->nz      ", batchedTotal.nonzeroToNonzero, legacy.nonzeroToNonzero);
        _printDelta("  no-op       ", batchedTotal.noop, legacy.noop);
        _printDelta("SLOADs total  ", batchedTotal.totalSload, legacy.totalSload);
        _printDelta("  cold        ", batchedTotal.coldSload, legacy.coldSload);
        _printDelta("  warm        ", batchedTotal.warmSload, legacy.warmSload);
    }

    function _printDelta(string memory label, uint256 a, uint256 b) internal {
        if (a >= b) {
            console.log(string.concat(label, " more :"), a - b);
        } else {
            console.log(string.concat(label, " fewer:"), b - a);
        }
    }

    // -------- Slot bucketing diagnostic --------
    //
    // Buckets the raw `vm.startStateDiffRecording` accesses by which Engine storage region
    // they target, so we can see where the SSTOREs/SLOADs in the BATCHED EXECUTE column
    // actually land. Bucket boundaries are derived from Engine.sol's storage layout:
    //   slot 3 = battleData mapping        -> battleData[battleKey] data lives at H(battleKey, 3)
    //   slot 4 = battleConfig mapping      -> battleConfig[storageKey] data lives at H(storageKey, 4) + struct offset
    //     +0  validator + p0EffectsCount
    //     +1  rngOracle + p1EffectsCount
    //     +2  moveManager + teamSizes + KO bitmaps + startTimestamp + ... (slot 2 of struct)
    //     +3  p0Salt + p1Salt
    //     +4  p0Move (MoveDecision)
    //     +5  p1Move (MoveDecision)
    //     +6  teamRegistry
    //     +7,8  p0Team, p1Team (mapping anchors; data hashed at H(monIdx, anchor))
    //     +9,10 p0States, p1States (mapping anchors)
    //     +11,12,13 globalEffects, p0Effects, p1Effects (mapping anchors; stride layout)
    //     +14  engineHooks (mapping anchor)
    //   slot 5 = globalKV nested mapping (data at H(uint64key, H(storageKey, 5)))
    //   slot 6 = globalKVKeySlots (data at H(slotIdx, H(storageKey, 6)))
    struct Bucket {
        bytes32 storageKey;
        bytes32 battleKey;
        bytes32 bdAnchor;     // H(battleKey, 3)
        bytes32 bcAnchor;     // H(storageKey, 4)
        bytes32 kvAnchor;     // H(storageKey, 5)
        bytes32 kvSlotsAnchor;// H(storageKey, 6)
    }

    function _bucket(bytes32 storageKey, bytes32 battleKey) internal pure returns (Bucket memory b) {
        b.storageKey = storageKey;
        b.battleKey = battleKey;
        // Engine storage slot layout (MappingAllocator has 2 state vars: freeStorageKeys + battleKeyToStorageKey):
        //   0 freeStorageKeys, 1 battleKeyToStorageKey, 2 pairHashNonces, 3 isMatchmakerFor,
        //   4 battleData, 5 battleConfig, 6 globalKV, 7 globalKVKeySlots
        b.bdAnchor = keccak256(abi.encode(battleKey, uint256(4)));
        b.bcAnchor = keccak256(abi.encode(storageKey, uint256(5)));
        b.kvAnchor = keccak256(abi.encode(storageKey, uint256(6)));
        b.kvSlotsAnchor = keccak256(abi.encode(storageKey, uint256(7)));
    }

    /// @dev Returns a region label for a raw slot. Best-effort: matches BattleData / BattleConfig
    ///      fixed fields exactly, and probes mapping anchors for small index ranges (mon 0..7).
    function _labelSlot(Bucket memory b, bytes32 slot) internal pure returns (string memory) {
        uint256 s = uint256(slot);

        // Fixed BattleData slots (only 2 used today).
        if (s == uint256(b.bdAnchor)) return "BD.slot0 (p0/p1/teamIndices)";
        if (s == uint256(b.bdAnchor) + 1) return "BD.slot1 (SHADOW: turnId/flags/winner)";

        // Fixed BattleConfig slots (struct offsets 0..6 are scalar fields).
        for (uint256 i; i < 7; i++) {
            if (s == uint256(b.bcAnchor) + i) {
                if (i == 0) return "BC.slot0 (validator + p0EffCount)";
                if (i == 1) return "BC.slot1 (rngOracle + p1EffCount)";
                if (i == 2) return "BC.slot2 (moveManager + KO bitmap + teamSizes + startTs)";
                if (i == 3) return "BC.slot3 (p0Salt + p1Salt)";
                if (i == 4) return "BC.slot4 (p0Move)";
                if (i == 5) return "BC.slot5 (p1Move)";
                if (i == 6) return "BC.slot6 (teamRegistry)";
            }
        }

        // Mapping data: probe small mon indices (0..7) against each anchor.
        // For `mapping(uint256 => V) X;` at struct offset N in BattleConfig:
        //   X[key] lives at keccak256(abi.encode(key, bcAnchor + N)). If V is a struct of M slots,
        //   the slots span [keccak256(...), keccak256(...) + M).
        for (uint256 monIdx; monIdx < 8; monIdx++) {
            // p0Team / p1Team (Mon struct, multi-slot). We only flag the FIRST slot of each Mon.
            if (s == uint256(keccak256(abi.encode(monIdx, uint256(b.bcAnchor) + 7)))) return "BC.p0Team[i].slot0";
            if (s == uint256(keccak256(abi.encode(monIdx, uint256(b.bcAnchor) + 8)))) return "BC.p1Team[i].slot0";
            // MonState (single slot each).
            if (s == uint256(keccak256(abi.encode(monIdx, uint256(b.bcAnchor) + 9)))) return "BC.p0States[i] (MonState)";
            if (s == uint256(keccak256(abi.encode(monIdx, uint256(b.bcAnchor) + 10)))) return "BC.p1States[i] (MonState)";
        }
        // Effects: each EffectInstance is 2 slots. Engine uses stride-64 per mon
        // (see _getMonEffectCount / Constants), so per-mon effect entries are at
        // keccak256(abi.encode(monIdx * 64 + effIdx, bcAnchor + offset)).
        for (uint256 monIdx; monIdx < 8; monIdx++) {
            for (uint256 effIdx; effIdx < 16; effIdx++) {
                uint256 key = monIdx * 64 + effIdx;
                if (s == uint256(keccak256(abi.encode(key, uint256(b.bcAnchor) + 12)))) return "BC.p0Effects[mon][eff].slot0 (effect+steps)";
                if (s == uint256(keccak256(abi.encode(key, uint256(b.bcAnchor) + 12))) + 1) return "BC.p0Effects[mon][eff].slot1 (data)";
                if (s == uint256(keccak256(abi.encode(key, uint256(b.bcAnchor) + 13)))) return "BC.p1Effects[mon][eff].slot0 (effect+steps)";
                if (s == uint256(keccak256(abi.encode(key, uint256(b.bcAnchor) + 13))) + 1) return "BC.p1Effects[mon][eff].slot1 (data)";
            }
        }
        // Global effects (single flat mapping; small indices).
        for (uint256 effIdx; effIdx < 32; effIdx++) {
            if (s == uint256(keccak256(abi.encode(effIdx, uint256(b.bcAnchor) + 11)))) return "BC.globalEffects[i].slot0";
            if (s == uint256(keccak256(abi.encode(effIdx, uint256(b.bcAnchor) + 11))) + 1) return "BC.globalEffects[i].slot1";
        }
        // engineHooks at offset 14 — single slot per hook.
        for (uint256 hookIdx; hookIdx < 16; hookIdx++) {
            if (s == uint256(keccak256(abi.encode(hookIdx, uint256(b.bcAnchor) + 14)))) return "BC.engineHooks[i]";
        }

        // GlobalKV: H(uint64key, kvAnchor). Probe small keys.
        for (uint256 k; k < 32; k++) {
            if (s == uint256(keccak256(abi.encode(uint64(k), b.kvAnchor)))) return "GlobalKV[i]";
            if (s == uint256(keccak256(abi.encode(k, b.kvSlotsAnchor)))) return "GlobalKVKeySlots[i]";
        }

        // Unmatched: dump the raw slot for manual inspection.
        return "(unmatched)";
    }

    function _printSlotBuckets(string memory label, Vm.AccountAccess[] memory accesses, Bucket memory b) internal {
        console.log("");
        console.log(label);
        console.log("  ANCHORS:");
        console.log("    bdAnchor      =", uint256(b.bdAnchor));
        console.log("    bcAnchor      =", uint256(b.bcAnchor));
        console.log("    kvAnchor      =", uint256(b.kvAnchor));
        console.log("    kvSlotsAnchor =", uint256(b.kvSlotsAnchor));
        console.log("    bdSlot1       =", uint256(b.bdAnchor) + 1);
        console.log("    bcSlot0       =", uint256(b.bcAnchor) + 0);
        console.log("    bcSlot2 (KO)  =", uint256(b.bcAnchor) + 2);
        console.log("    p0States anch =", uint256(keccak256(abi.encode(uint256(0), uint256(b.bcAnchor) + 9))));
        console.log("    p1States anch =", uint256(keccak256(abi.encode(uint256(0), uint256(b.bcAnchor) + 10))));
        console.log("");
        // Aggregate by label: writes, no-op writes, reads.
        string[] memory labels = new string[](512);
        uint256[] memory writes = new uint256[](512);
        uint256[] memory noops = new uint256[](512);
        uint256[] memory reads = new uint256[](512);
        bytes32[] memory unmatchedSlots = new bytes32[](512);
        uint256[] memory unmatchedHits = new uint256[](512);
        uint256 unmatchedN;
        uint256 n;
        for (uint256 i; i < accesses.length; i++) {
            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                string memory lbl = _labelSlot(b, a.slot);
                if (keccak256(bytes(lbl)) == keccak256(bytes("(unmatched)"))) {
                    // Track unique unmatched slots.
                    bool found;
                    for (uint256 u; u < unmatchedN; u++) {
                        if (unmatchedSlots[u] == a.slot) { unmatchedHits[u]++; found = true; break; }
                    }
                    if (!found) { unmatchedSlots[unmatchedN] = a.slot; unmatchedHits[unmatchedN] = 1; unmatchedN++; }
                    continue;
                }
                uint256 idx = n;
                for (uint256 k; k < n; k++) {
                    if (keccak256(bytes(labels[k])) == keccak256(bytes(lbl))) { idx = k; break; }
                }
                if (idx == n) { labels[n] = lbl; n++; }
                if (a.isWrite) {
                    if (a.previousValue == a.newValue) noops[idx]++;
                    else writes[idx]++;
                } else {
                    reads[idx]++;
                }
            }
        }
        for (uint256 k; k < n; k++) {
            console.log(string.concat("  ", labels[k]));
            console.log("    reads :", reads[k]);
            console.log("    writes:", writes[k]);
            console.log("    noops :", noops[k]);
        }
        if (unmatchedN > 0) {
            console.log("  (unmatched slots -- likely effects past probe range)");
            for (uint256 u; u < unmatchedN; u++) {
                console.log("    slot", uint256(unmatchedSlots[u]));
                console.log("    hits :", unmatchedHits[u]);
            }
        }
    }

    /// @notice Gas measurement counterpart to `test_realisticGameAccessProfile_steadyState`.
    ///         Same 14-turn plan, same warmup-then-measure structure, but uses `gasleft()`
    ///         before/after each turn instead of `vm.startStateDiffRecording`.
    ///
    /// !!! HARNESS BIAS — READ BEFORE TRUSTING THIS NUMBER !!!
    /// `gasleft()` inside a single foundry test function measures all 14 legacy turns under
    /// ONE EVM transaction. Per EIP-2929, slots accessed in turn 1 become warm for turns 2-14
    /// (SLOAD 100 instead of 2,100; SSTORE doesn't pay the cold-access penalty). In production
    /// each legacy turn is its own transaction with cold-start access, so production legacy
    /// gas is materially higher than this number.
    ///
    /// The batched flow's executeBuffered IS a single tx in both the test and production, so
    /// its number IS representative. The submit calls are also each their own tx in production
    /// but get amortized inside the test the same way legacy does — modest bias.
    ///
    /// To estimate the production legacy number, take the access tally from
    /// `test_realisticGameAccessProfile_steadyState` (which records each turn as its own tx
    /// via per-call `vm.startStateDiffRecording`) and apply the EIP-2929/EIP-2200 cost model.
    ///
    /// The shadow's actual savings live in the SSTORE/SLOAD count delta, not in this number.
    /// The bucket diagnostic shows BD.slot1: 14 writes → 1 (single flush), koBitmaps: ~10 → 1,
    /// MonStates: ~6 → 0 (game-over skip). Those are 25+ SSTOREs coalesced into transient by
    /// the shadow layer, costing ~5k each in production. The single-tx test measurement masks
    /// most of that win.
    function test_realisticGameSteadyStateGas() public {
        TurnPlan[] memory plan = _buildBattlePlan();
        vm.warp(vm.getBlockTimestamp() + 1);

        // ---- LEGACY ----
        bytes32 lKey1 = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runLegacyWithoutMeasurement(lKey1, plan);
        require(engine.getWinner(lKey1) != address(0), "PRECONDITION: legacy battle 1 must end");

        bytes32 lKey2 = _startBattle();
        require(engine.getStorageKey(lKey1) == engine.getStorageKey(lKey2), "PRECONDITION: storageKey reuse");
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 legacyGasTotal;
        for (uint256 i; i < plan.length; i++) {
            uint256 g = gasleft();
            _legacyTurn(lKey2, plan[i]);
            legacyGasTotal += g - gasleft();
        }

        // ---- BATCHED ----
        _resetForBatched();
        bytes32 bKey1 = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runBatchedWithoutMeasurement(bKey1, plan);
        require(engine.getWinner(bKey1) != address(0), "PRECONDITION: batched battle 1 must end");

        bytes32 bKey2 = _startBattle();
        require(engine.getStorageKey(bKey1) == engine.getStorageKey(bKey2), "PRECONDITION: storageKey reuse");
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 batchedSubmitGas;
        for (uint64 i; i < plan.length; i++) {
            uint256 g = gasleft();
            _submitTurn(bKey2, uint64(i), plan[i]);
            batchedSubmitGas += g - gasleft();
        }
        uint256 g0 = gasleft();
        mgr.executeBuffered(bKey2);
        uint256 batchedExecuteGas = g0 - gasleft();
        engine.resetCallContext();

        console.log("");
        console.log("===============================================================");
        console.log("  REALISTIC GAME (14 turns, steady-state, gas measurement)");
        console.log("  WARNING: legacy is single-tx in this harness -- see docstring.");
        console.log("===============================================================");
        console.log("LEGACY total gas (14 turns, single-tx warmth)  :", legacyGasTotal);
        console.log("BATCHED submit gas (14 submits)                :", batchedSubmitGas);
        console.log("BATCHED execute gas (1 executeBuf, prod-faithful):", batchedExecuteGas);
        console.log("BATCHED total gas                              :", batchedSubmitGas + batchedExecuteGas);
        // Lower-bound production legacy estimate: add cold-SLOAD/SSTORE penalty for the
        // ~260 SLOADs and ~100 SSTOREs that production would re-incur each turn but the
        // single-tx harness amortizes. Penalty per slot per re-cold = 2,000 gas (cold 2,100
        // - warm 100). Numbers derived from the steady-state access tally test.
        uint256 prodLegacyEstimate = legacyGasTotal + 260 * 2000 + 14 * 21000;
        console.log("LEGACY production estimate (14 separate txs)   :", prodLegacyEstimate);
        if (prodLegacyEstimate > batchedSubmitGas + batchedExecuteGas + 14 * 21000) {
            console.log("BATCHED saves vs production legacy             :",
                prodLegacyEstimate - (batchedSubmitGas + batchedExecuteGas + 14 * 21000));
        }
    }

    /// @notice Diagnostic test: re-runs the realistic batched flow with state-diff recording
    ///         and bucketing by storage region. Use to spot which slots are still hot after
    ///         the BattleData / MonState shadows landed.
    function test_realisticGameSlotBuckets() public {
        TurnPlan[] memory plan = _buildBattlePlan();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Battle 1 to warm storageKey, then battle 2 measured (steady state).
        bytes32 bKey1 = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runBatchedWithoutMeasurement(bKey1, plan);
        require(engine.getWinner(bKey1) != address(0), "PRECONDITION: battle 1 must end");

        bytes32 bKey2 = _startBattle();
        bytes32 storageKey = engine.getStorageKey(bKey2);
        require(engine.getStorageKey(bKey1) == storageKey, "PRECONDITION: storageKey reuse");
        vm.warp(vm.getBlockTimestamp() + 1);

        // Submit all turns, then record only the executeBuffered call (the hot path).
        for (uint64 i; i < plan.length; i++) {
            _submitTurn(bKey2, i, plan[i]);
        }
        vm.startStateDiffRecording();
        mgr.executeBuffered(bKey2);
        engine.resetCallContext();
        Vm.AccountAccess[] memory execDiffs = vm.stopAndReturnStateDiff();

        Bucket memory b = _bucket(storageKey, bKey2);
        _printSlotBuckets("SLOT BUCKETS (executeBuffered, steady state):", execDiffs, b);

        console.log("");
        console.log("Battle 2 final state:");
        console.log("  winner       :", uint256(uint160(engine.getWinner(bKey2))));
        console.log("  turnId       :", engine.getTurnIdForBattleState(bKey2));
        // NOTE: after _freeStorageKey runs at game-over, getKOBitmap(battleKey, ...) returns 0
        // because battleKeyToStorageKey was deleted; read via the cached storageKey directly.
        uint256 koSlot = uint256(vm.load(address(engine), bytes32(uint256(b.bcAnchor) + 2)));
        uint256 koBitmaps = (koSlot >> 184) & 0xFFFF;
        console.log("  p0KO bitmap  :", koBitmaps & 0xFF);
        console.log("  p1KO bitmap  :", koBitmaps >> 8);
        console.log("  raw slot 2   :", koSlot);
    }

    function _runLegacyWithoutMeasurement(bytes32 battleKey, TurnPlan[] memory plan) internal {
        for (uint256 i; i < plan.length; i++) {
            _legacyTurn(battleKey, plan[i]);
        }
    }

    function _runBatchedWithoutMeasurement(bytes32 battleKey, TurnPlan[] memory plan) internal {
        for (uint64 i; i < plan.length; i++) {
            _submitTurn(battleKey, uint64(i), plan[i]);
        }
        mgr.executeBuffered(battleKey);
        engine.resetCallContext();
    }

    /// @dev Reset state for batched run so we get clean steady-state measurement (battle 2 from
    /// the batched engine, not battle 4 carried over from legacy).
    function _resetForBatched() internal {
        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        mgr = new SignedCommitManager(IEngine(address(engine)));
        maker = new SignedMatchmaker(engine);
        IEffect[] memory globals = new IEffect[](1);
        globals[0] = new StaminaRegen();
        ruleset = new DefaultRuleset(IEngine(address(engine)), globals);
    }
}
