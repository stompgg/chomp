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
import {ITeamRegistry} from "../src/game-layer/ITeamRegistry.sol";

import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";

contract ReturnerGiftTest is Test {
    address constant ALICE = address(0xA1);
    address constant BOB = address(0xB0);
    // CARL deliberately has no live team — used to exercise the NoLiveTeam path.
    address constant CARL = address(0xC1);

    GachaTeamRegistry registry;
    ReturnerGift gift;
    Engine engine;
    MockGachaRNG mockRNG;

    uint256 constant MONS_PER_TEAM = 4;
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
        for (uint256 i; i < MONS_PER_TEAM; ++i) {
            registry.createMon(i, stats, moves, abilities, ks, vs);
        }

        // Alice gets a live team with mons [0,1,2,3] so tier 2..6 claims can resolve.
        uint256[] memory aliceTeam = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; ++i) aliceTeam[i] = i;
        registry.setTeamForUser(ALICE, 0, aliceTeam, new uint8[](MONS_PER_TEAM));

        gift = new ReturnerGift(
            IGachaPointsAssigner(address(registry)),
            IExpAssigner(address(registry)),
            ITeamRegistry(address(registry)),
            address(this)
        );

        address[] memory toAdd = new address[](1);
        address[] memory toRemove = new address[](0);
        toAdd[0] = address(gift);
        registry.setAssigners(toAdd, toRemove);
    }

    // --- Merkle helpers (mirror MerkleProofLib's pair-sort hashing) ---

    function _leaf(address claimer, uint256 tier) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(claimer, tier));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
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

    function _setupAliceTier(uint256 tier) internal returns (bytes32[] memory proof) {
        bytes32 aliceLeaf = _leaf(ALICE, tier);
        bytes32 bobLeaf = _leaf(BOB, tier);
        bytes32 root;
        (root, proof) = _twoLeafRootAndProof(aliceLeaf, bobLeaf);
        gift.setMerkleRoot(root);
    }

    // --- Tier reward tests ---

    function test_claim_tier1_pointsOnly() public {
        bytes32[] memory proof = _setupAliceTier(1);

        vm.prank(ALICE);
        gift.claim(proof, 1);

        assertEq(registry.pointsBalance(ALICE), 16);
        assertEq(registry.getExp(ALICE, 0), 0, "tier 1 grants no exp");
        assertTrue(gift.claimed(gift.merkleRoot(), ALICE));
    }

    function test_claim_tier2_oneMon() public {
        bytes32[] memory proof = _setupAliceTier(2);

        vm.prank(ALICE);
        gift.claim(proof, 2);

        assertEq(registry.pointsBalance(ALICE), 16);
        assertEq(registry.getExp(ALICE, 0), 4);
        assertEq(registry.getExp(ALICE, 1), 0, "tier 2 stops at mon 0");
    }

    function test_claim_tier3_twoMons() public {
        bytes32[] memory proof = _setupAliceTier(3);

        vm.prank(ALICE);
        gift.claim(proof, 3);

        assertEq(registry.pointsBalance(ALICE), 16);
        assertEq(registry.getExp(ALICE, 0), 4);
        assertEq(registry.getExp(ALICE, 1), 4);
        assertEq(registry.getExp(ALICE, 2), 0, "tier 3 stops at mon 1");
    }

    function test_claim_tier4_threeMons() public {
        bytes32[] memory proof = _setupAliceTier(4);

        vm.prank(ALICE);
        gift.claim(proof, 4);

        assertEq(registry.pointsBalance(ALICE), 20);
        assertEq(registry.getExp(ALICE, 0), 8);
        assertEq(registry.getExp(ALICE, 1), 8);
        assertEq(registry.getExp(ALICE, 2), 8);
        assertEq(registry.getExp(ALICE, 3), 0, "tier 4 stops at mon 2");
    }

    function test_claim_tier5_fourMons() public {
        bytes32[] memory proof = _setupAliceTier(5);

        vm.prank(ALICE);
        gift.claim(proof, 5);

        assertEq(registry.pointsBalance(ALICE), 24);
        assertEq(registry.getExp(ALICE, 0), 8);
        assertEq(registry.getExp(ALICE, 1), 8);
        assertEq(registry.getExp(ALICE, 2), 8);
        assertEq(registry.getExp(ALICE, 3), 8);
    }

    function test_claim_tier6_fourMonsHigherPoints() public {
        bytes32[] memory proof = _setupAliceTier(6);

        vm.prank(ALICE);
        gift.claim(proof, 6);

        assertEq(registry.pointsBalance(ALICE), 31);
        assertEq(registry.getExp(ALICE, 0), 8);
        assertEq(registry.getExp(ALICE, 1), 8);
        assertEq(registry.getExp(ALICE, 2), 8);
        assertEq(registry.getExp(ALICE, 3), 8);
    }

    // --- Failure modes ---

    function test_claim_revertsOnInvalidTier_zero() public {
        bytes32 aliceLeaf = _leaf(ALICE, 0);
        bytes32 bobLeaf = _leaf(BOB, 0);
        (bytes32 root, bytes32[] memory proof) = _twoLeafRootAndProof(aliceLeaf, bobLeaf);
        gift.setMerkleRoot(root);

        vm.prank(ALICE);
        vm.expectRevert(ReturnerGift.InvalidTier.selector);
        gift.claim(proof, 0);
    }

    function test_claim_revertsOnInvalidTier_seven() public {
        bytes32 aliceLeaf = _leaf(ALICE, 7);
        bytes32 bobLeaf = _leaf(BOB, 7);
        (bytes32 root, bytes32[] memory proof) = _twoLeafRootAndProof(aliceLeaf, bobLeaf);
        gift.setMerkleRoot(root);

        vm.prank(ALICE);
        vm.expectRevert(ReturnerGift.InvalidTier.selector);
        gift.claim(proof, 7);
    }

    function test_claim_revertsOnNoLiveTeam() public {
        bytes32 carlLeaf = _leaf(CARL, 2);
        bytes32 bobLeaf = _leaf(BOB, 2);
        (bytes32 root, bytes32[] memory proof) = _twoLeafRootAndProof(carlLeaf, bobLeaf);
        gift.setMerkleRoot(root);

        vm.prank(CARL);
        vm.expectRevert(ReturnerGift.NoLiveTeam.selector);
        gift.claim(proof, 2);
    }

    function test_claim_tier1_succeedsWithoutTeam() public {
        // Tier 1 is points-only; a claimer with no live team should still succeed.
        bytes32 carlLeaf = _leaf(CARL, 1);
        bytes32 bobLeaf = _leaf(BOB, 1);
        (bytes32 root, bytes32[] memory proof) = _twoLeafRootAndProof(carlLeaf, bobLeaf);
        gift.setMerkleRoot(root);

        vm.prank(CARL);
        gift.claim(proof, 1);

        assertEq(registry.pointsBalance(CARL), 16);
    }

    function test_claim_revertsOnDoubleClaim() public {
        bytes32[] memory proof = _setupAliceTier(1);

        vm.prank(ALICE);
        gift.claim(proof, 1);
        assertEq(registry.pointsBalance(ALICE), 16);

        vm.prank(ALICE);
        vm.expectRevert(ReturnerGift.AlreadyClaimed.selector);
        gift.claim(proof, 1);
    }

    function test_claim_revertsOnInvalidProof() public {
        bytes32 aliceLeaf = _leaf(ALICE, 1);
        bytes32 bobLeaf = _leaf(BOB, 1);
        (bytes32 root,) = _twoLeafRootAndProof(aliceLeaf, bobLeaf);
        gift.setMerkleRoot(root);

        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("not-the-real-sibling");

        vm.prank(ALICE);
        vm.expectRevert(ReturnerGift.InvalidProof.selector);
        gift.claim(badProof, 1);
    }

    function test_claim_revertsOnTamperedTier() public {
        // Root encodes ALICE @ tier 1; she tries to claim tier 5 with the tier-1 proof.
        bytes32 aliceLeaf = _leaf(ALICE, 1);
        bytes32 bobLeaf = _leaf(BOB, 1);
        (bytes32 root, bytes32[] memory proof) = _twoLeafRootAndProof(aliceLeaf, bobLeaf);
        gift.setMerkleRoot(root);

        vm.prank(ALICE);
        vm.expectRevert(ReturnerGift.InvalidProof.selector);
        gift.claim(proof, 5);
    }

    function test_setMerkleRoot_rotationAllowsReclaim() public {
        bytes32[] memory proof1 = _setupAliceTier(1);

        vm.prank(ALICE);
        gift.claim(proof1, 1);
        assertEq(registry.pointsBalance(ALICE), 16);

        // New campaign — same player, different root, different tier.
        bytes32 aliceLeaf2 = _leaf(ALICE, 2);
        bytes32 bobLeaf = _leaf(BOB, 2);
        (bytes32 root2, bytes32[] memory proof2) = _twoLeafRootAndProof(aliceLeaf2, bobLeaf);
        gift.setMerkleRoot(root2);

        vm.prank(ALICE);
        gift.claim(proof2, 2);
        assertEq(registry.pointsBalance(ALICE), 32, "both campaigns applied");
        assertEq(registry.getExp(ALICE, 0), 4);
    }

    function test_claim_revertsIfGiftNotWhitelisted() public {
        address[] memory empty = new address[](0);
        address[] memory toRemove = new address[](1);
        toRemove[0] = address(gift);
        registry.setAssigners(empty, toRemove);

        bytes32[] memory proof = _setupAliceTier(1);

        vm.prank(ALICE);
        vm.expectRevert(GachaTeamRegistry.NotAssigner.selector);
        gift.claim(proof, 1);
    }

    function test_setMerkleRoot_onlyOwner() public {
        vm.prank(BOB);
        vm.expectRevert();
        gift.setMerkleRoot(bytes32(uint256(1)));
    }

    // --- Parity test against analysis/merkle.json ---
    // Tier-1 entry for 0x0165113d2702Ad22fc5c21Ef9BC51edB30EA6642 in the published merkle.json.
    // Asserts the contract's leaf encoding + pair-sort verification match the Python script
    // byte-for-byte, so on-chain claims will accept proofs from the analysis pipeline as-is.
    function test_claim_parityWithAnalysisMerkleJson() public {
        address pyAddr = 0x0165113d2702Ad22fc5c21Ef9BC51edB30EA6642;
        bytes32 root = 0x676c3dcca078e2a46cb67865fe30a3e807e4240312cbb923466334406b6e519d;

        bytes32[] memory proof = new bytes32[](8);
        proof[0] = 0x22723c1863b4cfd3661a7651a1e37a4d9c43f6c853159fc98aad6bc012224ddd;
        proof[1] = 0x7fe4be4d3db3f34120498bcfef65a457f540da886025b6614aec7932473892f8;
        proof[2] = 0x89cab2613abcbaa1a21a2b388d6f1af5a58d2b540ed0dd96a496cbe1ee8cbd82;
        proof[3] = 0xa432d73fd3fa08518ed27adfdadf16680c06cd78e11c03c1101fcbc93cf63946;
        proof[4] = 0x189f7d46379342a1e0ccc0cd384ccadb9b5628ef8223d28f9d8462319fbd6317;
        proof[5] = 0x654788cee11b903721860ab1c004a922f0632ce24c04f25e2fa32c418c0dab4b;
        proof[6] = 0xb6f62ee28649f56ac4009cab0eea0170f799f3cccd04060915b905ad80e96197;
        proof[7] = 0x3ab60dd1b26719675c836d8f25921b95e3df0f2c5e65adbe7a57f728e6be0d70;

        gift.setMerkleRoot(root);

        vm.prank(pyAddr);
        gift.claim(proof, 1);

        assertEq(registry.pointsBalance(pyAddr), 16);
    }
}
