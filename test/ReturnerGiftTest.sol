// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";
import {ReturnerGift} from "../src/game-layer/ReturnerGift.sol";
import {IGachaPointsAssigner} from "../src/game-layer/IGachaPointsAssigner.sol";
import {IExpAssigner} from "../src/game-layer/IExpAssigner.sol";

import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";

contract ReturnerGiftTest is Test {
    address constant ALICE = address(0xA1);
    address constant BOB = address(0xB0);

    GachaTeamRegistry registry;
    ReturnerGift gift;
    Engine engine;
    MockGachaRNG mockRNG;

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 1;
    address constant MOVE_ADDRESS = address(111);
    address constant ABILITY_ADDRESS = address(222);

    function setUp() public {
        engine = new Engine(0, 0, 0);
        mockRNG = new MockGachaRNG();
        registry = new GachaTeamRegistry(MONS_PER_TEAM, MOVES_PER_MON, engine, mockRNG);

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
        moves[0] = uint160(MOVE_ADDRESS);
        uint256[] memory abilities = new uint256[](1);
        abilities[0] = uint160(ABILITY_ADDRESS);
        bytes32[] memory ks = new bytes32[](0);
        bytes32[] memory vs = new bytes32[](0);
        for (uint256 i; i < 6; ++i) {
            registry.createMon(i, stats, moves, abilities, ks, vs);
        }

        gift = new ReturnerGift(
            IGachaPointsAssigner(address(registry)),
            IExpAssigner(address(registry)),
            address(this)
        );

        address[] memory toAdd = new address[](1);
        address[] memory toRemove = new address[](0);
        toAdd[0] = address(gift);
        registry.setAssigners(toAdd, toRemove);
    }

    // --- Merkle helpers (mirror MerkleProofLib's pair-sort hashing) ---

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _leaf(address claimer, uint256 pts, uint256[] memory ids, uint256[] memory amounts)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(claimer, pts, ids, amounts));
    }

    function _twoLeafRootAndProof(bytes32 myLeaf, bytes32 otherLeaf)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proof)
    {
        root = _hashPair(myLeaf, otherLeaf);
        proof = new bytes32[](1);
        proof[0] = otherLeaf;
    }

    // --- Tests ---

    function test_claim_happyPath() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 0;
        amounts[0] = 4;

        bytes32 aliceLeaf = _leaf(ALICE, 100, ids, amounts);
        // A second leaf so we have a proper tree.
        uint256[] memory bobIds = new uint256[](0);
        uint256[] memory bobAmounts = new uint256[](0);
        bytes32 bobLeaf = _leaf(BOB, 25, bobIds, bobAmounts);

        (bytes32 root, bytes32[] memory proof) = _twoLeafRootAndProof(aliceLeaf, bobLeaf);
        gift.setMerkleRoot(root);

        vm.prank(ALICE);
        gift.claim(proof, 100, ids, amounts);

        assertEq(registry.pointsBalance(ALICE), 100);
        assertEq(registry.getExp(ALICE, 0), 4);
        assertEq(registry.getLevel(ALICE, 0), 1, "lv 1 crossed");
        assertTrue(gift.claimed(root, ALICE));
    }

    function test_claim_revertsOnDoubleClaim() public {
        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32 aliceLeaf = _leaf(ALICE, 7, ids, amounts);
        bytes32 bobLeaf = _leaf(BOB, 7, ids, amounts);
        (bytes32 root, bytes32[] memory proof) = _twoLeafRootAndProof(aliceLeaf, bobLeaf);
        gift.setMerkleRoot(root);

        vm.prank(ALICE);
        gift.claim(proof, 7, ids, amounts);
        assertEq(registry.pointsBalance(ALICE), 7);

        vm.prank(ALICE);
        vm.expectRevert(ReturnerGift.AlreadyClaimed.selector);
        gift.claim(proof, 7, ids, amounts);
    }

    function test_claim_revertsOnInvalidProof() public {
        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32 aliceLeaf = _leaf(ALICE, 11, ids, amounts);
        bytes32 bobLeaf = _leaf(BOB, 11, ids, amounts);
        (bytes32 root,) = _twoLeafRootAndProof(aliceLeaf, bobLeaf);
        gift.setMerkleRoot(root);

        // Wrong sibling in proof.
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("not-the-real-sibling");

        vm.prank(ALICE);
        vm.expectRevert(ReturnerGift.InvalidProof.selector);
        gift.claim(badProof, 11, ids, amounts);
    }

    function test_claim_revertsOnTamperedAmount() public {
        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32 aliceLeaf = _leaf(ALICE, 11, ids, amounts);
        bytes32 bobLeaf = _leaf(BOB, 11, ids, amounts);
        (bytes32 root, bytes32[] memory proof) = _twoLeafRootAndProof(aliceLeaf, bobLeaf);
        gift.setMerkleRoot(root);

        vm.prank(ALICE);
        vm.expectRevert(ReturnerGift.InvalidProof.selector);
        gift.claim(proof, 999, ids, amounts);
    }

    function test_setMerkleRoot_rotationAllowsReclaim() public {
        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32 aliceLeaf1 = _leaf(ALICE, 5, ids, amounts);
        bytes32 bobLeaf = _leaf(BOB, 5, ids, amounts);
        (bytes32 root1, bytes32[] memory proof1) = _twoLeafRootAndProof(aliceLeaf1, bobLeaf);
        gift.setMerkleRoot(root1);

        vm.prank(ALICE);
        gift.claim(proof1, 5, ids, amounts);

        // New campaign — same player, different root.
        bytes32 aliceLeaf2 = _leaf(ALICE, 13, ids, amounts);
        (bytes32 root2, bytes32[] memory proof2) = _twoLeafRootAndProof(aliceLeaf2, bobLeaf);
        gift.setMerkleRoot(root2);

        vm.prank(ALICE);
        gift.claim(proof2, 13, ids, amounts);
        assertEq(registry.pointsBalance(ALICE), 18, "both campaigns applied");
    }

    function test_claim_revertsIfGiftNotWhitelisted() public {
        // Revoke the gift's assigner role.
        address[] memory empty = new address[](0);
        address[] memory toRemove = new address[](1);
        toRemove[0] = address(gift);
        registry.setAssigners(empty, toRemove);

        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32 aliceLeaf = _leaf(ALICE, 1, ids, amounts);
        bytes32 bobLeaf = _leaf(BOB, 1, ids, amounts);
        (bytes32 root, bytes32[] memory proof) = _twoLeafRootAndProof(aliceLeaf, bobLeaf);
        gift.setMerkleRoot(root);

        vm.prank(ALICE);
        vm.expectRevert(GachaTeamRegistry.NotAssigner.selector);
        gift.claim(proof, 1, ids, amounts);
    }

    function test_setMerkleRoot_onlyOwner() public {
        vm.prank(BOB);
        vm.expectRevert();
        gift.setMerkleRoot(bytes32(uint256(1)));
    }
}
