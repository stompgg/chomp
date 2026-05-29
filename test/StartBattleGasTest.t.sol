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
import {TestMoveFactory} from "./mocks/TestMoveFactory.sol";
import {GasMeasure} from "./abstract/GasMeasure.sol";

/// @notice Step-0 measurement for the startBattle optimization (PLAN_STARTBATTLE.md).
///         Measures Engine.startBattle (via matchmaker confirmBattle) against the REAL
///         GachaTeamRegistry with a facet assigned to EVERY mon on both sides, so getTeams does
///         the full facet-delta fold the production path pays. Reports a per-account
///         (engine = team-store/clear, registry = getTeams reads) SSTORE/SLOAD breakdown so we can
///         see where the ~474k/game actually goes. 4 mons x 4 moves to match prod team size.
contract StartBattleGasTest is Test, GasMeasure {
    address constant ALICE = address(0x1);
    address constant CPU = address(0xC9);
    uint256 constant MONS_PER_TEAM = 4;
    uint256 constant MOVES_PER_MON = 4;
    uint256 constant TIMEOUT = 10;
    uint256 constant POOL = 8; // mon ids 0..7

    Engine engine;
    GachaTeamRegistry registry;
    MockGachaRNG mockRNG;
    MockRandomnessOracle mockOracle;
    DefaultCommitManager commitManager;
    DefaultMatchmaker matchmaker;
    TestMoveFactory moveFactory;

    uint256[] aliceTeam;
    uint96 cpuPhantomIndex;

    function setUp() public {
        vm.warp(2 days); // gacha day-bucketed logic needs a non-zero day

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, TIMEOUT);
        mockOracle = new MockRandomnessOracle();
        mockRNG = new MockGachaRNG();
        registry = new GachaTeamRegistry(MONS_PER_TEAM, MOVES_PER_MON, engine, mockRNG);
        commitManager = new DefaultCommitManager(engine);
        matchmaker = new DefaultMatchmaker(engine);
        moveFactory = new TestMoveFactory();

        while (registry.getQuestPoolLength() > 0) registry.removeQuest(0);

        address[] memory none = new address[](0);

        // Register POOL mons, each with 4 moves + 1 ability (prod-shaped Mon record).
        uint256[] memory moves = new uint256[](MOVES_PER_MON);
        for (uint256 m; m < MOVES_PER_MON; ++m) {
            moves[m] = uint256(uint160(address(moveFactory.createMove(MoveClass.Physical, Type.Fire, 1, 0))));
        }
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = uint256(uint160(address(0xABAB)));
        bytes32[] memory noK = new bytes32[](0);
        bytes32[] memory noV = new bytes32[](0);
        MonStats memory stats = MonStats({
            hp: 100, stamina: 10, speed: 10, attack: 10, defense: 10,
            specialAttack: 10, specialDefense: 10, type1: Type.Fire, type2: Type.None
        });
        for (uint256 i; i < POOL; ++i) registry.createMon(i, stats, moves, abilities, noK, noV);

        // Deployer (this) is the exp assigner.
        address[] memory me = new address[](1);
        me[0] = address(this);
        registry.setAssigners(me, none);

        // ALICE: firstRoll(0) -> owns {0,3,4,5} (mockRNG=0, linear-probe dedup), build that team.
        vm.prank(ALICE);
        registry.firstRoll(0);
        aliceTeam = new uint256[](MONS_PER_TEAM);
        aliceTeam[0] = 0; aliceTeam[1] = 3; aliceTeam[2] = 4; aliceTeam[3] = 5;
        vm.prank(ALICE);
        registry.createTeam(aliceTeam);

        // Max exp on every ALICE mon -> unlocks all 12 facets -> assign facet 1 to each.
        uint256[] memory amounts = new uint256[](MONS_PER_TEAM);
        uint8[] memory facetOnes = new uint8[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; ++i) { amounts[i] = EXP_CAP(); facetOnes[i] = 1; }
        registry.assignExp(ALICE, aliceTeam, amounts);
        vm.prank(ALICE);
        registry.assignFacets(aliceTeam, facetOnes);

        // CPU phantom: whitelist + set a 4-mon team with facet 1 on every slot (no ownership needed).
        address[] memory allow = new address[](1);
        allow[0] = CPU;
        registry.setWhitelistedOpponents(allow, none);
        uint256[] memory cpuMons = new uint256[](MONS_PER_TEAM);
        cpuMons[0] = 1; cpuMons[1] = 2; cpuMons[2] = 6; cpuMons[3] = 7;
        uint8[] memory cpuFacets = new uint8[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; ++i) cpuFacets[i] = 1;
        vm.prank(ALICE);
        registry.setOpponentTeam(CPU, cpuMons, cpuFacets);
        cpuPhantomIndex = uint96(uint16(uint160(ALICE)));

        // Authorize matchmaker for both sides.
        address[] memory mk = new address[](1);
        mk[0] = address(matchmaker);
        vm.prank(ALICE);
        engine.updateMatchmakers(mk, none);
        vm.prank(CPU);
        engine.updateMatchmakers(mk, none);
    }

    function EXP_CAP() internal pure returns (uint256) { return 65535; }

    /// @dev propose + accept (unmeasured); returns the proposal so the caller measures confirmBattle alone.
    function _proposeAndAccept(bytes32 salt) internal returns (bytes32 battleKey, ProposedBattle memory proposal) {
        uint96 ti = 0;
        uint256[] memory ids = registry.getMonRegistryIndicesForTeam(ALICE, ti);
        bytes32 teamHash = keccak256(abi.encodePacked(salt, ti, ids));
        proposal = ProposedBattle({
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
        internal
        pure
        returns (uint256 sstores, uint256 zToNz, uint256 nzToNz, uint256 sloads)
    {
        for (uint256 i; i < acc.length; i++) {
            if (acc[i].account != who) continue;
            Vm.StorageAccess[] memory sa = acc[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                if (sa[j].isWrite) {
                    sstores++;
                    if (sa[j].previousValue == bytes32(0) && sa[j].newValue != bytes32(0)) zToNz++;
                    else if (sa[j].previousValue != sa[j].newValue) nzToNz++;
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
        (uint256 eS, uint256 eZ, uint256 eN, uint256 eL) = _accountTally(acc, address(engine));
        (uint256 rS,,, uint256 rL) = _accountTally(acc, address(registry));
        _snapScenario(snapName, t, gasUsed);
        console.log("");
        console.log(label);
        console.log("  confirmBattle->startBattle gas        :", gasUsed);
        console.log("  ENGINE  SSTORE total / z->nz / nz->nz :", eS, eZ, eN);
        console.log("  ENGINE  SLOAD  total                  :", eL);
        console.log("  REGISTRY SSTORE / SLOAD (getTeams)    :", rS, rL);
        console.log("  ALL: SLOAD cold / warm                :", t.coldSload, t.warmSload);
        console.log("  ALL: SSTORE z->nz / nz->nz / noop     :", t.zToNz, t.nzToNz, t.noop);
    }

    function test_startBattle_breakdown() public {
        // ---- COLD: first battle on a fresh storageKey (z->nz team-store, nothing to clear). ----
        (bytes32 k1,) = _proposeAndAccept("s1");
        _coolAll4();
        vm.startStateDiffRecording();
        uint256 g1 = gasleft();
        vm.prank(ALICE);
        matchmaker.confirmBattle(k1, "s1", 0);
        uint256 coldGas = g1 - gasleft();
        Vm.AccountAccess[] memory acc1 = vm.stopAndReturnStateDiff();
        bytes32 sk1 = engine.getStorageKey(k1);
        _report("=== startBattle COLD (first battle, all mons faceted, real GachaTeamRegistry) ===", "StartBattle_Cold", acc1, coldGas);

        // ---- STEADY: recycle the freed key. Same teams here, so team-store writes are no-ops;
        //      isolates getTeams + prev-state clear + BattleData. The realistic recycled-key case
        //      (a DIFFERENT prior battle's team in those slots) is nz->nz, between cold and this. ----
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        engine.end(k1);
        engine.resetCallContext();
        (bytes32 k2,) = _proposeAndAccept("s2");
        _coolAll4();
        vm.startStateDiffRecording();
        uint256 g2 = gasleft();
        vm.prank(ALICE);
        matchmaker.confirmBattle(k2, "s2", 0);
        uint256 steadyGas = g2 - gasleft();
        Vm.AccountAccess[] memory acc2 = vm.stopAndReturnStateDiff();
        require(engine.getStorageKey(k2) == sk1, "storageKey reuse (steady-state)");
        _report("=== startBattle STEADY (recycled key, SAME team -> team-store no-ops) ===", "StartBattle_Steady", acc2, steadyGas);
    }
}
