// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {SignedCommitLib} from "../../src/commit-manager/SignedCommitLib.sol";

import {Test} from "forge-std/Test.sol";

/// @notice EIP-712 signing helpers for `SignedCommitManager` tests.
/// @dev Standalone (not inheriting `EIP712`) — replicates `_DOMAIN_TYPEHASH` to avoid pulling
///      the production base into test contracts. The verifying-contract address is taken as a
///      parameter so a single helper instance can sign for multiple managers.
abstract contract SignedCommitHelper is Test {
    /// `keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")`
    bytes32 internal constant _SIGNED_COMMIT_DOMAIN_TYPEHASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    function _signedCommitDomainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _SIGNED_COMMIT_DOMAIN_TYPEHASH,
                keccak256("SignedCommitManager"),
                keccak256("1"),
                block.chainid,
                verifyingContract
            )
        );
    }

    function _signCommit(
        address signedCommitManagerAddr,
        uint256 privateKey,
        bytes32 moveHash,
        bytes32 battleKey,
        uint64 turnId
    ) internal view returns (bytes memory) {
        bytes32 structHash = SignedCommitLib.hashSignedCommit(
            SignedCommitLib.SignedCommit({moveHash: moveHash, battleKey: battleKey, turnId: turnId})
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _signedCommitDomainSeparator(signedCommitManagerAddr), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signDualReveal(
        address signedCommitManagerAddr,
        uint256 privateKey,
        bytes32 battleKey,
        uint64 turnId,
        bytes32 committerMoveHash,
        uint8 revealerMoveIndex,
        uint104 revealerSalt,
        uint16 revealerExtraData
    ) internal view returns (bytes memory) {
        bytes32 structHash = SignedCommitLib.hashDualSignedReveal(
            SignedCommitLib.DualSignedReveal({
                battleKey: battleKey,
                turnId: turnId,
                committerMoveHash: committerMoveHash,
                revealerMoveIndex: revealerMoveIndex,
                revealerSalt: revealerSalt,
                revealerExtraData: revealerExtraData
            })
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _signedCommitDomainSeparator(signedCommitManagerAddr), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
