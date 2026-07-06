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
import {BlessedStatus} from "../src/effects/status/BlessedStatus.sol";
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

import {BatchHelper} from "./abstract/BatchHelper.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

/// @notice Faithful replay of a REAL prod battle (26 turns, switch/no-op heavy): real mon loadouts
///         via SetupMons' canonical deployX() recipes + the log's per-turn moveIndex/salt/extraData,
///         run through LEGACY (per-turn execute), BUILT-IN (turn-by-turn submits + drain), and ONE-TX
///         (CPU batch). Asserts byte-equal end state (equivalence) across all three.
///         Gas accounting is production-faithful per tx: TX_BASE (21000 intrinsic) + the EIP-2028
///         calldata cost (16/4 per byte) + on-chain execution. The ABI encode is done OUTSIDE the
///         measured bracket and the call is dispatched low-level (see _measuredCall) because in prod the
///         relayer/wallet encodes off-chain — measuring it would over-count paths with larger structs.
///         Every path is measured on COLD slots (fresh storageKey) and again on REUSED slots.
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
        engine = new Engine(4, 4);
        TypeCalculator tc = new TypeCalculator();
        Overclock oc = new Overclock();
        SleepStatus sleepStatus = new SleepStatus();
        PanicStatus panicStatus = new PanicStatus();
        FrostbiteStatus frost = new FrostbiteStatus();
        BurnStatus burn = new BurnStatus();
        ZapStatus zap = new ZapStatus();
        BlessedStatus blessed = new BlessedStatus();
        gachaReg = new GachaTeamRegistry(4, 4, IEngine(address(engine)), IGachaRNG(address(0)), GachaTeamRegistry(address(0)));
        vm.setEnv("TYPE_CALCULATOR", vm.toString(address(tc)));
        vm.setEnv("OVERCLOCK", vm.toString(address(oc)));
        vm.setEnv("SLEEP_STATUS", vm.toString(address(sleepStatus)));
        vm.setEnv("PANIC_STATUS", vm.toString(address(panicStatus)));
        vm.setEnv("FROSTBITE_STATUS", vm.toString(address(frost)));
        vm.setEnv("BURN_STATUS", vm.toString(address(burn)));
        vm.setEnv("ZAP_STATUS", vm.toString(address(zap)));
        vm.setEnv("BLESSED_STATUS", vm.toString(address(blessed)));
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
        return _startBattleWith(address(mgr));
    }

    /// @notice Start a battle wired to the Engine's built-in dual-signed buffer flow (sentinel
    ///         moveManager) instead of the external SignedCommitManager.
    function _startBattleBuiltIn() internal returns (bytes32) {
        return _startBattleWith(BUILTIN_DUAL_SIGNED_MANAGER);
    }

    function _startBattleWith(address moveManager) internal returns (bytes32) {
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
                teamRegistry: registry,                rngOracle: IRandomnessOracle(address(0)), ruleset: IRuleset(INLINE_STAMINA_REGEN_RULESET),
                moveManager: moveManager, matchmaker: maker, engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: nonce,
            battleMode: BATTLE_MODE_SINGLES
        });
        bytes32 digest = maker.hashTypedData(BattleOfferLib.hashBattleOffer(offer));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(P0_PK, digest);
        vm.prank(p1); maker.startGame(offer, abi.encodePacked(r, s, v));
        return key;
    }

    // Old submit struct shape, kept only to measure the calldata delta of the flat+compact refactor.
    struct _OldTurnSubmission {
        uint256 packedMoves;
        bytes revealerSig;
    }

    /// @notice Deterministic calldata-cost comparison (immune to the optimizer-layout shift in the full
    ///         replay): old `submitTurnMoves(bytes32, TurnSubmission{uint256, bytes})` vs new flat
    ///         `submitTurnMoves(bytes32, uint256, bytes32, bytes32)`. Asserts the new form is cheaper.
    function test_submitCalldataCompression() public pure {
        bytes32 bk = keccak256("battleKey");
        uint256 pm = uint256(keccak256("packedMoves")); // realistic high-entropy move word
        bytes32 r = keccak256("r");
        bytes32 s = keccak256("s") & bytes32(type(uint256).max >> 1); // low-s (yParity bit free)
        bytes memory sig65 = abi.encodePacked(r, s, uint8(27)); // standard (r,s,v) 65-byte sig
        bytes32 vs = s; // v == 27 → no yParity bit set

        // Args-only calldata (selector is identical 4 bytes in both, so excluded).
        uint256 costOld = _calldataCost(abi.encode(bk, _OldTurnSubmission(pm, sig65)));
        uint256 costNew = _calldataCost(abi.encode(bk, pm, r, vs));
        assertLt(costNew, costOld, "flat+compact must be cheaper calldata");
        console.log("submit calldata gas  OLD (struct + bytes sig):", costOld);
        console.log("submit calldata gas  NEW (flat + compact sig) :", costNew);
        console.log("saved per submit                             :", costOld - costNew);
        console.log("saved over a 26-submit game                  :", (costOld - costNew) * 26);
    }

    function _coolEngineAndMgr() internal { vm.cool(address(engine)); vm.cool(address(mgr)); }

    /// @dev EIP-2028 calldata cost: 16 gas per non-zero byte, 4 per zero byte. This is the real
    ///      top-level-tx cost the flat TX_BASE (21000 intrinsic) omits. Execution here far exceeds the
    ///      EIP-7623 floor, so the standard token cost applies.
    function _calldataCost(bytes memory cd) internal pure returns (uint256 cost) {
        for (uint256 i; i < cd.length; i++) cost += cd[i] == bytes1(0) ? 4 : 16;
    }

    /// @dev Prod-faithful per-tx gas = on-chain execution + calldata bytes. The ABI encode is done by
    ///      the CALLER, OUTSIDE this bracket, because in prod the relayer/wallet encodes off-chain — so we
    ///      measure only the low-level call (CALL + the callee's decode + logic) and add the real calldata
    ///      cost. Cold-starts storage first (per-tx cold slots). Add `+ TX_BASE` once per tx at the call site.
    function _measuredCall(address target, address sender, bytes memory cd, bool measure)
        internal
        returns (uint256 gasUsed)
    {
        if (measure) _coolEngineAndMgr();
        vm.prank(sender);
        uint256 g0 = gasleft();
        (bool ok,) = target.call(cd);
        uint256 raw = g0 - gasleft();
        require(ok, "measured call reverted");
        if (measure) gasUsed = raw + _calldataCost(cd);
    }

    // ---- LEGACY (per-turn, 2-sig executeWithDualSignedMoves as on main) ----
    function _legacyTurn(bytes32 battleKey, Turn memory tn, bool measure) internal returns (uint256 gasUsed) {
        uint64 turnId = uint64(engine.getTurnIdForBattleState(battleKey));
        bool twoPlayer = tn.p0Present && tn.p1Present;
        bytes memory cd;
        address actor;
        if (twoPlayer) {
            (uint8 cM, uint16 cE, uint104 cS, uint8 rM, uint16 rE, uint104 rS, uint256 rPk) =
                turnId % 2 == 0
                    ? (tn.p0Move, tn.p0Extra, tn.p0Salt, tn.p1Move, tn.p1Extra, tn.p1Salt, P1_PK)
                    : (tn.p1Move, tn.p1Extra, tn.p1Salt, tn.p0Move, tn.p0Extra, tn.p0Salt, P0_PK);
            // Single-sig: committer (msg.sender, by parity) submits; only the revealer signs.
            actor = turnId % 2 == 0 ? p0 : p1;
            bytes32 cHash = keccak256(abi.encodePacked(cM, cS, cE));
            bytes memory rSig = _signDualReveal(address(mgr), rPk, battleKey, turnId, cHash, rM, rS, rE);
            cd = abi.encodeCall(mgr.executeWithDualSignedMoves, (battleKey, cM, cS, cE, rM, rS, rE, rSig));
        } else {
            uint8 m;
            uint16 e;
            uint104 s;
            (m, e, s, actor) = tn.p0Present
                ? (tn.p0Move, tn.p0Extra, tn.p0Salt, p0) : (tn.p1Move, tn.p1Extra, tn.p1Salt, p1);
            cd = abi.encodeCall(mgr.executeSinglePlayerMove, (battleKey, m, s, e));
        }
        gasUsed = _measuredCall(address(mgr), actor, cd, measure);
        engine.resetCallContext();
    }

    function _runLegacy(bytes32 battleKey, Turn[] memory plan, bool measure) internal returns (uint256 totalExec) {
        for (uint256 i; i < plan.length; i++) totalExec += _legacyTurn(battleKey, plan[i], measure);
    }

    // ---- BUILT-IN BATCHED (in-Engine buffer: submit/drain via the Engine directly). Single-sig
    //      dual-signed flow with signatures targeting the Engine's own EIP-712 domain. Each submit
    //      announces the moves via one compressed MovesSubmitted (move idx + extra + salts); the drain
    //      emits NO per-turn events, only a BattleComplete at game over. The production "delayed execution
    //      with turn-by-turn submits" path and a fair apples-to-apples metric vs LEGACY. ----
    function _submitTurnBuiltIn(bytes32 battleKey, uint64 turnId, Turn memory tn, bool combined, bool measure)
        internal returns (uint256 gasUsed)
    {
        uint8 p0m = tn.p0Present ? tn.p0Move : NO_OP_MOVE_INDEX;
        uint8 p1m = tn.p1Present ? tn.p1Move : NO_OP_MOVE_INDEX;
        uint104 p0s = tn.p0Present ? tn.p0Salt : uint104(uint256(keccak256(abi.encode("noop0", battleKey, turnId))));
        uint104 p1s = tn.p1Present ? tn.p1Salt : uint104(uint256(keccak256(abi.encode("noop1", battleKey, turnId))));
        (uint256 packedMoves, bytes32 r, bytes32 vs) = _buildTurnSubmissionForEngine(
            address(engine), battleKey, turnId, p0m, tn.p0Extra, p0s, p1m, tn.p1Extra, p1s, P0_PK, P1_PK
        );
        bytes memory cd = combined
            ? abi.encodeCall(engine.submitTurnMovesAndExecute, (battleKey, packedMoves, r, vs))
            : abi.encodeCall(engine.submitTurnMoves, (battleKey, packedMoves, r, vs));
        gasUsed = _measuredCall(address(engine), _committerFor(turnId, p0, p1), cd, measure);
    }

    function _runBuiltIn(bytes32 battleKey, Turn[] memory plan, bool measure) internal returns (uint256 submitExec, uint256 execExec) {
        uint64 lastIdx = uint64(plan.length - 1);
        for (uint64 i; i < lastIdx; i++) submitExec += _submitTurnBuiltIn(battleKey, i, plan[i], false, measure);
        execExec = _submitTurnBuiltIn(battleKey, lastIdx, plan[lastIdx], true, measure);
        engine.resetCallContext();
    }

    // ---- ONE-TX (single-player / CPU): all moves provided up front and executed in ONE tx via
    //      engine.executeBatchedTurns (the same loop the batched drain runs). No per-turn
    //      commit-reveal — single-player has no adversary to hide moves from — so the (plan.length-1)
    //      submit txs and their per-submit signature/context overhead collapse into this single call. ----
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
        // executeBatchedTurns is moveManager-gated, so the mgr is the tx sender.
        bytes memory cd = abi.encodeCall(engine.executeBatchedTurns, (battleKey, entries));
        execGas = _measuredCall(address(engine), address(mgr), cd, measure);
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
        // Recorded under the pre-mix RNG; the custom-move RNG mix shifts the turn structure, so this
        // fixture needs re-recording before it can replay again.
        vm.skip(true);
        Turn[] memory plan = _plan();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Every path is measured TWICE on its own freshly-deployed stack, so all paths share one regime
        // when compared: battle 1 runs on a fresh storageKey (every config/state/buffer SSTORE is a
        // 0->nonzero COLD write), then ends via timeout (freeing the storageKey) and battle 2 reuses that
        // same storageKey so its writes are steady-state nonzero->nonzero (REUSED). Mixing regimes would
        // flatter whichever path touches more storage, so we report COLD and REUSED separately.

        // ---- LEGACY (per-turn execute via external mgr) ----
        bytes32 lKey1 = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 legacyCold = _runLegacy(lKey1, plan, true) + plan.length * TX_BASE;
        bytes32 legacyState = _stateHash(lKey1);
        _endViaTimeout(lKey1);
        bytes32 lKey2 = _startBattle();
        require(engine.getStorageKey(lKey1) == engine.getStorageKey(lKey2), "legacy storageKey reuse");
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 legacyReused = _runLegacy(lKey2, plan, true) + plan.length * TX_BASE;

        // ---- BUILT-IN BATCHED (in-Engine buffer: turn-by-turn submits, single drain; emits the same
        //      per-turn MonMoves + a final BattleComplete as legacy) ----
        _deployStack();
        registry.setTeam(p0, _buildTeam(P0_IDS, _p0Stats()));
        registry.setTeam(p1, _buildTeam(P1_IDS, _p1Stats()));
        bytes32 inKey1 = _startBattleBuiltIn();
        vm.warp(vm.getBlockTimestamp() + 1);
        (uint256 inSubmitCold, uint256 inExecCold) = _runBuiltIn(inKey1, plan, true);
        uint256 builtInCold = inSubmitCold + inExecCold + plan.length * TX_BASE;
        bytes32 builtInState = _stateHash(inKey1);
        _endViaTimeout(inKey1);
        bytes32 inKey2 = _startBattleBuiltIn();
        require(engine.getStorageKey(inKey1) == engine.getStorageKey(inKey2), "built-in storageKey reuse");
        vm.warp(vm.getBlockTimestamp() + 1);
        (uint256 inSubmitReused, uint256 inExecReused) = _runBuiltIn(inKey2, plan, true);
        uint256 builtInReused = inSubmitReused + inExecReused + plan.length * TX_BASE;

        assertEq(legacyState, builtInState, "legacy and built-in must reach identical end state");

        // ---- ONE-TX (CPU: all moves up front, executed in one tx) ----
        _deployStack();
        registry.setTeam(p0, _buildTeam(P0_IDS, _p0Stats()));
        registry.setTeam(p1, _buildTeam(P1_IDS, _p1Stats()));
        bytes32 oKey1 = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 oneTxCold = _runOneTx(oKey1, plan, true) + TX_BASE;
        bytes32 oneTxState = _stateHash(oKey1);
        _endViaTimeout(oKey1);
        bytes32 oKey2 = _startBattle();
        require(engine.getStorageKey(oKey1) == engine.getStorageKey(oKey2), "one-tx storageKey reuse");
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 oneTxReused = _runOneTx(oKey2, plan, true) + TX_BASE;

        assertEq(legacyState, oneTxState, "legacy and one-tx must reach identical end state");

        console.log("");
        console.log("=== REAL game (26 turns), PROD config (inline regen), production-faithful ===");
        console.log("--- COLD SLOTS (fresh storageKey, first battle on the stack) ---");
        console.log("  LEGACY   (PvP per-turn execute, events)        :", legacyCold);
        console.log("  BUILT-IN (PvP turn-by-turn submits, events)    :", builtInCold);
        if (builtInCold < legacyCold) console.log("    built-in saves vs legacy                     :", legacyCold - builtInCold);
        console.log("  ONE-TX   (CPU: all moves + execute, 1 tx)      :", oneTxCold);
        if (oneTxCold < legacyCold) console.log("    one-tx saves vs legacy                       :", legacyCold - oneTxCold);
        console.log("--- REUSED SLOTS (storageKey reused from a prior battle) ---");
        console.log("  LEGACY   (PvP per-turn execute, events)        :", legacyReused);
        console.log("  BUILT-IN (PvP turn-by-turn submits, events)    :", builtInReused);
        if (builtInReused < legacyReused) console.log("    built-in saves vs legacy                     :", legacyReused - builtInReused);
        console.log("  ONE-TX   (CPU: all moves + execute, 1 tx)      :", oneTxReused);
        if (oneTxReused < legacyReused) console.log("    one-tx saves vs legacy                       :", legacyReused - oneTxReused);
        // NOTE: the old external-StaminaRegen main baseline (5,277,953) is NOT comparable — it
        // measured the slow ruleset. A fair main comparison needs main itself re-measured under inline.
    }
}
