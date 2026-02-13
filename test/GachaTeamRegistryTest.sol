// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {GachaRegistry} from "../src/gacha/GachaRegistry.sol";
import {DefaultMonRegistry} from "../src/teams/DefaultMonRegistry.sol";
import {GachaTeamRegistry} from "../src/teams/GachaTeamRegistry.sol";
import {LookupTeamRegistry} from "../src/teams/LookupTeamRegistry.sol";

import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";

import {IAbility} from "../src/abilities/IAbility.sol";

import {IMoveSet} from "../src/moves/IMoveSet.sol";

contract GachaTeamRegistryTest is Test {
    address constant ALICE = address(1);
    address constant BOB = address(2);

    DefaultMonRegistry monRegistry;
    GachaTeamRegistry gachaTeamRegistry;
    GachaRegistry gachaRegistry;
    Engine engine;
    MockGachaRNG mockRNG;

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 1;
    address constant MOVE_ADDRESS = address(111);
    address constant ABILITY_ADDRESS = address(222);

    uint256 unownedMonId;

    function setUp() public {
        monRegistry = new DefaultMonRegistry();
        engine = new Engine(0, 0, 0);
        mockRNG = new MockGachaRNG();

        gachaRegistry = new GachaRegistry(monRegistry, engine, mockRNG, 1);

        gachaTeamRegistry = new GachaTeamRegistry(
            LookupTeamRegistry.Args({
                REGISTRY: gachaRegistry, MONS_PER_TEAM: MONS_PER_TEAM, MOVES_PER_MON: MOVES_PER_MON
            }),
            gachaRegistry
        );

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

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = IMoveSet(MOVE_ADDRESS);

        IAbility[] memory abilities = new IAbility[](1);
        abilities[0] = IAbility(ABILITY_ADDRESS);

        bytes32[] memory keys = new bytes32[](0);
        bytes32[] memory values = new bytes32[](0);

        for (uint256 i = 0; i < gachaRegistry.INITIAL_ROLLS() + 1; i++) {
            monRegistry.createMon(i, stats, moves, abilities, keys, values);
        }

        // Roll for Alice (due to RNG, we should get IDs 0 to INITIAL_ROLLS)
        vm.startPrank(ALICE);
        gachaRegistry.firstRoll();

        // Set unowned mon id
        unownedMonId = gachaRegistry.INITIAL_ROLLS();
    }

    /*
     * Test that createTeam reverts when attempting to use mons not owned by the caller.
     * Verifies the ownership validation prevents unauthorized team creation.
     */
    function test_createTeam_revertsWithUnownedMon() public {
        vm.startPrank(ALICE);
        uint256[] memory monIndices = new uint256[](MONS_PER_TEAM);
        monIndices[0] = unownedMonId;
        vm.expectRevert(GachaTeamRegistry.NotOwner.selector);
        gachaTeamRegistry.createTeam(monIndices);
    }

    function test_createTeamReturnsCorrectValues() public {
        vm.startPrank(ALICE);
        uint256[] memory monIndices = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            monIndices[i] = i;
        }
        gachaTeamRegistry.createTeam(monIndices);
        assertEq(gachaTeamRegistry.getTeamCount(ALICE), 1);
        Mon[] memory team = gachaTeamRegistry.getTeam(ALICE, 0);
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            IMoveSet[] memory moves = team[i].moves;
            assertEq(address(moves[0]), MOVE_ADDRESS);
            assertEq(address(team[i].ability), ABILITY_ADDRESS);
        }
    }

    function test_updateTeam_revertsWithUnownedMon() public {
        vm.startPrank(ALICE);
        uint256[] memory monIndices = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            monIndices[i] = i;
        }
        gachaTeamRegistry.createTeam(monIndices);
        uint256[] memory teamMonIndicesToOverride = new uint256[](1);
        teamMonIndicesToOverride[0] = 0;
        uint256[] memory newMonIndices = new uint256[](1);
        newMonIndices[0] = unownedMonId;
        vm.expectRevert(GachaTeamRegistry.NotOwner.selector);
        gachaTeamRegistry.updateTeam(0, teamMonIndicesToOverride, newMonIndices);
    }

    function test_updateTeamOverrideWorks() public {
        vm.startPrank(ALICE);
        uint256[] memory monIndices = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            monIndices[i] = i;
        }
        gachaTeamRegistry.createTeam(monIndices);
        uint256[] memory newMonIndices = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            newMonIndices[i] = i + 1;
        }
        gachaTeamRegistry.updateTeamForUser(newMonIndices);
        // Assert the new indices have been set for team index 0
        uint256[] memory teamIndices = gachaTeamRegistry.getMonRegistryIndicesForTeam(ALICE, 0);
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            assertEq(teamIndices[i], i + 1);
        }
    }
}
