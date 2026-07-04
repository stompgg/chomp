// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";

import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";
import {MonExp} from "../src/game-layer/MonExp.sol";
import {MonRegistry} from "../src/game-layer/MonRegistry.sol";

import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";

/// @notice Unit coverage for level-gated move learning and per-(player, mon) configurable
/// movesets. The catalog is widened to 8 lanes; lanes [0, MOVES_PER_MON) are the default moves
/// (level 0) and lane 4 unlocks at FIRST_UNLOCK_LEVEL (6). No new moves are authored — these tests
/// seed synthetic 5-lane catalog rows to exercise the machinery.
contract MoveLearningTest is Test {
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 4;

    Engine engine;
    GachaTeamRegistry registry;
    MockGachaRNG mockRNG;

    uint256 aliceTeamIndex;

    // Distinct, non-zero synthetic move words. Lane L of mon m.
    function _moveWord(uint256 m, uint256 lane) internal pure returns (uint256) {
        return uint256(uint160(uint160(0x100000 + m * 256 + lane)));
    }

    function _movesForMon(uint256 m, uint256 numLanes) internal pure returns (uint256[] memory mv) {
        mv = new uint256[](numLanes);
        for (uint256 i; i < numLanes; ++i) {
            mv[i] = _moveWord(m, i);
        }
    }

    function setUp() public {
        // Non-zero day for the gacha streak/quest logic.
        vm.warp(2 days);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON);
        mockRNG = new MockGachaRNG();
        registry = new GachaTeamRegistry(MONS_PER_TEAM, MOVES_PER_MON, engine, mockRNG, GachaTeamRegistry(address(0)));

        while (registry.getQuestPoolLength() > 0) {
            registry.removeQuest(0);
        }

        MonStats memory stats = MonStats({
            hp: 100, stamina: 10, speed: 10, attack: 10, defense: 10,
            specialAttack: 10, specialDefense: 10, type1: Type.Fire, type2: Type.None
        });
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = uint256(uint160(address(0xABAB)));
        bytes32[] memory noKeys = new bytes32[](0);
        bytes32[] memory noValues = new bytes32[](0);

        // NUM_STARTERS(3) + INITIAL_ROLLS(4) - 1 = 6 mons. Mons 0..4 get 5 catalog moves (lane 4 is
        // the level-6 unlock); mon 5 gets only 4 (lane 4 empty) to cover empty-lane exclusion.
        uint256 poolSize = registry.NUM_STARTERS() + registry.INITIAL_ROLLS() - 1;
        for (uint256 i; i < poolSize; ++i) {
            uint256 numLanes = i == 5 ? 4 : 5;
            registry.createMon(i, stats, _movesForMon(i, numLanes), abilities, noKeys, noValues);
        }

        // mockRNG=0 + linear probing → Alice owns {0, 3, 4, 5}.
        vm.prank(ALICE);
        registry.firstRoll(0);

        // Let this test contract grant exp (to drive level-ups).
        address[] memory assigners = new address[](1);
        assigners[0] = address(this);
        registry.setAssigners(assigners, new address[](0));

        // Alice's team: owned mons {0, 3}.
        uint256[] memory aliceTeam = new uint256[](MONS_PER_TEAM);
        aliceTeam[0] = 0;
        aliceTeam[1] = 3;
        vm.prank(ALICE);
        aliceTeamIndex = registry.createTeam(aliceTeam);
    }

    function _level(address player, uint256 monId, uint256 exp) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = monId;
        uint256[] memory amts = new uint256[](1);
        amts[0] = exp;
        registry.assignExp(player, ids, amts);
    }

    function _one(uint256 monId) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = monId;
    }

    function _bm(uint8 bitmap) internal pure returns (uint8[] memory a) {
        a = new uint8[](1);
        a[0] = bitmap;
    }

    function _aliceMon0Moves() internal view returns (uint256[] memory) {
        (Mon[] memory team,) = registry.getTeams(ALICE, aliceTeamIndex, ALICE, aliceTeamIndex);
        return team[0].moves;
    }

    // ====================================================================
    // Catalog widening
    // ====================================================================

    function test_getMovePool() public view {
        // 5-lane mon: moves in lane order, level-6 unlock on lane 4.
        (uint256[] memory moves, uint8[] memory unlocks) = registry.getMovePool(0);
        assertEq(moves.length, 5);
        for (uint256 lane; lane < 5; ++lane) {
            assertEq(moves[lane], _moveWord(0, lane), "lane order preserved");
        }
        assertEq(unlocks[0], 0);
        assertEq(unlocks[3], 0);
        assertEq(unlocks[4], 6, "lane 4 unlocks at level 6");

        // 4-lane mon: exactly four level-0 moves, no phantom lane 4.
        (uint256[] memory moves5,) = registry.getMovePool(5);
        assertEq(moves5.length, 4);
    }

    function test_createMon_eightLaneCeiling() public {
        MonStats memory stats = registry.getMonStats(0);
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = uint256(uint160(address(0xABAB)));

        // 8 moves is the new ceiling.
        uint256[] memory eight = new uint256[](8);
        for (uint256 i; i < 8; ++i) eight[i] = _moveWord(98, i);
        uint256 id8 = registry.getMonCount();
        registry.createMon(id8, stats, eight, abilities, new bytes32[](0), new bytes32[](0));
        (uint256[] memory moves,) = registry.getMovePool(id8);
        assertEq(moves.length, 8);

        // 9 overflows the catalog width. (Read the id before arming expectRevert — it applies to
        // the next external call, which would otherwise be the getMonCount() staticcall.)
        uint256[] memory nine = new uint256[](9);
        for (uint256 i; i < 9; ++i) nine[i] = _moveWord(99, i);
        uint256 id9 = registry.getMonCount();
        vm.expectRevert(MonRegistry.TooManyMoves.selector);
        registry.createMon(id9, stats, nine, abilities, new bytes32[](0), new bytes32[](0));
    }

    // ====================================================================
    // Unlock curve
    // ====================================================================

    function test_unlockCurve() public {
        // Level 0 (no exp): default lanes 0-3.
        assertEq(registry.getUnlockedMoves(ALICE, 0), 0x0F, "level 0: lanes 0-3");

        // Level 5: lane 4 still locked (boundary just below the unlock).
        _level(ALICE, 0, 53); // exp 53 -> level 5
        assertEq(registry.getLevel(ALICE, 0), 5);
        assertEq(registry.getUnlockedMoves(ALICE, 0), 0x0F, "level 5: lane 4 still locked");

        // Level 6: lane 4 flips on.
        _level(ALICE, 0, 1); // total 54 -> level 6
        assertEq(registry.getLevel(ALICE, 0), 6);
        assertEq(registry.getUnlockedMoves(ALICE, 0), 0x1F, "level 6: lane 4 unlocked");
    }

    function test_getUnlockedMoves_neverExposesEmptyLane() public {
        _level(ALICE, 5, 60); // well past level 6
        assertEq(registry.getLevel(ALICE, 5), 6);
        // Mon 5 has only 4 catalog moves: lane 4 is empty and must stay excluded.
        assertEq(registry.getUnlockedMoves(ALICE, 5), 0x0F);
    }

    // ====================================================================
    // assignMoves (storage + getTeams resolution folded in)
    // ====================================================================

    function test_assignMoves_storesAndResolves() public {
        // Unconfigured: default bitmap and default loadout (first MOVES_PER_MON lanes).
        assertEq(registry.getMoveSelection(ALICE, 0), 0x0F, "default when unconfigured");
        uint256[] memory moves = _aliceMon0Moves();
        assertEq(moves.length, MOVES_PER_MON);
        for (uint256 lane; lane < MOVES_PER_MON; ++lane) {
            assertEq(moves[lane], _moveWord(0, lane), "default = first 4 lanes");
        }

        // Configure lanes 0,2,3: stored bitmap + resolved ascending-lane battle slots, trailing empty.
        vm.prank(ALICE);
        registry.assignMoves(_one(0), _bm(0x0D));
        assertEq(registry.getMoveSelection(ALICE, 0), 0x0D);
        moves = _aliceMon0Moves();
        assertEq(moves[0], _moveWord(0, 0));
        assertEq(moves[1], _moveWord(0, 2));
        assertEq(moves[2], _moveWord(0, 3));
        assertEq(moves[3], 0, "trailing slot empty");
    }

    function test_assignMoves_validationReverts() public {
        // Not the mon's owner.
        vm.prank(BOB);
        vm.expectRevert(MonExp.NotMoveOwner.selector);
        registry.assignMoves(_one(0), _bm(0x0F));

        // Empty selection.
        vm.prank(ALICE);
        vm.expectRevert(MonExp.EmptyMoveSelection.selector);
        registry.assignMoves(_one(0), _bm(0x00));

        // More set bits than battle slots (5 > 4).
        vm.prank(ALICE);
        vm.expectRevert(MonExp.TooManyMovesSelected.selector);
        registry.assignMoves(_one(0), _bm(0x1F));

        // Bit on an empty catalog lane (mon 5 lane 4) — fails regardless of level.
        vm.prank(ALICE);
        vm.expectRevert(MonExp.InvalidMoveLane.selector);
        registry.assignMoves(_one(5), _bm(0x10));

        // Real lane but out-leveled (mon 0 lane 4 at level 0).
        vm.prank(ALICE);
        vm.expectRevert(MonExp.MoveNotUnlocked.selector);
        registry.assignMoves(_one(0), _bm(0x10));

        // Parallel-array length mismatch.
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 3;
        vm.prank(ALICE);
        vm.expectRevert(MonExp.LengthMismatch.selector);
        registry.assignMoves(ids, _bm(0x0F));
    }

    function test_assignMoves_succeedsAfterUnlock() public {
        _level(ALICE, 0, 54); // level 6 unlocks lane 4
        vm.prank(ALICE);
        registry.assignMoves(_one(0), _bm(0x1C)); // lanes 2,3,4
        assertEq(registry.getMoveSelection(ALICE, 0), 0x1C);

        // The unlocked high lane resolves into a battle slot.
        uint256[] memory moves = _aliceMon0Moves();
        assertEq(moves[0], _moveWord(0, 2));
        assertEq(moves[1], _moveWord(0, 3));
        assertEq(moves[2], _moveWord(0, 4), "unlocked high lane resolves");
        assertEq(moves[3], 0);
    }

    function test_assignMoves_multiMonBucketCoalescing() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 3;
        uint8[] memory bms = new uint8[](2);
        bms[0] = 0x07; // lanes 0,1,2
        bms[1] = 0x0B; // lanes 0,1,3
        vm.prank(ALICE);
        registry.assignMoves(ids, bms);
        assertEq(registry.getMoveSelection(ALICE, 0), 0x07);
        assertEq(registry.getMoveSelection(ALICE, 3), 0x0B);
    }

    // ====================================================================
    // getOwnedMonDetails (one-call hydration resolver)
    // ====================================================================

    // The resolver must be byte-for-byte equivalent to composing getOwned + the per-mon getters it
    // folds, so cross-check every lane rather than hardcoding brittle expected values.
    function test_getOwnedMonDetails_matchesPerMonGetters() public {
        // Non-default state: level mon 0 (drives facet-unlock draws) and set a non-default loadout.
        _level(ALICE, 0, 65535);
        vm.prank(ALICE);
        registry.assignMoves(_one(0), _bm(0x0D));

        (
            uint256[] memory monIds,
            uint256[] memory exp,
            uint256[] memory levels,
            uint16[] memory facetUnlocked,
            uint8[] memory facetEquipped,
            uint8[] memory moveSelections
        ) = registry.getOwnedMonDetails(ALICE);

        uint256[] memory owned = registry.getOwned(ALICE);
        assertGt(owned.length, 0, "alice owns mons");
        assertEq(monIds.length, owned.length, "len matches getOwned");

        (uint256[] memory expBatch, uint256[] memory lvlBatch) = registry.getExpAndLevelsForMons(ALICE, owned);

        for (uint256 i; i < monIds.length; ++i) {
            assertEq(monIds[i], owned[i], "ordering matches getOwned");
            assertEq(exp[i], expBatch[i], "exp");
            assertEq(levels[i], lvlBatch[i], "level");
            (uint16 unlocked, uint8 equipped) = registry.getFacetData(ALICE, monIds[i]);
            assertEq(facetUnlocked[i], unlocked, "facet unlocked");
            assertEq(facetEquipped[i], equipped, "facet equipped");
            assertEq(moveSelections[i], registry.getMoveSelection(ALICE, monIds[i]), "move selection");
        }

        // Sanity: the assigned loadout actually surfaces (not just default-vs-default agreement).
        assertEq(monIds[0], 0, "mon 0 is first owned");
        assertEq(moveSelections[0], 0x0D, "non-default loadout reflected");
        assertGt(facetUnlocked[0], 0, "leveling unlocked at least one facet");
    }
}
