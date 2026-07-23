// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {SetupMons} from "../script/SetupMons.s.sol";
import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {IAbility} from "../src/abilities/IAbility.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {IEffectResolver} from "../src/effects/IEffectResolver.sol";
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
import {IMoveResolver} from "../src/moves/IMoveResolver.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";

import {GasMeasure} from "./abstract/GasMeasure.sol";
import {sideWord} from "./abstract/SlotWire.sol";
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
contract MainnetReplayGasTest is Test, SetupMons, GasMeasure {
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

    struct ReplayCensus {
        EffectStorageTally effectStorage;
        StorageWorkingSet engineWorkingSet;
        CallBoundaryStorageTally callBoundaryStorage;
        EngineStorageCategoryTally storageCategories;
        MonStateStorageTally monStateStorage;
        MonStateFrameModel monStateFrame;
        PackedHeaderFrameModel packedHeaderFrame;
        uint256 roundStartCalls;
        uint256 roundEndCalls;
        uint256 afterMoveCalls;
        uint256 preDamageCalls;
        uint256 afterDamageCalls;
        uint256 updateStateCalls;
        uint256 moveDecisionCallbacks;
        uint256 statusClassCallbacks;
        uint256 lifecycleCalls;
        uint256 nonHookHeaderReadUpperBound;
        uint256 moveResolverCalls;
        uint256 moveResolverContinuations;
        uint256 effectResolverCalls;
        uint256 legacyMoveBoundaries;
        uint256 legacyAbilityBoundaries;
        uint256 legacyEffectBoundaries;
        uint256 legacyBoundaryUpperBound;
    }

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

    /// @dev Recorded analog of `_replayOneTx`. State-diff collection perturbs Foundry's raw gas
    ///      scalar, so this intentionally returns census data only and cannot become a KPI.
    function _replayOneTxRecorded(bytes32 battleKey) internal returns (Vm.AccountAccess[] memory accesses) {
        uint256[] memory entries = _entries();
        bytes memory cd = abi.encodeCall(engine.executeBatchedTurns, (battleKey, entries));
        vm.cool(address(engine));
        vm.startStateDiffRecording();
        vm.prank(address(mgr));
        (bool ok,) = address(engine).call(cd);
        require(ok, "recorded replay reverted");
        accesses = vm.stopAndReturnStateDiff();
        engine.resetCallContext();
    }

    function _calldataCost(bytes memory cd) internal pure returns (uint256 cost) {
        for (uint256 i; i < cd.length; i++) {
            cost += cd[i] == bytes1(0) ? 4 : 16;
        }
    }

    function _recordReplayCensus(
        string memory name,
        bytes32 battleKey,
        Vm.AccountAccess[] memory accesses,
        bytes32 storageKey,
        uint256 reusedGas
    ) internal returns (ReplayCensus memory c) {
        c.effectStorage = _effectStorageTally(accesses, address(engine), storageKey);
        c.engineWorkingSet = _storageWorkingSet(accesses, address(engine));
        c.callBoundaryStorage = _callBoundaryStorageTally(accesses, address(engine), address(mgr));
        c.storageCategories = _engineStorageCategoryTally(accesses, address(engine), battleKey, storageKey);
        c.monStateStorage = _monStateStorageTally(accesses, address(engine), storageKey);
        c.monStateFrame =
            _monStateFrameModel(accesses, address(engine), storageKey, _legacyBoundarySelectors());
        c.packedHeaderFrame = _packedHeaderFrameModel(
            accesses,
            address(engine),
            address(mgr),
            battleKey,
            storageKey,
            _legacyBoundarySelectors()
        );
        uint256 classifiedHeaderOps = c.storageCategories.reads[STORAGE_BATTLE_DATA]
            + c.storageCategories.writes[STORAGE_BATTLE_DATA]
            + c.storageCategories.reads[STORAGE_CONFIG_HEADER]
            + c.storageCategories.writes[STORAGE_CONFIG_HEADER];
        require(c.packedHeaderFrame.currentStorageOps == classifiedHeaderOps, "header frame census mismatch");
        require(
            c.storageCategories.reads[STORAGE_OTHER] + c.storageCategories.writes[STORAGE_OTHER] == 0,
            "unclassified Engine storage"
        );
        c.roundStartCalls = _countCalls(accesses, address(engine), address(0), IEffect.onRoundStart.selector);
        c.roundEndCalls = _countCalls(accesses, address(engine), address(0), IEffect.onRoundEnd.selector);
        c.afterMoveCalls = _countCalls(accesses, address(engine), address(0), IEffect.onAfterMove.selector)
            + _countCalls(accesses, address(engine), address(0), IEffectResolver.resolveEffect.selector);
        c.preDamageCalls = _countCalls(accesses, address(engine), address(0), IEffect.onPreDamage.selector);
        c.afterDamageCalls = _countCalls(accesses, address(engine), address(0), IEffect.onAfterDamage.selector);
        c.updateStateCalls = _countCalls(accesses, address(engine), address(0), IEffect.onUpdateMonState.selector);
        c.moveDecisionCallbacks =
            _countCalls(accesses, address(0), address(engine), IEngine.getMoveDecisionForSlot.selector);
        c.statusClassCallbacks = _countCalls(accesses, address(0), address(engine), IEngine.getMonStatusClass.selector);
        c.lifecycleCalls = c.roundStartCalls + c.roundEndCalls + c.afterMoveCalls + c.preDamageCalls
            + c.afterDamageCalls + c.updateStateCalls;
        c.nonHookHeaderReadUpperBound =
            c.effectStorage.headerReads > c.lifecycleCalls ? c.effectStorage.headerReads - c.lifecycleCalls : 0;
        c.moveResolverCalls = _countCalls(accesses, address(engine), address(0), IMoveResolver.resolveMove.selector);
        c.moveResolverContinuations = _countCallsWithNonzeroFirstArg(
            accesses, address(engine), address(0), IMoveResolver.resolveMove.selector
        );
        c.effectResolverCalls =
            _countCalls(accesses, address(engine), address(0), IEffectResolver.resolveEffect.selector);
        c.legacyMoveBoundaries = _countCalls(accesses, address(engine), address(0), IMoveSet.move.selector);
        c.legacyAbilityBoundaries =
            _countCalls(accesses, address(engine), address(0), IAbility.activateOnSwitch.selector);
        c.legacyEffectBoundaries = _legacyEffectBoundaryCount(accesses);
        c.legacyBoundaryUpperBound =
            c.legacyMoveBoundaries + c.legacyAbilityBoundaries + c.legacyEffectBoundaries;

        vm.snapshotValue(string.concat(name, "_execGas"), reusedGas);
        vm.snapshotValue(string.concat(name, "_effectHeaderReads"), c.effectStorage.headerReads);
        vm.snapshotValue(string.concat(name, "_effectDataReads"), c.effectStorage.dataReads);
        vm.snapshotValue(string.concat(name, "_effectHeaderWrites"), c.effectStorage.headerWrites);
        vm.snapshotValue(string.concat(name, "_effectDataWrites"), c.effectStorage.dataWrites);
        vm.snapshotValue(string.concat(name, "_engineStorageReads"), c.engineWorkingSet.reads);
        vm.snapshotValue(string.concat(name, "_engineStorageWrites"), c.engineWorkingSet.writes);
        vm.snapshotValue(
            string.concat(name, "_engineStorageUniqueTouchedSlots"), c.engineWorkingSet.uniqueTouchedSlots
        );
        vm.snapshotValue(
            string.concat(name, "_engineStorageUniqueWrittenSlots"), c.engineWorkingSet.uniqueWrittenSlots
        );
        vm.snapshotValue(
            string.concat(name, "_engineStorageLoadCommitFloorOps"), c.engineWorkingSet.loadCommitFloorOps
        );
        vm.snapshotValue(string.concat(name, "_engineStorageRemovableOps"), c.engineWorkingSet.removableOps);
        vm.snapshotValue(
            string.concat(name, "_engineRootStorageReads"), c.callBoundaryStorage.engineRootReads
        );
        vm.snapshotValue(
            string.concat(name, "_engineRootStorageWrites"), c.callBoundaryStorage.engineRootWrites
        );
        vm.snapshotValue(
            string.concat(name, "_engineCallbackStorageReads"), c.callBoundaryStorage.engineCallbackReads
        );
        vm.snapshotValue(
            string.concat(name, "_engineCallbackStorageWrites"), c.callBoundaryStorage.engineCallbackWrites
        );
        vm.snapshotValue(string.concat(name, "_externalStorageReads"), c.callBoundaryStorage.externalReads);
        vm.snapshotValue(string.concat(name, "_externalStorageWrites"), c.callBoundaryStorage.externalWrites);
        for (uint256 category; category < STORAGE_CATEGORY_COUNT; category++) {
            string memory prefix = string.concat(name, "_storage_", _storageCategoryName(category));
            vm.snapshotValue(string.concat(prefix, "Reads"), c.storageCategories.reads[category]);
            vm.snapshotValue(string.concat(prefix, "Writes"), c.storageCategories.writes[category]);
            vm.snapshotValue(string.concat(prefix, "UniqueTouched"), c.storageCategories.uniqueTouched[category]);
            vm.snapshotValue(string.concat(prefix, "UniqueWritten"), c.storageCategories.uniqueWritten[category]);
        }
        vm.snapshotValue(
            string.concat(name, "_storage_firstOtherSlot"), uint256(c.storageCategories.firstOtherSlot)
        );
        vm.snapshotValue(string.concat(name, "_roundStartCalls"), c.roundStartCalls);
        vm.snapshotValue(string.concat(name, "_roundEndCalls"), c.roundEndCalls);
        vm.snapshotValue(string.concat(name, "_afterMoveCalls"), c.afterMoveCalls);
        vm.snapshotValue(string.concat(name, "_preDamageCalls"), c.preDamageCalls);
        vm.snapshotValue(string.concat(name, "_afterDamageCalls"), c.afterDamageCalls);
        vm.snapshotValue(string.concat(name, "_updateStateCalls"), c.updateStateCalls);
        vm.snapshotValue(string.concat(name, "_moveDecisionCallbacks"), c.moveDecisionCallbacks);
        vm.snapshotValue(string.concat(name, "_statusClassCallbacks"), c.statusClassCallbacks);
        vm.snapshotValue(string.concat(name, "_lifecycleCalls"), c.lifecycleCalls);
        vm.snapshotValue(string.concat(name, "_nonHookHeaderReadUpperBound"), c.nonHookHeaderReadUpperBound);
        vm.snapshotValue(string.concat(name, "_monStateReads"), c.monStateStorage.reads);
        vm.snapshotValue(string.concat(name, "_monStateWrites"), c.monStateStorage.writes);
        vm.snapshotValue(string.concat(name, "_monStateUniqueTouchedLanes"), c.monStateStorage.uniqueTouchedLanes);
        vm.snapshotValue(string.concat(name, "_monStateUniqueWrittenLanes"), c.monStateStorage.uniqueWrittenLanes);
        vm.snapshotValue(string.concat(name, "_monStateFrameStorageOps"), c.monStateStorage.frameStorageOps);
        vm.snapshotValue(string.concat(name, "_monStateRemovableStorageOps"), c.monStateStorage.removableStorageOps);
        vm.snapshotValue(string.concat(name, "_monStateFrameLoadsWithLegacy"), c.monStateFrame.loads);
        vm.snapshotValue(string.concat(name, "_monStateFrameCommitsWithLegacy"), c.monStateFrame.commits);
        vm.snapshotValue(string.concat(name, "_monStateFrameReloadedLanes"), c.monStateFrame.reloadedLanes);
        vm.snapshotValue(string.concat(name, "_monStateDirtyFlushBoundaries"), c.monStateFrame.dirtyFlushBoundaries);
        vm.snapshotValue(
            string.concat(name, "_monStateCleanInvalidationBoundaries"), c.monStateFrame.cleanInvalidationBoundaries
        );
        vm.snapshotValue(
            string.concat(name, "_monStateFrameStorageOpsWithLegacy"), c.monStateFrame.modeledStorageOps
        );
        vm.snapshotValue(
            string.concat(name, "_monStateRemovableStorageOpsWithLegacy"), c.monStateFrame.removableStorageOps
        );
        vm.snapshotValue(string.concat(name, "_headerFrameLoadsWithLegacy"), c.packedHeaderFrame.loads);
        vm.snapshotValue(string.concat(name, "_headerFrameCommitsWithLegacy"), c.packedHeaderFrame.commits);
        vm.snapshotValue(
            string.concat(name, "_headerFrameCallbackPassthroughOps"),
            c.packedHeaderFrame.callbackPassthroughOps
        );
        vm.snapshotValue(string.concat(name, "_headerFrameReloadedWords"), c.packedHeaderFrame.reloadedWords);
        vm.snapshotValue(
            string.concat(name, "_headerFrameDirtyFlushBoundaries"),
            c.packedHeaderFrame.dirtyFlushBoundaries
        );
        vm.snapshotValue(
            string.concat(name, "_headerFrameCleanInvalidationBoundaries"),
            c.packedHeaderFrame.cleanInvalidationBoundaries
        );
        vm.snapshotValue(
            string.concat(name, "_headerFrameStorageOpsWithLegacy"), c.packedHeaderFrame.modeledStorageOps
        );
        vm.snapshotValue(
            string.concat(name, "_headerFrameRemovableStorageOpsWithLegacy"),
            c.packedHeaderFrame.removableStorageOps
        );
        vm.snapshotValue(string.concat(name, "_moveResolverCalls"), c.moveResolverCalls);
        vm.snapshotValue(string.concat(name, "_moveResolverContinuations"), c.moveResolverContinuations);
        vm.snapshotValue(string.concat(name, "_effectResolverCalls"), c.effectResolverCalls);
        vm.snapshotValue(string.concat(name, "_legacyMoveBoundaries"), c.legacyMoveBoundaries);
        vm.snapshotValue(string.concat(name, "_legacyAbilityBoundaries"), c.legacyAbilityBoundaries);
        vm.snapshotValue(string.concat(name, "_legacyEffectBoundaries"), c.legacyEffectBoundaries);
        vm.snapshotValue(string.concat(name, "_legacyBoundaryUpperBound"), c.legacyBoundaryUpperBound);

        assertGt(c.effectStorage.headerReads, 0, "effect header census must be live");
        assertGt(c.roundEndCalls, 0, "round-end census must be live");
        assertGt(c.afterMoveCalls, 0, "after-move census must be live");
        assertGt(c.monStateStorage.reads, 0, "mon-state census must be live");
    }

    /// @dev Every mutating legacy effect hook is a conservative frame flush/invalidation boundary.
    ///      This is an upper bound: consecutive calls with no intervening dirty lane need not flush.
    function _legacyEffectBoundaryCount(Vm.AccountAccess[] memory accesses) private view returns (uint256 count) {
        count = _countCalls(accesses, address(engine), address(0), IEffect.shouldApply.selector);
        count += _countCalls(accesses, address(engine), address(0), IEffect.onRoundStart.selector);
        count += _countCalls(accesses, address(engine), address(0), IEffect.onRoundEnd.selector);
        count += _countCalls(accesses, address(engine), address(0), IEffect.onMonSwitchIn.selector);
        count += _countCalls(accesses, address(engine), address(0), IEffect.onMonSwitchOut.selector);
        count += _countCalls(accesses, address(engine), address(0), IEffect.onAfterDamage.selector);
        count += _countCalls(accesses, address(engine), address(0), IEffect.onAfterMove.selector);
        count += _countCalls(accesses, address(engine), address(0), IEffect.onUpdateMonState.selector);
        count += _countCalls(accesses, address(engine), address(0), IEffect.onPreDamage.selector);
        count += _countCalls(accesses, address(engine), address(0), IEffect.onApply.selector);
        count += _countCalls(accesses, address(engine), address(0), IEffect.onRemove.selector);
    }

    function _legacyBoundarySelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](13);
        selectors[0] = IMoveSet.move.selector;
        selectors[1] = IAbility.activateOnSwitch.selector;
        selectors[2] = IEffect.shouldApply.selector;
        selectors[3] = IEffect.onRoundStart.selector;
        selectors[4] = IEffect.onRoundEnd.selector;
        selectors[5] = IEffect.onMonSwitchIn.selector;
        selectors[6] = IEffect.onMonSwitchOut.selector;
        selectors[7] = IEffect.onAfterDamage.selector;
        selectors[8] = IEffect.onAfterMove.selector;
        selectors[9] = IEffect.onUpdateMonState.selector;
        selectors[10] = IEffect.onPreDamage.selector;
        selectors[11] = IEffect.onApply.selector;
        selectors[12] = IEffect.onRemove.selector;
    }

    function _logFrameCensus(ReplayCensus memory census) private pure {
        console.log(
            "  Engine storage reads/writes                      :",
            census.engineWorkingSet.reads,
            census.engineWorkingSet.writes
        );
        console.log(
            "  Engine unique touched/written slots              :",
            census.engineWorkingSet.uniqueTouchedSlots,
            census.engineWorkingSet.uniqueWrittenSlots
        );
        console.log(
            "  Engine current/floor/removable storage ops        :",
            census.engineWorkingSet.reads + census.engineWorkingSet.writes,
            census.engineWorkingSet.loadCommitFloorOps,
            census.engineWorkingSet.removableOps
        );
        console.log(
            "  Engine root reads/writes                          :",
            census.callBoundaryStorage.engineRootReads,
            census.callBoundaryStorage.engineRootWrites
        );
        console.log(
            "  Engine callback reads/writes                      :",
            census.callBoundaryStorage.engineCallbackReads,
            census.callBoundaryStorage.engineCallbackWrites
        );
        console.log(
            "  mechanic-owned storage reads/writes               :",
            census.callBoundaryStorage.externalReads,
            census.callBoundaryStorage.externalWrites
        );
        console.log("  storage categories: reads / writes / unique / unique-written");
        _logStorageCategory("    other/unclassified", census.storageCategories, STORAGE_OTHER);
        _logStorageCategory("    shell/allocator", census.storageCategories, STORAGE_SHELL);
        _logStorageCategory("    BattleData", census.storageCategories, STORAGE_BATTLE_DATA);
        _logStorageCategory("    config header", census.storageCategories, STORAGE_CONFIG_HEADER);
        _logStorageCategory("    static catalog/team", census.storageCategories, STORAGE_STATIC_CATALOG);
        _logStorageCategory("    MonState", census.storageCategories, STORAGE_MON_STATE);
        _logStorageCategory("    effects/hooks", census.storageCategories, STORAGE_EFFECTS);
        _logStorageCategory("    stat boosts", census.storageCategories, STORAGE_BOOSTS);
        _logStorageCategory("    global KV", census.storageCategories, STORAGE_GLOBAL_KV);
        if (census.storageCategories.firstOtherSlot != bytes32(0)) {
            console.log("    first unclassified slot");
            console.logBytes32(census.storageCategories.firstOtherSlot);
        }
        console.log(
            "  packed-header current/modeled/removable ops       :",
            census.packedHeaderFrame.currentStorageOps,
            census.packedHeaderFrame.modeledStorageOps,
            census.packedHeaderFrame.removableStorageOps
        );
        console.log(
            "  packed-header loads/commits/callback passthrough  :",
            census.packedHeaderFrame.loads,
            census.packedHeaderFrame.commits,
            census.packedHeaderFrame.callbackPassthroughOps
        );
        console.log(
            "  packed-header reloads / dirty flushes / clean bars:",
            census.packedHeaderFrame.reloadedWords,
            census.packedHeaderFrame.dirtyFlushBoundaries,
            census.packedHeaderFrame.cleanInvalidationBoundaries
        );
        console.log(
            "  MonState reads/writes                            :",
            census.monStateStorage.reads,
            census.monStateStorage.writes
        );
        console.log(
            "  MonState unique touched/written lanes            :",
            census.monStateStorage.uniqueTouchedLanes,
            census.monStateStorage.uniqueWrittenLanes
        );
        console.log(
            "  MonState current/frame/removable storage ops      :",
            census.monStateStorage.currentStorageOps,
            census.monStateStorage.frameStorageOps,
            census.monStateStorage.removableStorageOps
        );
        console.log(
            "  frame loads/commits with legacy boundaries       :",
            census.monStateFrame.loads,
            census.monStateFrame.commits
        );
        console.log(
            "  frame reloaded lanes / dirty flushes / clean bars :",
            census.monStateFrame.reloadedLanes,
            census.monStateFrame.dirtyFlushBoundaries,
            census.monStateFrame.cleanInvalidationBoundaries
        );
        console.log(
            "  with-legacy frame/removable storage ops           :",
            census.monStateFrame.modeledStorageOps,
            census.monStateFrame.removableStorageOps
        );
        console.log(
            "  resolver move/continuation/effect calls           :",
            census.moveResolverCalls,
            census.moveResolverContinuations,
            census.effectResolverCalls
        );
        console.log(
            "  legacy move/ability/effect boundary upper bound   :",
            census.legacyMoveBoundaries,
            census.legacyAbilityBoundaries,
            census.legacyEffectBoundaries
        );
        console.log("  total legacy boundary upper bound                 :", census.legacyBoundaryUpperBound);
    }

    function _logStorageCategory(string memory label, EngineStorageCategoryTally memory t, uint256 category)
        private
        pure
    {
        console.log(label, t.reads[category], t.writes[category]);
        console.log("      unique touched/written", t.uniqueTouched[category], t.uniqueWritten[category]);
    }

    function _storageCategoryName(uint256 category) private pure returns (string memory) {
        if (category == STORAGE_SHELL) return "shell";
        if (category == STORAGE_BATTLE_DATA) return "battleData";
        if (category == STORAGE_CONFIG_HEADER) return "configHeader";
        if (category == STORAGE_STATIC_CATALOG) return "staticCatalog";
        if (category == STORAGE_MON_STATE) return "monState";
        if (category == STORAGE_EFFECTS) return "effects";
        if (category == STORAGE_BOOSTS) return "boosts";
        if (category == STORAGE_GLOBAL_KV) return "globalKV";
        return "other";
    }

    function _setFirstDoublesReplayTeams() private {
        uint256[] memory p0Ids = new uint256[](4);
        p0Ids[0] = 4; // Gorillax
        p0Ids[1] = 2; // Malalien
        p0Ids[2] = 5; // Sofabbi
        p0Ids[3] = 11; // Ekineki
        uint256[] memory p1Ids = new uint256[](4);
        p1Ids[0] = 0; // Ghouliath
        p1Ids[1] = 3; // Iblivion
        p1Ids[2] = 10; // Xmon
        p1Ids[3] = 5; // Sofabbi
        uint8[] memory p0Facets = new uint8[](4);
        uint8[] memory p1Facets = new uint8[](4);
        for (uint256 i; i < 4; i++) {
            p0Facets[i] = 6;
        }
        gachaReg.setTeamForUser(p0, 0, p0Ids, p0Facets);
        gachaReg.setTeamForUser(p1, 0, p1Ids, p1Facets);
    }

    function _startDoublesBattle() private returns (bytes32 key) {
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(maker);
        vm.prank(p0);
        engine.updateMatchmakers(makersToAdd, new address[](0));
        vm.prank(p1);
        engine.updateMatchmakers(makersToAdd, new address[](0));
        bytes32 pairHash;
        (key, pairHash) = engine.computeBattleKey(p0, p1);
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
                teamRegistry: gachaReg,
                rngOracle: IRandomnessOracle(address(0)),
                ruleset: IRuleset(INLINE_STAMINA_REGEN_RULESET),
                moveManager: address(mgr),
                matchmaker: maker,
                engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: engine.pairHashNonces(pairHash),
            battleMode: BATTLE_MODE_DOUBLES
        });
        bytes32 digest = maker.hashTypedData(BattleOfferLib.hashBattleOfferForSigning(offer, 0));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(P0_PK, digest);
        bytes[4] memory seatSigs;
        seatSigs[0] = abi.encodePacked(r, s, v);
        vm.prank(p1);
        maker.startGame(offer, 0, seatSigs);
    }

    function _firstDoublesReplayEntries() private pure returns (uint256[] memory e) {
        e = new uint256[](20);
        e[0] = sideWord(SWITCH_MOVE_INDEX, 1, SWITCH_MOVE_INDEX, 3, 629152483201830402240141);
        e[1] = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, 0);
        e[2] = sideWord(1, 32768, 0, 32768, 288092756437916069539032);
        e[3] = sideWord(1, 4096, 1, 0, 0);
        e[4] = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, 0);
        e[5] = sideWord(NO_OP_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 2, 0);
        e[6] = sideWord(1, 32768, 0, 32768, 874957430843907341896228);
        e[7] = sideWord(1, 4096, 1, 4096, 0);
        e[8] = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, 0);
        e[9] = sideWord(NO_OP_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 3, 0);
        e[10] = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, 1115499015655134625153807);
        e[11] = sideWord(3, 4096, 2, 8192, 0);
        e[12] = sideWord(SWITCH_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, 74943448586572800650145);
        e[13] = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, 0);
        e[14] = sideWord(2, 32768, 0, 16384, 315825775983314630690957);
        e[15] = sideWord(3, 8192, NO_OP_MOVE_INDEX, 0, 0);
        e[16] = sideWord(2, 32768, NO_OP_MOVE_INDEX, 0, 363940942254872708793045);
        e[17] = sideWord(3, 4096, 3, 0, 0);
        e[18] = sideWord(2, 32768, 0, 32768, 191897147809779057662496);
        e[19] = sideWord(3, 4096, 2, 4096, 0);
    }

    function _replayDoublesOneTx(bytes32 battleKey, bool measure) private returns (uint256 execGas) {
        uint256[] memory entries = _firstDoublesReplayEntries();
        bytes memory cd = abi.encodeCall(engine.executeBatchedSlotTurns, (battleKey, entries));
        if (measure) {
            vm.cool(address(engine));
        }
        vm.prank(address(mgr));
        uint256 g0 = gasleft();
        (bool ok,) = address(engine).call(cd);
        uint256 raw = g0 - gasleft();
        require(ok, "doubles replay reverted");
        if (measure) {
            execGas = raw + _calldataCost(cd) + TX_BASE;
        }
        engine.resetCallContext();
    }

    function _replayDoublesRecorded(bytes32 battleKey) private returns (Vm.AccountAccess[] memory accesses) {
        uint256[] memory entries = _firstDoublesReplayEntries();
        bytes memory cd = abi.encodeCall(engine.executeBatchedSlotTurns, (battleKey, entries));
        vm.cool(address(engine));
        vm.startStateDiffRecording();
        vm.prank(address(mgr));
        (bool ok,) = address(engine).call(cd);
        require(ok, "recorded doubles replay reverted");
        accesses = vm.stopAndReturnStateDiff();
        engine.resetCallContext();
    }

    function _finishIncompleteReplay(bytes32 battleKey) private {
        if (engine.getWinner(battleKey) == address(0)) {
            vm.prank(p0);
            engine.forfeit(battleKey);
        }
    }

    function _assertExactEffectStepLanes(bytes32 battleKey) private view {
        (BattleConfigView memory cfg,) = engine.getBattle(battleKey);
        for (uint256 side; side < 2; side++) {
            EffectInstance[][] memory effects = side == 0 ? cfg.p0Effects : cfg.p1Effects;
            for (uint256 mon; mon < effects.length; mon++) {
                uint16 expected;
                for (uint256 i; i < effects[mon].length; i++) {
                    expected |= effects[mon][i].stepsBitmap;
                }
                uint256 shift = ((side << 3) | mon) << 4;
                assertEq(uint16(cfg.playerEffectStepsByMon >> shift), expected, "effect-step lane mismatch");
            }
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
            e[i] = _packEntry(
                NO_OP_MOVE_INDEX, 0, uint104(saltBase + 2 * i), NO_OP_MOVE_INDEX, 0, uint104(saltBase + 2 * i + 1)
            );
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

        vm.snapshotValue("SinglesFloor_SendIn_rawGas", switchTurn);
        vm.snapshotValue("SinglesFloor_OneNoop_rawGas", t1);
        vm.snapshotValue("SinglesFloor_25Noops_rawGas", t25);
        vm.snapshotValue("SinglesFloor_Noop_perTurn", perTurn);
        vm.snapshotValue("SinglesFloor_BatchFixed", t1 - perTurn);
        vm.snapshotValue("SinglesFloor_Whole27_rawGas", t27);

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

        // State-diff recording perturbs Foundry's raw gas scalar, so collect the census on a
        // third, storage-congruent replay and never use its gas result as a KPI.
        bytes32 recycledStorageKey = engine.getStorageKey(key1);
        bytes32 key3 = _startBattle();
        require(engine.getStorageKey(key3) == recycledStorageKey, "storageKey must be reused for census");
        vm.warp(vm.getBlockTimestamp() + 1);
        Vm.AccountAccess[] memory accesses = _replayOneTxRecorded(key3);
        require(engine.getWinner(key3) != address(0), "census replay must also reach game over");
        ReplayCensus memory census =
            _recordReplayCensus("MainnetReplay_Reused", key3, accesses, recycledStorageKey, reusedGas);

        console.log("");
        console.log("=== MAINNET replay (27 batched turns), prod config (inline regen) ===");
        console.log("  VIRGIN storageKey (cold, first battle) execGas :", virginGas);
        console.log("  REUSED storageKey (steady state)       execGas :", reusedGas);
        console.log("  virgin - reused (recycling saving)             :", virginGas - reusedGas);
        console.log(
            "  player effect header/data reads                :",
            census.effectStorage.headerReads,
            census.effectStorage.dataReads
        );
        console.log(
            "  hooks RoundStart/RoundEnd/AfterMove             :",
            census.roundStartCalls,
            census.roundEndCalls,
            census.afterMoveCalls
        );
        console.log(
            "  hooks PreDamage/AfterDamage/UpdateState         :",
            census.preDamageCalls,
            census.afterDamageCalls,
            census.updateStateCalls
        );
        console.log(
            "  callbacks moveDecision/statusClass              :",
            census.moveDecisionCallbacks,
            census.statusClassCallbacks
        );
        console.log("  non-hook effect header read upper bound          :", census.nonHookHeaderReadUpperBound);
        _logFrameCensus(census);
    }

    /// @dev Real submitted move/target/salt sequence from `replays.txt`. The historical deployed
    ///      catalog state is not yet available locally, so this is an action-mix gas replay rather
    ///      than a winner-faithful replay. It intentionally receives the same reused-key+census
    ///      treatment as singles; forfeit only recycles the key after the measured bracket.
    function test_mainnetDoublesReplay1_batchedExecute() public {
        _setFirstDoublesReplayTeams();
        vm.warp(vm.getBlockTimestamp() + 1);

        bytes32 key1 = _startDoublesBattle();
        bytes32 recycledStorageKey = engine.getStorageKey(key1);
        vm.warp(vm.getBlockTimestamp() + 1);
        _replayDoublesOneTx(key1, false);
        assertEq(engine.getTurnIdForBattleState(key1), 10, "all real doubles turns execute");
        _finishIncompleteReplay(key1);

        bytes32 key2 = _startDoublesBattle();
        require(engine.getStorageKey(key2) == recycledStorageKey, "doubles storageKey must be reused");
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 reusedGas = _replayDoublesOneTx(key2, true);
        assertEq(engine.getTurnIdForBattleState(key2), 10, "all reused doubles turns execute");
        _finishIncompleteReplay(key2);

        bytes32 key3 = _startDoublesBattle();
        require(engine.getStorageKey(key3) == recycledStorageKey, "doubles storageKey must be reused for census");
        (BattleConfigView memory freshCfg,) = engine.getBattle(key3);
        assertEq(freshCfg.playerEffectStepsByMon, 0, "recycled step lanes must reset");
        vm.warp(vm.getBlockTimestamp() + 1);
        Vm.AccountAccess[] memory accesses = _replayDoublesRecorded(key3);
        assertEq(engine.getTurnIdForBattleState(key3), 10, "all census doubles turns execute");
        _assertExactEffectStepLanes(key3);
        ReplayCensus memory census =
            _recordReplayCensus("MainnetDoublesReplay1_Reused", key3, accesses, recycledStorageKey, reusedGas);
        _finishIncompleteReplay(key3);

        console.log("");
        console.log("=== MAINNET doubles replay 1 (10 submitted turns, reused key) ===");
        console.log("  execGas                                           :", reusedGas);
        console.log(
            "  player effect header/data reads                  :",
            census.effectStorage.headerReads,
            census.effectStorage.dataReads
        );
        console.log(
            "  hooks RoundStart/RoundEnd/AfterMove               :",
            census.roundStartCalls,
            census.roundEndCalls,
            census.afterMoveCalls
        );
        console.log(
            "  callbacks moveDecision/statusClass                :",
            census.moveDecisionCallbacks,
            census.statusClassCallbacks
        );
        console.log("  non-hook effect header read upper bound            :", census.nonHookHeaderReadUpperBound);
        _logFrameCensus(census);
    }
}
