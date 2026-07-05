// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Structs.sol";
import "../src/Enums.sol";

import {Engine} from "../src/Engine.sol";
import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";

import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";
import "src/Constants.sol";

/// @notice Covers GachaTeamRegistry.migrate(): the self-service, one-shot import of a
/// player's full progression state (ownership, profile slot, exp, facets, teams) from an
/// immutable PREVIOUS_REGISTRY that shares this contract's storage layout.
contract GachaMigrationTest is Test {
    address constant ALICE = address(1);
    address constant BOB = address(2);

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 1;
    address constant MOVE_ADDRESS = address(111);
    address constant ABILITY_ADDRESS = address(222);

    Engine engine;
    MockGachaRNG mockRNG;
    GachaTeamRegistry oldReg;
    GachaTeamRegistry newReg;

    function setUp() public {
        // currentDay > 0 so daily-gated branches behave; mirrors GachaTeamRegistryTest.
        vm.warp(2 days);

        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        mockRNG = new MockGachaRNG();

        // ----- Old (source) registry: no predecessor. -----
        oldReg = new GachaTeamRegistry(MONS_PER_TEAM, MOVES_PER_MON, engine, mockRNG, GachaTeamRegistry(address(0)));
        _seedCatalog(oldReg);

        // Test contract is the registry owner; allow itself to assign exp/points.
        address[] memory selfList = new address[](1);
        selfList[0] = address(this);
        oldReg.setAssigners(selfList, new address[](0));

        // Alice rolls a starter → owns {0, 3, 4, 5} (mockRNG=0 + linear probing).
        vm.prank(ALICE);
        oldReg.firstRoll(0);

        // A team built from owned mons.
        uint256[] memory team = new uint256[](MONS_PER_TEAM);
        team[0] = 0;
        team[1] = 3;
        vm.prank(ALICE);
        oldReg.createTeam(team);

        // Exp on two owned mons → level-ups draw facets (populates the facet bucket too).
        uint256[] memory expMons = new uint256[](2);
        expMons[0] = 0;
        expMons[1] = 3;
        uint256[] memory expAmts = new uint256[](2);
        expAmts[0] = 40; // → level 5
        expAmts[1] = 12; // → level 2
        oldReg.assignExp(ALICE, expMons, expAmts);

        // Assign one of mon 0's freshly-unlocked facets.
        (uint16 unlocked,) = oldReg.getFacetData(ALICE, 0);
        uint8 facetId = _lowestUnlocked(unlocked);
        assertGt(facetId, 0, "mon 0 should have unlocked at least one facet");
        uint256[] memory facetMon = new uint256[](1);
        facetMon[0] = 0;
        uint8[] memory facetVal = new uint8[](1);
        facetVal[0] = facetId;
        vm.prank(ALICE);
        oldReg.assignFacets(facetMon, facetVal);

        // Points in the low bits.
        oldReg.assignPoints(ALICE, 1234);

        // Populate the upper region of the profile word (a flag bit) so the migration's
        // verbatim whole-slot copy is exercised, not just the points bits.
        address[] memory aliceList = new address[](1);
        aliceList[0] = ALICE;
        oldReg.setWhitelistedOpponents(aliceList, new address[](0));

        // ----- New (destination) registry: points back at oldReg. -----
        newReg = new GachaTeamRegistry(MONS_PER_TEAM, MOVES_PER_MON, engine, mockRNG, oldReg);
        _seedCatalog(newReg); // catalog set up before anyone migrates, same sequential ids
    }

    function test_migrate_copiesOwnership() public {
        vm.prank(ALICE);
        newReg.migrate();

        uint256[] memory oldOwned = oldReg.getOwned(ALICE);
        uint256[] memory newOwned = newReg.getOwned(ALICE);
        assertEq(newReg.balanceOf(ALICE), oldReg.balanceOf(ALICE), "owned count matches");
        assertEq(newOwned.length, oldOwned.length, "owned array length matches");
        for (uint256 i; i < oldOwned.length; i++) {
            assertTrue(newReg.isOwner(ALICE, oldOwned[i]), "each old-owned mon is owned on new");
        }
        // A mon Alice never owned stays unowned.
        assertFalse(newReg.isOwner(ALICE, 1), "unowned mon stays unowned");
    }

    function test_migrate_copiesProfileSlotVerbatim() public {
        vm.prank(ALICE);
        newReg.migrate();

        // Whole-word equality proves the slot (points + flags) is copied verbatim, unmasked.
        assertEq(newReg.playerData(ALICE), oldReg.playerData(ALICE), "profile word verbatim");
        assertEq(newReg.pointsBalance(ALICE), 1234, "points carried");
        assertTrue(newReg.isWhitelistedOpponent(ALICE), "whitelist flag carried");
    }

    function test_migrate_copiesExpAndFacets() public {
        vm.prank(ALICE);
        newReg.migrate();

        // Every cataloged mon's exp + facet data matches (covers owned and unowned lanes).
        for (uint256 monId; monId < oldReg.getMonCount(); monId++) {
            assertEq(newReg.getExp(ALICE, monId), oldReg.getExp(ALICE, monId), "exp matches");
            assertEq(newReg.getLevel(ALICE, monId), oldReg.getLevel(ALICE, monId), "level matches");
            (uint16 oldUnlocked, uint8 oldAssigned) = oldReg.getFacetData(ALICE, monId);
            (uint16 newUnlocked, uint8 newAssigned) = newReg.getFacetData(ALICE, monId);
            assertEq(newUnlocked, oldUnlocked, "unlocked bitmap matches");
            assertEq(newAssigned, oldAssigned, "assigned facet matches");
        }
        assertGt(newReg.getLevel(ALICE, 0), 0, "mon 0 leveled up");
        (, uint8 assigned0) = newReg.getFacetData(ALICE, 0);
        assertGt(assigned0, 0, "mon 0 has an assigned facet");
    }

    function test_migrate_copiesTeams() public {
        vm.prank(ALICE);
        newReg.migrate();

        assertEq(newReg.getTeamCount(ALICE), oldReg.getTeamCount(ALICE), "team count matches");
        assertEq(newReg.teamOrderPacked(ALICE), oldReg.teamOrderPacked(ALICE), "order/live word matches");

        uint256[] memory oldIds = oldReg.getMonRegistryIndicesForTeam(ALICE, 0);
        uint256[] memory newIds = newReg.getMonRegistryIndicesForTeam(ALICE, 0);
        assertEq(newIds.length, oldIds.length, "team length matches");
        for (uint256 i; i < oldIds.length; i++) {
            assertEq(newIds[i], oldIds[i], "team mon id matches");
        }
    }

    function test_migrate_setsMigratedFlag() public {
        assertFalse(newReg.migrated(ALICE), "not migrated before");
        vm.prank(ALICE);
        newReg.migrate();
        assertTrue(newReg.migrated(ALICE), "migrated after");
    }

    function test_migrate_revertsOnSecondCall() public {
        vm.prank(ALICE);
        newReg.migrate();
        vm.prank(ALICE);
        vm.expectRevert(GachaTeamRegistry.AlreadyMigrated.selector);
        newReg.migrate();
    }

    function test_migrate_revertsWhenNoPreviousRegistry() public {
        // oldReg was constructed with address(0) as its predecessor.
        vm.prank(ALICE);
        vm.expectRevert(GachaTeamRegistry.NoPreviousRegistry.selector);
        oldReg.migrate();
    }

    function test_migrate_emptyPlayerIsClean() public {
        // Bob has no state on oldReg; migrating is a no-op-equivalent that still sets the guard.
        vm.prank(BOB);
        newReg.migrate();

        assertEq(newReg.balanceOf(BOB), 0, "no mons");
        assertEq(newReg.playerData(BOB), 0, "empty profile");
        assertEq(newReg.getTeamCount(BOB), 0, "no teams");
        assertTrue(newReg.migrated(BOB), "guard set even when empty");
    }

    function test_migrate_isPerPlayer() public {
        // Alice migrating does not flip Bob's guard.
        vm.prank(ALICE);
        newReg.migrate();
        assertFalse(newReg.migrated(BOB), "bob still un-migrated");
        vm.prank(BOB);
        newReg.migrate(); // does not revert
        assertTrue(newReg.migrated(BOB), "bob now migrated");
    }

    // ----- helpers -----

    function _seedCatalog(GachaTeamRegistry reg) internal {
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
        bytes32[] memory empty = new bytes32[](0);

        uint256 poolSize = reg.NUM_STARTERS() + reg.INITIAL_ROLLS() - 1; // 6
        for (uint256 i; i < poolSize; i++) {
            reg.createMon(i, stats, moves, abilities, empty, empty);
        }
    }

    function _lowestUnlocked(uint16 unlocked) internal pure returns (uint8) {
        for (uint8 i; i < 12; i++) {
            if (unlocked & uint16(1 << i) != 0) return i + 1; // facetId is 1-indexed
        }
        return 0;
    }
}
