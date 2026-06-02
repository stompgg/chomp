// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import {Vm} from "../lib/forge-std/src/Vm.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {IValidator} from "../src/IValidator.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";
import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";

import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";
import {GasMeasure} from "./abstract/GasMeasure.sol";

/// @notice Step-0 measurement for the startBattle optimization (PLAN_STARTBATTLE.md).
///         Measures Engine.startBattle (via matchmaker confirmBattle) against the REAL
///         GachaTeamRegistry with a facet on every mon, so getTeams does the full facet-delta fold.
///         Reports a per-account (engine = team-store/clear, registry = getTeams) SSTORE/SLOAD
///         breakdown for two regimes:
///           - COLD:  first-ever storageKey (z->nz everywhere) — the rare first battle.
///           - WARM:  recycled storageKey holding a DIFFERENT prior team (the production steady
///                    state). Mons have DISTINCT data + the CPU team is swapped between battles, so
///                    the recycled config is genuinely overwritten (nz->nz), not no-op'd.
///         4 mons x 4 moves to match prod team size.
contract StartBattleGasTest is Test, GasMeasure {
    address constant ALICE = address(0x1);
    address constant CPU = address(0xC9);
    uint256 constant MONS_PER_TEAM = 4;
    uint256 constant MOVES_PER_MON = 4;
    uint256 constant TIMEOUT = 10;
    uint256 constant POOL = 12; // mon ids 0..11 (ALICE {0,3,4,5}, CPU-T1 {1,2,6,7}, CPU-T2 {8,9,10,11})

    Engine engine;
    GachaTeamRegistry registry;
    MockGachaRNG mockRNG;
    MockRandomnessOracle mockOracle;
    DefaultCommitManager commitManager;
    DefaultMatchmaker matchmaker;

    uint256[] aliceTeam;
    uint96 cpuPhantomIndex;

    function setUp() public {
        vm.warp(2 days); // gacha day-bucketed logic needs a non-zero day

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, TIMEOUT);
        mockOracle = new MockRandomnessOracle();
        mockRNG = new MockGachaRNG();
        registry = new GachaTeamRegistry(MONS_PER_TEAM, MOVES_PER_MON, engine, mockRNG, GachaTeamRegistry(address(0)));
        commitManager = new DefaultCommitManager(engine);
        matchmaker = new DefaultMatchmaker(engine);

        while (registry.getQuestPoolLength() > 0) registry.removeQuest(0);

        address[] memory none = new address[](0);
        bytes32[] memory noK = new bytes32[](0);
        bytes32[] memory noV = new bytes32[](0);

        // DISTINCT data per mon (stats vary by id; synthetic distinct move/ability refs) so storing a
        // DIFFERENT team over a recycled key overwrites config with different values (nz->nz), which is
        // what the production steady state actually pays — not the same-team no-op artifact.
        for (uint256 i; i < POOL; ++i) {
            MonStats memory s = MonStats({
                hp: uint32(200 + i * 7), stamina: uint32(8 + i), speed: uint32(50 + i * 3),
                attack: uint32(40 + i * 2), defense: uint32(40 + i), specialAttack: uint32(45 + i),
                specialDefense: uint32(42 + i), type1: Type.Fire, type2: Type.None
            });
            uint256[] memory mvs = new uint256[](MOVES_PER_MON);
            for (uint256 j; j < MOVES_PER_MON; ++j) mvs[j] = uint256(uint160(0x100000 + i * 16 + j));
            uint256[] memory abl = new uint256[](1);
            abl[0] = uint256(uint160(0x200000 + i));
            registry.createMon(i, s, mvs, abl, noK, noV);
        }

        // Deployer (this) is the exp assigner.
        address[] memory me = new address[](1);
        me[0] = address(this);
        registry.setAssigners(me, none);

        // ALICE: firstRoll(0) -> owns {0,3,4,5}; build that team.
        vm.prank(ALICE);
        registry.firstRoll(0);
        aliceTeam = new uint256[](MONS_PER_TEAM);
        aliceTeam[0] = 0; aliceTeam[1] = 3; aliceTeam[2] = 4; aliceTeam[3] = 5;
        vm.prank(ALICE);
        registry.createTeam(aliceTeam);

        // Max exp on every ALICE mon -> unlocks all 12 facets -> assign facet 1 to each.
        uint256[] memory amounts = new uint256[](MONS_PER_TEAM);
        uint8[] memory facetOnes = new uint8[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; ++i) { amounts[i] = 65535; facetOnes[i] = 1; }
        registry.assignExp(ALICE, aliceTeam, amounts);
        vm.prank(ALICE);
        registry.assignFacets(aliceTeam, facetOnes);

        // CPU phantom: whitelist + initial team T1 = {1,2,6,7}, facet 1 on every slot.
        address[] memory allow = new address[](1);
        allow[0] = CPU;
        registry.setWhitelistedOpponents(allow, none);
        cpuPhantomIndex = uint96(uint16(uint160(ALICE)));
        _setCpuTeam([uint256(1), 2, 6, 7]);

        // Authorize matchmaker for both sides.
        address[] memory mk = new address[](1);
        mk[0] = address(matchmaker);
        vm.prank(ALICE);
        engine.updateMatchmakers(mk, none);
        vm.prank(CPU);
        engine.updateMatchmakers(mk, none);
    }

    function _setCpuTeam(uint256[4] memory mons) internal {
        uint256[] memory cpuMons = new uint256[](MONS_PER_TEAM);
        uint8[] memory cpuFacets = new uint8[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; ++i) { cpuMons[i] = mons[i]; cpuFacets[i] = 1; }
        vm.prank(ALICE);
        registry.setOpponentTeam(CPU, cpuMons, cpuFacets);
    }

    /// @dev propose + accept (unmeasured); caller measures confirmBattle (-> startBattle) alone.
    function _proposeAndAccept(bytes32 salt) internal returns (bytes32 battleKey) {
        uint96 ti = 0;
        uint256[] memory ids = registry.getMonRegistryIndicesForTeam(ALICE, ti);
        bytes32 teamHash = keccak256(abi.encodePacked(salt, ti, ids));
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE, p0TeamIndex: ti, p0TeamHash: teamHash,
            p1: CPU, p1TeamIndex: cpuPhantomIndex,
            teamRegistry: registry, validator: IValidator(address(0)),
            rngOracle: mockOracle, ruleset: IRuleset(address(0)),
            moveManager: address(commitManager), matchmaker: matchmaker, engineHooks: new IEngineHook[](0)
        });
        vm.prank(ALICE);
        battleKey = matchmaker.proposeBattle(proposal);
        bytes32 integrity = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.prank(CPU);
        matchmaker.acceptBattle(battleKey, cpuPhantomIndex, integrity);
    }

    function _coolAll4() internal {
        vm.cool(address(engine));
        vm.cool(address(registry));
        vm.cool(address(matchmaker));
        vm.cool(address(commitManager));
    }

    function _accountTally(Vm.AccountAccess[] memory acc, address who)
        internal pure
        returns (uint256 sstores, uint256 zToNz, uint256 nzToNz, uint256 noop, uint256 sloads)
    {
        for (uint256 i; i < acc.length; i++) {
            if (acc[i].account != who) continue;
            Vm.StorageAccess[] memory sa = acc[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                if (sa[j].isWrite) {
                    sstores++;
                    if (sa[j].previousValue == bytes32(0) && sa[j].newValue != bytes32(0)) zToNz++;
                    else if (sa[j].previousValue == sa[j].newValue) noop++;
                    else nzToNz++;
                } else {
                    sloads++;
                }
            }
        }
    }

    function _report(string memory label, string memory snapName, Vm.AccountAccess[] memory acc, uint256 gasUsed)
        internal
    {
        Tally memory t = _tally(acc);
        (uint256 eS, uint256 eZ, uint256 eN, uint256 eNo, uint256 eL) = _accountTally(acc, address(engine));
        (,,,, uint256 rL) = _accountTally(acc, address(registry));
        _snapScenario(snapName, t, gasUsed);
        console.log("");
        console.log(label);
        console.log("  confirmBattle->startBattle gas         :", gasUsed);
        console.log("  ENGINE  SSTORE total                   :", eS);
        console.log("  ENGINE  SSTORE z->nz / nz->nz / noop   :", eZ, eN, eNo);
        console.log("  ENGINE  SLOAD  total                   :", eL);
        console.log("  REGISTRY SLOAD (getTeams)              :", rL);
        console.log("  ALL: SLOAD cold / warm                 :", t.coldSload, t.warmSload);
    }

    function test_startBattle_breakdown() public {
        // ---- COLD: first battle on a fresh storageKey (z->nz everywhere). CPU team = T1 {1,2,6,7}. ----
        bytes32 k1 = _proposeAndAccept("s1");
        _coolAll4();
        vm.startStateDiffRecording();
        uint256 g1 = gasleft();
        vm.prank(ALICE);
        matchmaker.confirmBattle(k1, "s1", 0);
        uint256 coldGas = g1 - gasleft();
        Vm.AccountAccess[] memory acc1 = vm.stopAndReturnStateDiff();
        bytes32 sk1 = engine.getStorageKey(k1);
        _report("=== COLD (first-ever key, z->nz) ===", "StartBattle_Cold", acc1, coldGas);

        // Free the key; swap the CPU team to DISTINCT mons T2 {8,9,10,11} so the recycled config is
        // genuinely overwritten on the p1 (CPU) side.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        engine.end(k1);
        engine.resetCallContext();
        _setCpuTeam([uint256(8), 9, 10, 11]);

        // ---- WARM STEADY: recycled key; CPU side stores DIFFERENT mons -> nz->nz. ALICE side is the
        //      same team -> no-op. So the CPU side (28 slots) shows the true per-slot nz->nz team-store
        //      cost; a fully-different matchup (both sides) is ~2x that delta. ----
        bytes32 k2 = _proposeAndAccept("s2");
        _coolAll4();
        vm.startStateDiffRecording();
        uint256 g2 = gasleft();
        vm.prank(ALICE);
        matchmaker.confirmBattle(k2, "s2", 0);
        uint256 warmGas = g2 - gasleft();
        Vm.AccountAccess[] memory acc2 = vm.stopAndReturnStateDiff();
        require(engine.getStorageKey(k2) == sk1, "storageKey reuse (warm steady)");
        _report("=== WARM STEADY (recycled key, CPU team differs -> CPU-side nz->nz) ===", "StartBattle_WarmSteady", acc2, warmGas);

        // ---- WARM SAME: recycle again, CPU team UNCHANGED (T2) -> team-store all no-op. Baseline so
        //      (WARM_DIFF - WARM_SAME) isolates the 28-slot CPU team-store nz->nz cost. ----
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        engine.end(k2);
        engine.resetCallContext();
        bytes32 k3 = _proposeAndAccept("s3");
        _coolAll4();
        vm.startStateDiffRecording();
        uint256 g3 = gasleft();
        vm.prank(ALICE);
        matchmaker.confirmBattle(k3, "s3", 0);
        uint256 sameGas = g3 - gasleft();
        Vm.AccountAccess[] memory acc3 = vm.stopAndReturnStateDiff();
        require(engine.getStorageKey(k3) == sk1, "storageKey reuse (warm same)");
        _report("=== WARM SAME (recycled key, CPU team unchanged -> team-store all no-op) ===", "StartBattle_WarmSame", acc3, sameGas);

        console.log("");
        console.log("  28-slot CPU team-store nz->nz cost (WARM_DIFF - WARM_SAME) :", warmGas - sameGas);
        console.log("  => fully-different matchup team-store ~= WARM_SAME + 2x that delta");
    }
}
