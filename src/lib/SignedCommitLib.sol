// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/// @notice Library for hashing SignedCommit structs according to EIP-712
/// @dev Used by FastCommitManager to verify signed move commitments
library SignedCommitLib {
    /// @dev keccak256("SignedCommit(bytes32 moveHash,bytes32 battleKey,uint64 turnId)")
    bytes32 public constant SIGNED_COMMIT_TYPEHASH =
        0x1a5c47a5e8c55c3c3e3d3b3a3938373635343332313039383736353433323130;

    struct SignedCommit {
        bytes32 moveHash;
        bytes32 battleKey;
        uint64 turnId;
    }

    /// @notice Computes the type hash for SignedCommit
    /// @dev This can be called once to verify SIGNED_COMMIT_TYPEHASH is correct
    function computeTypehash() internal pure returns (bytes32) {
        return keccak256("SignedCommit(bytes32 moveHash,bytes32 battleKey,uint64 turnId)");
    }

    /// @notice Hashes a SignedCommit struct according to EIP-712
    /// @param commit The SignedCommit struct to hash
    /// @return The EIP-712 struct hash
    function hashSignedCommit(SignedCommit memory commit) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("SignedCommit(bytes32 moveHash,bytes32 battleKey,uint64 turnId)"),
                commit.moveHash,
                commit.battleKey,
                commit.turnId
            )
        );
    }
}
