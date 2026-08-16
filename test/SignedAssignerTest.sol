// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";

import {Engine} from "../src/Engine.sol";
import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";
import {PlayerProfile} from "../src/game-layer/PlayerProfile.sol";
import {SignedAssigner} from "../src/game-layer/SignedAssigner.sol";
import {ECDSA} from "../src/lib/ECDSA.sol";

import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";

contract SignedAssignerTest is Test {
    address constant ALICE = address(0xA1);
    address constant BOB = address(0xB0);

    uint256 constant SIGNER_PK = 0x5160E;
    uint256 constant IMPOSTOR_PK = 0xBAD;
    uint256 constant AMOUNT = 16;

    /// @dev Order of the secp256k1 curve; used to malleate a signature.
    uint256 constant SECP256K1_N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;

    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant CLAIM_TYPEHASH = keccak256("Claim(address recipient,uint256 amount,uint256 claimId)");

    GachaTeamRegistry registry;
    SignedAssigner assigner;
    Engine engine;
    MockGachaRNG mockRNG;
    address signer;

    function setUp() public {
        signer = vm.addr(SIGNER_PK);
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        mockRNG = new MockGachaRNG();
        registry = new GachaTeamRegistry(4, 1, engine, mockRNG, GachaTeamRegistry(address(0)));
        assigner = new SignedAssigner(signer, address(registry));
        _setAssigner(address(assigner), true);
    }

    function _setAssigner(address who, bool allowed) internal {
        address[] memory on = new address[](allowed ? 1 : 0);
        address[] memory off = new address[](allowed ? 0 : 1);
        (allowed ? on : off)[0] = who;
        registry.setAssigners(on, off);
    }

    // Rebuilt here rather than read off the contract, so a domain or typehash change fails.
    function _digest(address recipient, uint256 amount, uint256 claimId) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("SignedAssigner"), keccak256("1"), block.chainid, address(assigner)
            )
        );
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, recipient, amount, claimId));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _signParts(uint256 pk, address recipient, uint256 amount, uint256 claimId)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return vm.sign(pk, _digest(recipient, amount, claimId));
    }

    function _sign(uint256 pk, address recipient, uint256 amount, uint256 claimId)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = _signParts(pk, recipient, amount, claimId);
        return abi.encodePacked(r, s, v);
    }

    function _sign(address recipient, uint256 amount, uint256 claimId) internal view returns (bytes memory) {
        return _sign(SIGNER_PK, recipient, amount, claimId);
    }

    /// Anyone may submit; the signed recipient is paid either way (BOB here drives the relay path).
    function test_claimPaysSignedRecipient() public {
        vm.expectEmit(true, true, true, true);
        emit SignedAssigner.Claimed(ALICE, AMOUNT, 1);
        vm.prank(BOB);
        assigner.claim(ALICE, AMOUNT, 1, _sign(ALICE, AMOUNT, 1));

        assertEq(registry.pointsBalance(ALICE), AMOUNT);
        assertEq(registry.pointsBalance(BOB), 0);
        assertTrue(assigner.isSpent(1));
    }

    /// Regression: the nullifier must key on claimId, not the signature bytes. ECDSA signatures
    /// are malleable, so a signature-keyed nullifier lets a flipped s replay the same grant.
    function test_malleatedSignatureCannotReplay() public {
        (uint8 v, bytes32 r, bytes32 s) = _signParts(SIGNER_PK, ALICE, AMOUNT, 1);
        assigner.claim(ALICE, AMOUNT, 1, abi.encodePacked(r, s, v));

        bytes memory malleated = abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        assertTrue(
            keccak256(malleated) != keccak256(abi.encodePacked(r, s, v)), "malleated signature bytes must differ"
        );

        vm.expectRevert(SignedAssigner.ClaimAlreadySpent.selector);
        assigner.claim(ALICE, AMOUNT, 1, malleated);
        assertEq(registry.pointsBalance(ALICE), AMOUNT);
    }

    /// The same (recipient, amount) must stay grantable under a fresh claimId.
    function test_sameAmountRepeatableWithNewClaimId() public {
        assigner.claim(ALICE, AMOUNT, 1, _sign(ALICE, AMOUNT, 1));
        assigner.claim(ALICE, AMOUNT, 2, _sign(ALICE, AMOUNT, 2));

        assertEq(registry.pointsBalance(ALICE), AMOUNT * 2);
    }

    /// Every field is inside the digest, and only SIGNER's key opens it.
    function test_signedFieldsAreBound() public {
        bytes memory sig = _sign(ALICE, AMOUNT, 1);

        vm.expectRevert(ECDSA.InvalidSignature.selector);
        assigner.claim(BOB, AMOUNT, 1, sig);

        vm.expectRevert(ECDSA.InvalidSignature.selector);
        assigner.claim(ALICE, AMOUNT * 100, 1, sig);

        vm.expectRevert(ECDSA.InvalidSignature.selector);
        assigner.claim(ALICE, AMOUNT, 2, sig);

        vm.expectRevert(ECDSA.InvalidSignature.selector);
        assigner.claim(ALICE, AMOUNT, 1, _sign(IMPOSTOR_PK, ALICE, AMOUNT, 1));
    }

    /// Signer-compromise recovery: revoking the allowlist entry kills unspent claims.
    function test_removedAssignerReverts() public {
        bytes memory sig = _sign(ALICE, AMOUNT, 1);
        _setAssigner(address(assigner), false);

        vm.expectRevert(PlayerProfile.NotAssigner.selector);
        assigner.claim(ALICE, AMOUNT, 1, sig);
    }

    /// Ids sharing a word (0/255, 256/257) and crossing one (255/256) stay independent.
    function test_bitmapWordBoundary() public {
        uint256[4] memory ids = [uint256(0), 255, 256, 257];
        for (uint256 i; i < ids.length; ++i) {
            assigner.claim(ALICE, AMOUNT, ids[i], _sign(ALICE, AMOUNT, ids[i]));
            assertTrue(assigner.isSpent(ids[i]));
        }
        assertEq(registry.pointsBalance(ALICE), AMOUNT * ids.length);

        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(SignedAssigner.ClaimAlreadySpent.selector);
            assigner.claim(ALICE, AMOUNT, ids[i], _sign(ALICE, AMOUNT, ids[i]));
        }
    }

    function testFuzz_claimIdSpendableOnce(uint256 claimId, uint128 amount) public {
        vm.assume(amount > 0);
        bytes memory sig = _sign(ALICE, amount, claimId);

        assigner.claim(ALICE, amount, claimId, sig);
        assertEq(registry.pointsBalance(ALICE), amount);

        vm.expectRevert(SignedAssigner.ClaimAlreadySpent.selector);
        assigner.claim(ALICE, amount, claimId, sig);
    }
}
