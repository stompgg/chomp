// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {SetupMons} from "../script/SetupMons.s.sol";
import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";
import {IGachaRNG} from "../src/rng/IGachaRNG.sol";

import {Overclock} from "../src/effects/battlefield/Overclock.sol";
import {BlessedStatus} from "../src/effects/status/BlessedStatus.sol";
import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../src/effects/status/FrostbiteStatus.sol";
import {PanicStatus} from "../src/effects/status/PanicStatus.sol";
import {SleepStatus} from "../src/effects/status/SleepStatus.sol";
import {ZapStatus} from "../src/effects/status/ZapStatus.sol";
import {TypeCalculator} from "../src/types/TypeCalculator.sol";

import {IEngineHook} from "../src/IEngineHook.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {BattleOfferLib} from "../src/matchmaker/BattleOfferLib.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";

import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

/// @notice Bit-faithful replay of the first real mainnet game we captured — MegaETH tx
///         0x5c5daa0edaaa79ac05a6915c36c393c03b172f0336a25917d96b811a5f1283e9 (CPU::executeGame,
///         27 batched turns, receipt 4,875,113 gas). Both sides ran an Embursa burn kit, so this
///         exercises the burn apply/escalate + switch-guard paths that Tier A/B of the gas audit
///         target. Teams (ids + facet-adjusted stats) and the 27 packed turn entries were read
///         off-chain from the real config (getBattle) + tx calldata; the turn RNG is keccak(p0Salt,
///         p1Salt) with NO battleKey dependency, so replaying the same salts reproduces the exact
///         battle here. Measured through engine.executeBatchedTurns (the same path the tx took) on
///         a VIRGIN storageKey and again on a REUSED (steady-state) one.
contract MainnetReplayGasTest is Test, SetupMons {
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

    // Real rosters from the mainnet config (getBattle). p1 is the CPU side.
    uint256[4] P0_IDS = [uint256(1), 5, 7, 6]; // Inutia, Sofabbi, Embursa, Pengym
    uint256[4] P1_IDS = [uint256(5), 7, 4, 7]; // Sofabbi, Embursa, Gorillax, Embursa

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
        gachaReg =
            new GachaTeamRegistry(4, 4, IEngine(address(engine)), IGachaRNG(address(0)), GachaTeamRegistry(address(0)));
        vm.setEnv("TYPE_CALCULATOR", vm.toString(address(tc)));
        vm.setEnv("OVERCLOCK", vm.toString(address(oc)));
        vm.setEnv("SLEEP_STATUS", vm.toString(address(sleepStatus)));
        vm.setEnv("PANIC_STATUS", vm.toString(address(panicStatus)));
        vm.setEnv("FROSTBITE_STATUS", vm.toString(address(frost)));
        vm.setEnv("BURN_STATUS", vm.toString(address(burn)));
        vm.setEnv("ZAP_STATUS", vm.toString(address(zap)));
        vm.setEnv("BLESSED_STATUS", vm.toString(address(blessed)));
        vm.setEnv("GACHA_TEAM_REGISTRY", vm.toString(address(gachaReg)));
        deployGhouliath(gachaReg);
        deployInutia(gachaReg);
        deployMalalien(gachaReg);
        deployIblivion(gachaReg);
        deployGorillax(gachaReg);
        deploySofabbi(gachaReg);
        deployPengym(gachaReg);
        deployEmbursa(gachaReg);
        deployVolthare(gachaReg);
        deployAurox(gachaReg);
        deployXmon(gachaReg);
        mgr = new SignedCommitManager(IEngine(address(engine)));
        maker = new SignedMatchmaker(engine);
        registry = new TestTeamRegistry();
    }

    function _buildTeam(uint256[4] memory ids, MonStats[4] memory logStats) internal view returns (Mon[] memory team) {
        team = new Mon[](4);
        for (uint256 i; i < 4; i++) {
            (, uint256[] memory moves, uint256[] memory abilities) = gachaReg.getMonData(ids[i]);
            team[i] = Mon({stats: logStats[i], ability: abilities.length > 0 ? abilities[0] : 0, moves: moves});
        }
    }

    function _mk(uint32 hp, uint32 stam, uint32 spe, uint32 atk, uint32 def, uint32 spa, uint32 spd, Type t1, Type t2)
        internal
        pure
        returns (MonStats memory)
    {
        return MonStats({
            hp: hp,
            stamina: stam,
            speed: spe,
            attack: atk,
            defense: def,
            specialAttack: spa,
            specialDefense: spd,
            type1: t1,
            type2: t2
        });
    }

    // Facet-adjusted stats straight from the mainnet config (getBattle).
    function _p0Stats() internal pure returns (MonStats[4] memory s) {
        s[0] = _mk(371, 5, 218, 179, 189, 183, 192, Type(9), Type(14));
        s[1] = _mk(333, 5, 167, 180, 211, 120, 282, Type(7), Type(14));
        s[2] = _mk(420, 5, 106, 141, 231, 190, 169, Type(4), Type(14));
        s[3] = _mk(371, 5, 156, 191, 191, 210, 172, Type(6), Type(14));
    }

    function _p1Stats() internal pure returns (MonStats[4] memory s) {
        s[0] = _mk(333, 5, 167, 189, 201, 126, 269, Type(7), Type(14));
        s[1] = _mk(420, 5, 106, 148, 220, 199, 161, Type(4), Type(14));
        s[2] = _mk(407, 5, 123, 317, 175, 117, 176, Type(2), Type(14));
        s[3] = _mk(420, 5, 106, 148, 220, 199, 161, Type(4), Type(14));
    }

    // The 27 packed turn entries from the tx calldata (verbatim wire words:
    // p0Move 8 | p0Extra 16 | p0Salt 104 | p1Move 8 | p1Extra 16 | p1Salt 104).
    function _entries() internal pure returns (uint256[] memory e) {
        e = new uint256[](27);
        e[0] = 0x17def5ffbebed718e42ad8d5437b700007d;
        e[1] = 0x17cc1b6f203a7394f49cc2cbe26000002;
        e[2] = 0x1491cabc6f3f9f098a351da75a6000303;
        e[3] = 0x2d351b8789b948ba4d526e455d0000001;
        e[4] = 0x28ea2c7b0d748d1437c53a9d7cb00007e;
        e[5] = 0x17e454fd4f7ab2d549f0ee2ab9000027d;
        e[6] = 0x27dd5e77a28073a9e5ee44929aab3000001;
        e[7] = 0x173a3d8262dc65be7dbf730c590000001;
        e[8] = 0x1643e54852af9503f2e8077ebf700007e;
        e[9] = 0x7ef094b6975e53293948e1203cc700037d;
        e[10] = 0x31feeeddb68b4b17088085a1080000002;
        e[11] = 0x339b37ca50816ee03f076911342000001;
        e[12] = 0x3e201cd1cb941d52bc67fec615d00007e;
        e[13] = 0x17d2888d001183e07bcc3f0a8e8e800017d;
        e[14] = 0x37d0000000000000000000000000000007e;
        e[15] = 0x1977f57d82dc43af2a2448c2f91000002;
        e[16] = 0x1a18f414979e79dece646b3ed36000101;
        e[17] = 0x2c444b8009fc7e49a768d6a26eb000003;
        e[18] = 0x2ff3f0d7e0548d4c90746470428000003;
        e[19] = 0x1a90ef652a7be14013561d2f88f00007e;
        e[20] = 0x7e1c013c0ff1e95c94cef042b98a00007d;
        e[21] = 0x22d9ec4faf7e71b4cbe49adbe55000002;
        e[22] = 0x2a2c344c9bc853f445b3c8df0cc00007e;
        e[23] = 0x7d0000000000000000000000000000007e;
        e[24] = 0xe0eb713b94ee96ba68b8c238c3000001;
        e[25] = 0x7e474f7f0d702737a8ad3337d43000037d;
        e[26] = 0x53d475e14cb30342bbd9209f1f000002;
    }

    function _startBattle() internal returns (bytes32 key) {
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(maker);
        address[] memory makersToRemove = new address[](0);
        vm.prank(p0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.prank(p1);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        bytes32 pairHash;
        (key, pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);
        // moveManager == the tx sender of executeBatchedTurns (mirrors the CPU relayer role).
        BattleOffer memory offer = BattleOffer({
            battle: Battle({
                p0: p0,
                p0TeamIndex: 0,
                p1: p1,
                p1TeamIndex: 0,
                p2: address(0),
                p2TeamIndex: 0,
                p3: address(0),
                p3TeamIndex: 0,
                teamRegistry: registry,
                rngOracle: IRandomnessOracle(address(0)),
                ruleset: IRuleset(INLINE_STAMINA_REGEN_RULESET),
                moveManager: address(mgr),
                matchmaker: maker,
                engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: nonce,
            battleMode: BATTLE_MODE_SINGLES
        });
        bytes32 digest = maker.hashTypedData(BattleOfferLib.hashBattleOfferForSigning(offer, 0));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(P0_PK, digest);
        vm.prank(p1);
        bytes[4] memory seatSigs;
        seatSigs[0] = abi.encodePacked(r, s, v);
        maker.startGame(offer, 0, seatSigs);
    }

    /// @dev Prod-faithful per-tx gas = on-chain exec + EIP-2028 calldata. The ABI encode is done by
    ///      the caller OUTSIDE the bracket (the relayer encodes off-chain); cold-starts storage first.
    function _replayOneTx(bytes32 battleKey, bool measure) internal returns (uint256 execGas) {
        uint256[] memory entries = _entries();
        bytes memory cd = abi.encodeCall(engine.executeBatchedTurns, (battleKey, entries));
        if (measure) {
            vm.cool(address(engine));
        }
        vm.prank(address(mgr));
        uint256 g0 = gasleft();
        (bool ok,) = address(engine).call(cd);
        uint256 raw = g0 - gasleft();
        require(ok, "replay reverted");
        if (measure) {
            execGas = raw + _calldataCost(cd) + TX_BASE;
        }
        engine.resetCallContext();
    }

    function _calldataCost(bytes memory cd) internal pure returns (uint256 cost) {
        for (uint256 i; i < cd.length; i++) {
            cost += cd[i] == bytes1(0) ? 4 : 16;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // R2.0 — turn-pipeline floor: same rosters/config, but the turns carry ZERO content
    // (turn 0 = send-ins, then NO_OPs: no moves, no effects, no damage). Prices the fixed
    // per-turn engine cost so the replay's per-turn self-gas can be split into floor vs content.
    // Raw exec gas, warm storage, no vm.cool — comparable to trace frame-self numbers.
    // ---------------------------------------------------------------------------------------------

    function _packEntry(uint8 p0Move, uint16 p0Extra, uint104 p0Salt, uint8 p1Move, uint16 p1Extra, uint104 p1Salt)
        internal
        pure
        returns (uint256)
    {
        return uint256(p0Move) | (uint256(p0Extra) << 8) | (uint256(p0Salt) << 24) | (uint256(p1Move) << 128)
            | (uint256(p1Extra) << 136) | (uint256(p1Salt) << 152);
    }

    function _noopEntries(uint256 n, uint256 saltBase) internal pure returns (uint256[] memory e) {
        e = new uint256[](n);
        for (uint256 i; i < n; i++) {
            e[i] =
                _packEntry(NO_OP_MOVE_INDEX, 0, uint104(saltBase + 2 * i), NO_OP_MOVE_INDEX, 0, uint104(saltBase + 2 * i + 1));
        }
    }

    function _execBatch(bytes32 battleKey, uint256[] memory entries) internal returns (uint256 raw) {
        bytes memory cd = abi.encodeCall(engine.executeBatchedTurns, (battleKey, entries));
        vm.prank(address(mgr));
        uint256 g0 = gasleft();
        (bool ok,) = address(engine).call(cd);
        raw = g0 - gasleft();
        require(ok, "batch reverted");
        engine.resetCallContext();
    }

    function test_noopFloor_batchedExecute() public {
        vm.warp(vm.getBlockTimestamp() + 1);

        // Battle 1: the real replay, unmeasured — completes and frees the storageKey.
        bytes32 key1 = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        _replayOneTx(key1, false);
        require(engine.getWinner(key1) != address(0), "warmup replay must finish");

        // Battle 2 (reused key): send-ins, then 1-noop and 25-noop batches to split
        // per-batch fixed cost from per-turn cost.
        bytes32 key2 = _startBattle();
        require(engine.getStorageKey(key1) == engine.getStorageKey(key2), "storageKey must be reused");
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256[] memory sw = new uint256[](1);
        sw[0] = _packEntry(SWITCH_MOVE_INDEX, 0, 11, SWITCH_MOVE_INDEX, 0, 12);
        uint256 switchTurn = _execBatch(key2, sw);
        uint256 t1 = _execBatch(key2, _noopEntries(1, 100));
        uint256 t25 = _execBatch(key2, _noopEntries(25, 300));
        uint256 perTurn = t25 / 25;

        // Battle 3 (reused again after forfeit): the whole no-op game in ONE batch, mirroring
        // the replay's shape (1 tx, 27 entries) for a like-for-like total. Capture the storage
        // key BEFORE forfeit — freeing deletes the battleKey mapping (identity fallback after).
        bytes32 liveStorageKey = engine.getStorageKey(key2);
        vm.prank(p0);
        engine.forfeit(key2);
        bytes32 key3 = _startBattle();
        require(engine.getStorageKey(key3) == liveStorageKey, "storageKey must be reused (3)");
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256[] memory whole = new uint256[](27);
        whole[0] = _packEntry(SWITCH_MOVE_INDEX, 0, 13, SWITCH_MOVE_INDEX, 0, 14);
        uint256[] memory noops = _noopEntries(26, 500);
        for (uint256 i; i < 26; i++) {
            whole[i + 1] = noops[i];
        }
        uint256 t27 = _execBatch(key3, whole);

        console.log("");
        console.log("=== R2.0 no-op floor (reused key, raw exec gas, warm) ===");
        console.log("  send-in turn (batch of 1)          :", switchTurn);
        console.log("  1 no-op turn (batch of 1)          :", t1);
        console.log("  25 no-op turns (one batch)         :", t25);
        console.log("  floor per no-op turn (t25/25)      :", perTurn);
        console.log("  per-batch fixed (t1 - floor)       :", t1 - perTurn);
        console.log("  whole no-op game, 1 batch of 27    :", t27);
    }

    function test_mainnetReplay_batchedExecute() public {
        vm.warp(vm.getBlockTimestamp() + 1);

        // ---- VIRGIN storageKey (fresh, every execute SSTORE is 0->nonzero) ----
        bytes32 key1 = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 virginGas = _replayOneTx(key1, true);
        address winner1 = engine.getWinner(key1);
        require(winner1 != address(0), "replay must reach game over (faithful)");

        // Reaching game over freed key1's storageKey back into the pool.
        // ---- REUSED storageKey (steady state, execute SSTOREs are nonzero->nonzero) ----
        bytes32 key2 = _startBattle();
        require(engine.getStorageKey(key1) == engine.getStorageKey(key2), "storageKey must be reused");
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 reusedGas = _replayOneTx(key2, true);
        require(engine.getWinner(key2) != address(0), "reused replay must also reach game over");

        console.log("");
        console.log("=== MAINNET replay (27 batched turns), prod config (inline regen) ===");
        console.log("  VIRGIN storageKey (cold, first battle) execGas :", virginGas);
        console.log("  REUSED storageKey (steady state)       execGas :", reusedGas);
        console.log("  virgin - reused (recycling saving)             :", virginGas - reusedGas);
    }
}
