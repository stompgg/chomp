// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultValidator} from "../src/DefaultValidator.sol";
import {Engine} from "../src/Engine.sol";
import {GachaRegistry} from "../src/gacha/GachaRegistry.sol";
import {DefaultMonRegistry} from "../src/teams/DefaultMonRegistry.sol";
import {GachaTeamRegistry} from "../src/teams/GachaTeamRegistry.sol";

import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";

contract GachaTeamRegistryTest is Test {
    address constant ALICE = address(1);
    address constant BOB = address(2);
    address constant CPU = address(0xC9);

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

        gachaRegistry = new GachaRegistry(monRegistry, engine, mockRNG);

        gachaTeamRegistry = new GachaTeamRegistry(
            GachaTeamRegistry.Args({
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

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(MOVE_ADDRESS));

        uint256[] memory abilities = new uint256[](1);
        abilities[0] = uint160(ABILITY_ADDRESS);

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
            uint256[] memory moves = team[i].moves;
            assertEq(address(uint160(moves[0])), MOVE_ADDRESS);
            assertEq(address(uint160(team[i].ability)), ABILITY_ADDRESS);
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

    function _allowOnly(address opponent) internal {
        address[] memory toAllow = new address[](1);
        toAllow[0] = opponent;
        address[] memory toDisallow = new address[](0);
        gachaTeamRegistry.setWhitelistedOpponents(toAllow, toDisallow);
    }

    function test_setWhitelistedOpponents_onlyOwner_reverts() public {
        // setUp leaves a prank active as ALICE.
        address[] memory toAllow = new address[](1);
        toAllow[0] = CPU;
        address[] memory toDisallow = new address[](0);
        vm.expectRevert();
        gachaTeamRegistry.setWhitelistedOpponents(toAllow, toDisallow);
    }

    function test_setWhitelistedOpponents_ownerSucceeds() public {
        vm.stopPrank();

        address[] memory toAllow = new address[](2);
        toAllow[0] = CPU;
        toAllow[1] = address(0xCA);
        address[] memory toDisallow = new address[](0);
        gachaTeamRegistry.setWhitelistedOpponents(toAllow, toDisallow);
        assertTrue(gachaTeamRegistry.isWhitelistedOpponent(CPU));
        assertTrue(gachaTeamRegistry.isWhitelistedOpponent(address(0xCA)));

        // Toggle one off via the disallow list.
        address[] memory toAllow2 = new address[](0);
        address[] memory toDisallow2 = new address[](1);
        toDisallow2[0] = CPU;
        gachaTeamRegistry.setWhitelistedOpponents(toAllow2, toDisallow2);
        assertFalse(gachaTeamRegistry.isWhitelistedOpponent(CPU));
        assertTrue(gachaTeamRegistry.isWhitelistedOpponent(address(0xCA)));
    }

    function test_setOpponentTeam_revertsIfNotWhitelisted() public {
        vm.startPrank(ALICE);
        uint256[] memory monIndices = new uint256[](MONS_PER_TEAM);
        monIndices[0] = 0;
        monIndices[1] = 1;
        vm.expectRevert(GachaTeamRegistry.NotWhitelistedOpponent.selector);
        gachaTeamRegistry.setOpponentTeam(CPU, monIndices);
    }

    // Covers both "phantom team is keyed at uint256(uint160(msg.sender))" and "no ownership check".
    function test_setOpponentTeam_writesAtUserAddressIndex() public {
        vm.stopPrank();
        _allowOnly(CPU);

        vm.startPrank(ALICE);
        uint256[] memory monIndices = new uint256[](MONS_PER_TEAM);
        monIndices[0] = unownedMonId; // Alice does NOT own this mon.
        monIndices[1] = 0;
        gachaTeamRegistry.setOpponentTeam(CPU, monIndices);

        uint256[] memory readIndices = gachaTeamRegistry.getMonRegistryIndicesForTeam(CPU, uint256(uint160(ALICE)));
        assertEq(readIndices[0], unownedMonId);
        assertEq(readIndices[1], 0);
    }

    function test_setOpponentTeam_overwritesPriorTeam() public {
        vm.stopPrank();
        _allowOnly(CPU);

        vm.startPrank(ALICE);
        uint256[] memory firstIndices = new uint256[](MONS_PER_TEAM);
        firstIndices[0] = 0;
        firstIndices[1] = 1;
        gachaTeamRegistry.setOpponentTeam(CPU, firstIndices);

        uint256[] memory secondIndices = new uint256[](MONS_PER_TEAM);
        secondIndices[0] = 2;
        secondIndices[1] = 3;
        gachaTeamRegistry.setOpponentTeam(CPU, secondIndices);

        uint256[] memory readIndices = gachaTeamRegistry.getMonRegistryIndicesForTeam(CPU, uint256(uint160(ALICE)));
        assertEq(readIndices[0], 2);
        assertEq(readIndices[1], 3);
    }

    function test_setOpponentTeam_perUserSlots() public {
        vm.stopPrank();
        _allowOnly(CPU);

        vm.startPrank(ALICE);
        uint256[] memory aliceIndices = new uint256[](MONS_PER_TEAM);
        aliceIndices[0] = 0;
        aliceIndices[1] = 1;
        gachaTeamRegistry.setOpponentTeam(CPU, aliceIndices);
        vm.stopPrank();

        vm.startPrank(BOB);
        uint256[] memory bobIndices = new uint256[](MONS_PER_TEAM);
        bobIndices[0] = 2;
        bobIndices[1] = 3;
        gachaTeamRegistry.setOpponentTeam(CPU, bobIndices);
        vm.stopPrank();

        uint256[] memory aliceTeam = gachaTeamRegistry.getMonRegistryIndicesForTeam(CPU, uint256(uint160(ALICE)));
        uint256[] memory bobTeam = gachaTeamRegistry.getMonRegistryIndicesForTeam(CPU, uint256(uint160(BOB)));
        assertEq(aliceTeam[0], 0);
        assertEq(aliceTeam[1], 1);
        assertEq(bobTeam[0], 2);
        assertEq(bobTeam[1], 3);
    }

    function test_defaultValidator_acceptsPhantomTeam() public {
        DefaultValidator validator = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: MONS_PER_TEAM, MOVES_PER_MON: MOVES_PER_MON, TIMEOUT_DURATION: 0})
        );

        vm.stopPrank();
        _allowOnly(CPU);

        // CPU needs at least one regular team so getTeamCount(CPU) > 0.
        uint256[] memory cpuRegularTeam = new uint256[](MONS_PER_TEAM);
        cpuRegularTeam[0] = 0;
        cpuRegularTeam[1] = 1;
        gachaTeamRegistry.createTeamForUser(CPU, cpuRegularTeam);

        vm.startPrank(ALICE);
        uint256[] memory aliceTeam = new uint256[](MONS_PER_TEAM);
        aliceTeam[0] = 0;
        aliceTeam[1] = 1;
        gachaTeamRegistry.createTeam(aliceTeam);

        uint256[] memory phantomTeam = new uint256[](MONS_PER_TEAM);
        phantomTeam[0] = unownedMonId;
        phantomTeam[1] = 0;
        gachaTeamRegistry.setOpponentTeam(CPU, phantomTeam);
        vm.stopPrank();

        Mon[][] memory teams = new Mon[][](2);
        teams[0] = gachaTeamRegistry.getTeam(ALICE, 0);
        teams[1] = gachaTeamRegistry.getTeam(CPU, uint256(uint160(ALICE)));

        bool ok = validator.validateGameStart(ALICE, CPU, teams, gachaTeamRegistry, 0, uint256(uint160(ALICE)));
        assertTrue(ok);
    }
}
