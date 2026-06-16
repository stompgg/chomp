// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {IValidator} from "../src/IValidator.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";

import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";
import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";

import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";
import {TestMoveFactory} from "./mocks/TestMoveFactory.sol";

/// @notice End-to-end check that GachaTeamRegistry.getTeams() folds facet ±5% deltas
/// into stats and that Engine.startBattle picks them up via the inline-validator path
/// (validator = address(0)). The DefaultValidator path is deprecated.
contract GachaFacetsBattleTest is Test {
    address constant ALICE = address(0x1);
    address constant CPU = address(0xC9);

    Engine engine;
    GachaTeamRegistry registry;
    MockGachaRNG mockRNG;
    MockRandomnessOracle mockOracle;
    DefaultCommitManager commitManager;
    DefaultMatchmaker matchmaker;
    TestMoveFactory moveFactory;
    IMoveSet testMove;

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 1;
    address constant ABILITY_ADDR = address(0xABAB);

    function setUp() public {
        // GachaTeamRegistry's day-bucketed quest/streak logic needs a non-zero day.
        vm.warp(2 days);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON);
        mockOracle = new MockRandomnessOracle();
        mockRNG = new MockGachaRNG();
        registry = new GachaTeamRegistry(MONS_PER_TEAM, MOVES_PER_MON, engine, mockRNG, GachaTeamRegistry(address(0)));
        commitManager = new DefaultCommitManager(engine);
        matchmaker = new DefaultMatchmaker(engine);
        moveFactory = new TestMoveFactory();

        // Constructor seeds production quests; drain so the test runs against a clean pool.
        while (registry.getQuestPoolLength() > 0) {
            registry.removeQuest(0);
        }

        testMove = moveFactory.createMove(MoveClass.Physical, Type.Fire, 1, 0);

        MonStats memory stats = MonStats({
            hp: 100,
            stamina: 10,
            speed: 10,
            attack: 10,
            defense: 10,
            specialAttack: 10,
            specialDefense: 10,
            type1: Type.Fire,
            type2: Type.None
        });
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(testMove)));
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = uint256(uint160(ABILITY_ADDR));
        bytes32[] memory noKeys = new bytes32[](0);
        bytes32[] memory noValues = new bytes32[](0);

        // NUM_STARTERS starters + (INITIAL_ROLLS - 1) non-starters so firstRoll can complete.
        uint256 poolSize = registry.NUM_STARTERS() + registry.INITIAL_ROLLS() - 1;
        for (uint256 i; i < poolSize; ++i) {
            registry.createMon(i, stats, moves, abilities, noKeys, noValues);
        }

        // Alice rolls starter 0 (plus 3 random non-starters via firstRoll).
        vm.prank(ALICE);
        registry.firstRoll(0);

        // Whitelist CPU so its facets come from opponentTeamFacetsPacked.
        address[] memory allow = new address[](1);
        allow[0] = CPU;
        address[] memory disallow = new address[](0);
        registry.setWhitelistedOpponents(allow, disallow);

        // Alice builds a team from owned mons {0, 3, 4, 5} (post-firstRoll).
        uint256[] memory aliceTeam = new uint256[](MONS_PER_TEAM);
        aliceTeam[0] = 0;
        aliceTeam[1] = 3;
        vm.prank(ALICE);
        registry.createTeam(aliceTeam);

        // Alice configures the CPU's phantom team and facets. Facet 1 boosts HP +5%, nerfs Atk.
        // Slot 0 gets facet 1 → +5 HP on hp=100. Slot 1 left at 0 (no facet) for a control read.
        uint256[] memory cpuMons = new uint256[](MONS_PER_TEAM);
        cpuMons[0] = 1;
        cpuMons[1] = 2;
        uint8[] memory cpuFacets = new uint8[](MONS_PER_TEAM);
        cpuFacets[0] = 1;
        cpuFacets[1] = 0;
        uint8[] memory cpuMoves = new uint8[](MONS_PER_TEAM); // default loadout
        vm.prank(ALICE);
        registry.setOpponentTeam(CPU, cpuMons, cpuFacets, cpuMoves);

        // Both players must authorize the matchmaker with the engine.
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        address[] memory makersToRemove = new address[](0);
        vm.prank(ALICE);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.prank(CPU);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
    }

    function test_inlineValidator_appliesFacetsAtBattleStart() public {
        bytes32 salt = "";
        uint96 aliceTeamIndex = 0;
        // Phantom team for CPU is keyed by uint16(uint160(human caller)).
        uint96 cpuPhantomIndex = uint96(uint16(uint160(ALICE)));

        uint256[] memory aliceMonIds = registry.getMonRegistryIndicesForTeam(ALICE, aliceTeamIndex);
        bytes32 aliceTeamHash = keccak256(abi.encodePacked(salt, aliceTeamIndex, aliceMonIds));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: aliceTeamIndex,
            p0TeamHash: aliceTeamHash,
            p1: CPU,
            p1TeamIndex: cpuPhantomIndex,
            teamRegistry: registry,
            validator: IValidator(address(0)), // inline validation
            rngOracle: mockOracle,
            ruleset: IRuleset(address(0)),
            moveManager: address(commitManager),
            matchmaker: matchmaker,
            engineHooks: new IEngineHook[](0)
        });

        vm.prank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        bytes32 integrity = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.prank(CPU);
        matchmaker.acceptBattle(battleKey, cpuPhantomIndex, integrity);

        vm.prank(ALICE);
        // confirmBattle internally invokes engine.startBattle, which is where getTeams runs.
        matchmaker.confirmBattle(battleKey, salt, aliceTeamIndex);

        // CPU slot 0 has facet 1 (+5% of 100 = +5). CPU slot 1 has no facet. Alice has no
        // facets unlocked. Verifying through the same path CPUs read from at runtime.
        uint32 cpuMon0Hp   = engine.getMonValueForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        uint32 cpuMon0Atk  = engine.getMonValueForBattle(battleKey, 1, 0, MonStateIndexName.Attack);
        uint32 cpuMon1Hp   = engine.getMonValueForBattle(battleKey, 1, 1, MonStateIndexName.Hp);
        uint32 aliceMon0Hp = engine.getMonValueForBattle(battleKey, 0, 0, MonStateIndexName.Hp);

        assertEq(cpuMon0Hp, 105, "CPU slot 0 HP boosted by facet 1");
        // Atk=10, 5% truncates to 0 — nerf is unobservable at this base stat. Documented so the
        // assertion below doesn't look accidental.
        assertEq(cpuMon0Atk, 10, "CPU slot 0 Atk nerf truncates to 0 at base=10");
        assertEq(cpuMon1Hp, 100, "CPU slot 1 HP unchanged (no facet)");
        assertEq(aliceMon0Hp, 100, "Alice slot 0 HP unchanged (human, no unlocked facets)");
    }
}
