// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {SetupMons} from "../script/SetupMons.s.sol";
import {Engine} from "../src/Engine.sol";
import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";
import {IGachaRNG} from "../src/rng/IGachaRNG.sol";
import {IEngine} from "../src/IEngine.sol";

import {TypeCalculator} from "../src/types/TypeCalculator.sol";
import {StatBoosts} from "../src/effects/StatBoosts.sol";
import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../src/effects/status/FrostbiteStatus.sol";
import {PanicStatus} from "../src/effects/status/PanicStatus.sol";
import {SleepStatus} from "../src/effects/status/SleepStatus.sol";
import {ZapStatus} from "../src/effects/status/ZapStatus.sol";
import {Overclock} from "../src/effects/battlefield/Overclock.sol";

import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {BattleOfferLib} from "../src/matchmaker/BattleOfferLib.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IValidator} from "../src/IValidator.sol";

import {BatchHelper} from "./abstract/BatchHelper.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

/// @notice Faithful replay of a REAL prod battle (26 turns, switch/no-op heavy): real mon loadouts
///         via SetupMons' canonical deployX() recipes + the log's per-turn moveIndex/salt/extraData,
///         run through LEGACY (per-turn execute) and BATCHED (single-sig submit x N-1 + a final
///         submitTurnMovesAndExecute that buffers the last turn and drains in the same tx).
///         Asserts byte-equal end state (equivalence) and reports production-faithful (vm.cool,
///         steady-state) total gas. Batching uses direct storage (no shadow) + single-sig submit.
contract RealMonReplayGasTest is Test, SetupMons, BatchHelper {
    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    uint256 constant TX_BASE = 21000;
    address p0;
    address p1;

    Engine engine;
    SignedCommitManager mgr;
    SignedMatchmaker maker;
    GachaTeamRegistry gachaReg;
    TestTeamRegistry registry;

    uint256[4] P0_IDS = [uint256(6), 3, 9, 8];
    uint256[4] P1_IDS = [uint256(0), 3, 10, 5];

    struct Turn {
        uint8 p0Move; uint16 p0Extra; uint104 p0Salt; bool p0Present;
        uint8 p1Move; uint16 p1Extra; uint104 p1Salt; bool p1Present;
    }

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);
        _deployStack();
        registry.setTeam(p0, _buildTeam(P0_IDS, _p0Stats()));
        registry.setTeam(p1, _buildTeam(P1_IDS, _p1Stats()));
    }

    function _deployStack() internal {
        engine = new Engine(4, 4, 1);
        TypeCalculator tc = new TypeCalculator();
        StatBoosts sb = new StatBoosts();
        Overclock oc = new Overclock(sb);
        SleepStatus sleepStatus = new SleepStatus();
        PanicStatus panicStatus = new PanicStatus();
        FrostbiteStatus frost = new FrostbiteStatus(sb);
        BurnStatus burn = new BurnStatus(sb);
        ZapStatus zap = new ZapStatus();
        gachaReg = new GachaTeamRegistry(4, 4, IEngine(address(engine)), IGachaRNG(address(0)));
        vm.setEnv("TYPE_CALCULATOR", vm.toString(address(tc)));
        vm.setEnv("STAT_BOOSTS", vm.toString(address(sb)));
        vm.setEnv("OVERCLOCK", vm.toString(address(oc)));
        vm.setEnv("SLEEP_STATUS", vm.toString(address(sleepStatus)));
        vm.setEnv("PANIC_STATUS", vm.toString(address(panicStatus)));
        vm.setEnv("FROSTBITE_STATUS", vm.toString(address(frost)));
        vm.setEnv("BURN_STATUS", vm.toString(address(burn)));
        vm.setEnv("ZAP_STATUS", vm.toString(address(zap)));
        vm.setEnv("GACHA_TEAM_REGISTRY", vm.toString(address(gachaReg)));
        deployGhouliath(gachaReg); deployInutia(gachaReg); deployMalalien(gachaReg); deployIblivion(gachaReg);
        deployGorillax(gachaReg); deploySofabbi(gachaReg); deployPengym(gachaReg); deployEmbursa(gachaReg);
        deployVolthare(gachaReg); deployAurox(gachaReg); deployXmon(gachaReg);
        mgr = new SignedCommitManager(IEngine(address(engine)));
        maker = new SignedMatchmaker(engine);
        registry = new TestTeamRegistry();
        // Production uses the inline stamina-regen path (INLINE_STAMINA_REGEN_RULESET sentinel),
        // handled internally by the engine — no external StaminaRegen effect / ruleset deployed.
    }

    function _buildTeam(uint256[4] memory ids, MonStats[4] memory logStats) internal view returns (Mon[] memory team) {
        team = new Mon[](4);
        for (uint256 i; i < 4; i++) {
            (, uint256[] memory moves, uint256[] memory abilities) = gachaReg.getMonData(ids[i]);
            team[i] = Mon({stats: logStats[i], ability: abilities.length > 0 ? abilities[0] : 0, moves: moves});
        }
    }

    function _mk(uint32 hp, uint32 stam, uint32 spe, uint32 atk, uint32 def, uint32 spa, uint32 spd, Type t1, Type t2)
        internal pure returns (MonStats memory)
    { return MonStats({hp: hp, stamina: stam, speed: spe, attack: atk, defense: def, specialAttack: spa, specialDefense: spd, type1: t1, type2: t2}); }

    function _p0Stats() internal pure returns (MonStats[4] memory s) {
        s[0] = _mk(371, 5, 149, 202, 200, 222, 180, Type.Ice, Type.None);
        s[1] = _mk(277, 5, 256, 197, 156, 252, 160, Type.Yang, Type.Air);
        s[2] = _mk(420, 5, 100, 143, 230, 95, 220, Type.Metal, Type.None);
        s[3] = _mk(295, 5, 311, 120, 193, 255, 184, Type.Lightning, Type.Cyber);
    }
    function _p1Stats() internal pure returns (MonStats[4] memory s) {
        s[0] = _mk(303, 5, 181, 157, 202, 151, 202, Type.Yin, Type.Fire);
        s[1] = _mk(277, 5, 256, 188, 164, 240, 168, Type.Yang, Type.Air);
        s[2] = _mk(311, 5, 285, 123, 179, 222, 185, Type.Cosmic, Type.None);
        s[3] = _mk(333, 5, 175, 180, 201, 120, 269, Type.Nature, Type.None);
    }

    function _plan() internal pure returns (Turn[] memory t) {
        t = new Turn[](26);
        t[0]  = Turn(125,1,15450001689812990757318517192966,true, 125,0,18252122845989030006812243139474,true);
        t[1]  = Turn(2,0,4834210944993112651816909106126,true,   3,0,15255474349613996056713761071686,true);
        t[2]  = Turn(2,0,6583714706138183953804767275678,true,   1,0,15461637266987935369279566108124,true);
        t[3]  = Turn(2,0,7210161534971784956923416751886,true,   1,0,15016064050662495416725412652563,true);
        t[4]  = Turn(126,0,0,false,                               125,1,19240011345095274681466263674330,true);
        t[5]  = Turn(126,0,3284692555853178397455092928083,true,  126,0,7835549805310255467442088074506,true);
        t[6]  = Turn(125,3,12334118906782137414472592949424,true, 126,0,19374785281272442474766137271163,true);
        t[7]  = Turn(2,0,15077791565903026790875989318528,true,   125,0,11421095052443333388573678495326,true);
        t[8]  = Turn(126,0,0,false,                               125,1,6291473213391741470941218170218,true);
        t[9]  = Turn(0,0,7022931971424196742811121512061,true,    125,3,15438085774022369100235175410030,true);
        t[10] = Turn(1,2,4420670065419414850590787481288,true,    2,0,1960761762236369089740333992246,true);
        t[11] = Turn(3,0,19801295147355512497167142159749,true,   2,0,6166359188124075649524594725791,true);
        t[12] = Turn(3,0,17171843021366040478135578264996,true,   2,0,5383564461617129507072037502214,true);
        t[13] = Turn(125,3,1986471879882982807378747309426,true,  126,0,14414938581786935425390960964000,true);
        t[14] = Turn(1,2,3458675293930857335960176057085,true,    2,0,7749328072402731440980579744946,true);
        t[15] = Turn(125,3,17293194887286872287278788602290,true, 126,0,4383111541380336465729024026150,true);
        t[16] = Turn(1,2,10450409746379039708229821790015,true,   125,2,8716693538680640339539097046509,true);
        t[17] = Turn(3,0,15015474814001600635537093680446,true,   1,0,2288645315003210275352244731355,true);
        t[18] = Turn(125,3,11920649514225307809051229177287,true, 1,0,11401157979167469193859133635460,true);
        t[19] = Turn(126,0,17457123310241581297033221314838,true, 1,0,10631747601138287248935576077466,true);
        t[20] = Turn(0,0,6835862067306040477454545192907,true,    1,0,9322809856242922630776583049082,true);
        t[21] = Turn(0,0,4954019214144165935310368793018,true,    1,0,134338259296852826632816183133,true);
        t[22] = Turn(126,0,0,false,                               125,1,16613587181676977476579639480048,true);
        t[23] = Turn(1,0,17804535964781524133768449087333,true,   125,3,18580496538728489255944038457804,true);
        t[24] = Turn(126,0,0,false,                               125,1,7470981269216264771411536686385,true);
        t[25] = Turn(2,0,12785556958579953943913050575887,true,   126,0,17130052050856558701654168347952,true);
    }

    function _startBattle() internal returns (bytes32) {
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(maker);
        address[] memory makersToRemove = new address[](0);
        vm.prank(p0); engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.prank(p1); engine.updateMatchmakers(makersToAdd, makersToRemove);
        (bytes32 key, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);
        BattleOffer memory offer = BattleOffer({
            battle: Battle({
                p0: p0, p0TeamIndex: 0, p1: p1, p1TeamIndex: 0,
                teamRegistry: registry, validator: IValidator(address(0)),
                rngOracle: IRandomnessOracle(address(0)), ruleset: IRuleset(INLINE_STAMINA_REGEN_RULESET),
                moveManager: address(mgr), matchmaker: maker, engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: nonce
        });
        bytes32 digest = maker.hashTypedData(BattleOfferLib.hashBattleOffer(offer));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(P0_PK, digest);
        vm.prank(p1); maker.startGame(offer, abi.encodePacked(r, s, v));
        return key;
    }

    function _coolEngineAndMgr() internal { vm.cool(address(engine)); vm.cool(address(mgr)); }

    // ---- LEGACY (per-turn, 2-sig executeWithDualSignedMoves as on main) ----
    function _legacyTurn(bytes32 battleKey, Turn memory tn, bool measure) internal returns (uint256 gasUsed) {
        uint64 turnId = uint64(engine.getTurnIdForBattleState(battleKey));
        bool twoPlayer = tn.p0Present && tn.p1Present;
        if (twoPlayer) {
            (uint8 cM, uint16 cE, uint104 cS, uint8 rM, uint16 rE, uint104 rS, uint256 rPk) =
                turnId % 2 == 0
                    ? (tn.p0Move, tn.p0Extra, tn.p0Salt, tn.p1Move, tn.p1Extra, tn.p1Salt, P1_PK)
                    : (tn.p1Move, tn.p1Extra, tn.p1Salt, tn.p0Move, tn.p0Extra, tn.p0Salt, P0_PK);
            // Single-sig: committer (msg.sender, by parity) submits; only the revealer signs.
            address committer = turnId % 2 == 0 ? p0 : p1;
            bytes32 cHash = keccak256(abi.encodePacked(cM, cS, cE));
            bytes memory rSig = _signDualReveal(address(mgr), rPk, battleKey, turnId, cHash, rM, rS, rE);
            if (measure) { _coolEngineAndMgr(); vm.prank(committer); uint256 g0 = gasleft();
                mgr.executeWithDualSignedMoves(battleKey, cM, cS, cE, rM, rS, rE, rSig);
                gasUsed = g0 - gasleft();
            } else { vm.prank(committer); mgr.executeWithDualSignedMoves(battleKey, cM, cS, cE, rM, rS, rE, rSig); }
        } else {
            (uint8 m, uint16 e, uint104 s, address actor) = tn.p0Present
                ? (tn.p0Move, tn.p0Extra, tn.p0Salt, p0) : (tn.p1Move, tn.p1Extra, tn.p1Salt, p1);
            if (measure) _coolEngineAndMgr();
            uint256 g0 = gasleft();
            vm.prank(actor); mgr.executeSinglePlayerMove(battleKey, m, s, e);
            if (measure) gasUsed = g0 - gasleft();
        }
        engine.resetCallContext();
    }

    // ---- BATCHED (single-sig submit: committer = msg.sender) ----
    function _submitTurn(bytes32 battleKey, uint64 turnId, Turn memory tn, bool combined, bool measure)
        internal returns (uint256 gasUsed)
    {
        uint8 p0m = tn.p0Present ? tn.p0Move : NO_OP_MOVE_INDEX;
        uint8 p1m = tn.p1Present ? tn.p1Move : NO_OP_MOVE_INDEX;
        uint104 p0s = tn.p0Present ? tn.p0Salt : uint104(uint256(keccak256(abi.encode("noop0", battleKey, turnId))));
        uint104 p1s = tn.p1Present ? tn.p1Salt : uint104(uint256(keccak256(abi.encode("noop1", battleKey, turnId))));
        TurnSubmission memory entry = _buildTurnSubmission(
            address(mgr), battleKey, turnId, p0m, tn.p0Extra, p0s, p1m, tn.p1Extra, p1s, P0_PK, P1_PK
        );
        address committer = _committerFor(turnId, p0, p1);
        if (measure) _coolEngineAndMgr();
        vm.prank(committer);
        uint256 g0 = gasleft();
        // Final submission drains the whole buffer in the same tx; the rest only buffer.
        if (combined) {
            mgr.submitTurnMovesAndExecute(battleKey, entry);
        } else {
            mgr.submitTurnMoves(battleKey, entry);
        }
        gasUsed = g0 - gasleft();
    }

    function _runLegacy(bytes32 battleKey, Turn[] memory plan, bool measure) internal returns (uint256 totalExec) {
        for (uint256 i; i < plan.length; i++) totalExec += _legacyTurn(battleKey, plan[i], measure);
    }

    function _runBatched(bytes32 battleKey, Turn[] memory plan, bool measure) internal returns (uint256 submitExec, uint256 execExec) {
        uint64 lastIdx = uint64(plan.length - 1);
        for (uint64 i; i < lastIdx; i++) submitExec += _submitTurn(battleKey, i, plan[i], false, measure);
        // Final turn submits AND drains the buffer in one tx (submit + executeBuffered combined).
        execExec = _submitTurn(battleKey, lastIdx, plan[lastIdx], true, measure);
        engine.resetCallContext();
    }

    // ---- ONE-TX (single-player / CPU): all moves provided up front and executed in ONE tx via
    //      engine.executeBatchedTurns (the same loop the batched drain runs). No per-turn
    //      commit-reveal — single-player has no adversary to hide moves from — so the (plan.length-1)
    //      submit txs and their sig/getSubmitContext overhead collapse into this single call. ----
    function _oneTxEntries(bytes32 battleKey, Turn[] memory plan) internal pure returns (uint256[] memory entries) {
        entries = new uint256[](plan.length);
        for (uint256 i; i < plan.length; i++) {
            Turn memory tn = plan[i];
            uint8 p0m = tn.p0Present ? tn.p0Move : NO_OP_MOVE_INDEX;
            uint8 p1m = tn.p1Present ? tn.p1Move : NO_OP_MOVE_INDEX;
            uint104 p0s = tn.p0Present ? tn.p0Salt : uint104(uint256(keccak256(abi.encode("noop0", battleKey, i))));
            uint104 p1s = tn.p1Present ? tn.p1Salt : uint104(uint256(keccak256(abi.encode("noop1", battleKey, i))));
            // executeBatchedTurns entry layout: p0Move 8 | p0Extra 16 | p0Salt 104 | p1Move 8 | p1Extra 16 | p1Salt 104
            entries[i] = uint256(p0m) | (uint256(tn.p0Extra) << 8) | (uint256(p0s) << 24)
                | (uint256(p1m) << 128) | (uint256(tn.p1Extra) << 136) | (uint256(p1s) << 152);
        }
    }

    function _runOneTx(bytes32 battleKey, Turn[] memory plan, bool measure) internal returns (uint256 execGas) {
        uint256[] memory entries = _oneTxEntries(battleKey, plan);
        if (measure) _coolEngineAndMgr();
        vm.prank(address(mgr)); // executeBatchedTurns is moveManager-gated
        uint256 g0 = gasleft();
        engine.executeBatchedTurns(battleKey, entries);
        if (measure) execGas = g0 - gasleft();
        engine.resetCallContext();
    }

    function _stateHash(bytes32 battleKey) internal view returns (bytes32) {
        (, BattleData memory data) = engine.getBattle(battleKey);
        MonState[] memory p0s = engine.getMonStatesForSide(battleKey, 0);
        MonState[] memory p1s = engine.getMonStatesForSide(battleKey, 1);
        return keccak256(abi.encode(data.turnId, data.winnerIndex, data.activeMonIndex, p0s, p1s));
    }

    function _endViaTimeout(bytes32 battleKey) internal {
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        engine.end(battleKey);
        engine.resetCallContext();
    }

    function test_realGameReplay_legacyVsBatched() public {
        Turn[] memory plan = _plan();
        vm.warp(vm.getBlockTimestamp() + 1);

        // LEGACY: battle 1 warms slots + ends via timeout (frees storageKey), battle 2 measured.
        bytes32 lKey1 = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runLegacy(lKey1, plan, false);
        bytes32 legacyState = _stateHash(lKey1);
        _endViaTimeout(lKey1);
        bytes32 lKey2 = _startBattle();
        require(engine.getStorageKey(lKey1) == engine.getStorageKey(lKey2), "legacy storageKey reuse");
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 legacyExec = _runLegacy(lKey2, plan, true);
        uint256 legacyTotal = legacyExec + plan.length * TX_BASE;

        // BATCHED: fresh stack, same pattern.
        _deployStack();
        registry.setTeam(p0, _buildTeam(P0_IDS, _p0Stats()));
        registry.setTeam(p1, _buildTeam(P1_IDS, _p1Stats()));
        bytes32 bKey1 = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runBatched(bKey1, plan, false);
        bytes32 batchedState = _stateHash(bKey1);
        _endViaTimeout(bKey1);
        bytes32 bKey2 = _startBattle();
        require(engine.getStorageKey(bKey1) == engine.getStorageKey(bKey2), "batched storageKey reuse");
        vm.warp(vm.getBlockTimestamp() + 1);
        (uint256 submitExec, uint256 execExec) = _runBatched(bKey2, plan, true);
        // plan.length transactions total: (plan.length - 1) buffer-only submits + 1 combined submit+execute.
        uint256 batchedTotal = submitExec + execExec + plan.length * TX_BASE;

        assertEq(legacyState, batchedState, "legacy and batched must reach identical end state");

        // ONE-TX (single-player/CPU): all moves up front, executed in one tx. Fresh stack, same pattern.
        _deployStack();
        registry.setTeam(p0, _buildTeam(P0_IDS, _p0Stats()));
        registry.setTeam(p1, _buildTeam(P1_IDS, _p1Stats()));
        bytes32 oKey1 = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _runOneTx(oKey1, plan, false);
        bytes32 oneTxState = _stateHash(oKey1);
        _endViaTimeout(oKey1);
        bytes32 oKey2 = _startBattle();
        require(engine.getStorageKey(oKey1) == engine.getStorageKey(oKey2), "one-tx storageKey reuse");
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 oneTxExec = _runOneTx(oKey2, plan, true);
        uint256 oneTxTotal = oneTxExec + TX_BASE; // submit + execute everything in ONE tx

        assertEq(legacyState, oneTxState, "legacy and one-tx must reach identical end state");

        console.log("");
        console.log("=== CLEAN BRANCH: REAL game (26 turns), PROD config (inline regen), production-faithful ===");
        console.log("  LEGACY  (inline regen, repack, 1-sig):", legacyTotal);
        console.log("  BATCHED (inline regen, repack, 1-sig):", batchedTotal);
        if (batchedTotal < legacyTotal) console.log("  batching saves vs clean-legacy       :", legacyTotal - batchedTotal);
        console.log("  ONE-TX  (CPU: all moves + execute, 1 tx):", oneTxTotal);
        if (oneTxTotal < batchedTotal) console.log("  one-tx saves vs batched              :", batchedTotal - oneTxTotal);
        if (oneTxTotal < legacyTotal) console.log("  one-tx saves vs legacy               :", legacyTotal - oneTxTotal);
        // NOTE: the old external-StaminaRegen main baseline (5,277,953) is NOT comparable — it
        // measured the slow ruleset. A fair main comparison needs main itself re-measured under inline.
    }
}
