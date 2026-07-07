// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/// @notice Library for hashing signed structs according to EIP-712
/// @dev Used by SignedCommitManager to verify signed move commitments
library SignedCommitLib {
    /// @notice Struct for a signed commitment from the committer
    /// @dev The committer (A) signs over their move hash to prove they committed
    ///      This can be published by anyone (typically B) if A stalls
    struct SignedCommit {
        bytes32 moveHash;
        bytes32 battleKey;
        uint64 turnId;
    }

    /// @notice Computes the type hash for SignedCommit
    function computeSignedCommitTypehash() internal pure returns (bytes32) {
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

    /// @notice Struct for the dual-signed reveal flow
    /// @dev The revealer (B) signs over their move and the committer's (A's) move hash
    ///      This allows A to submit both moves in a single transaction
    struct DualSignedReveal {
        bytes32 battleKey;
        uint64 turnId;
        bytes32 committerMoveHash; // A's hash that B signs over
        uint8 revealerMoveIndex;
        uint104 revealerSalt;
        uint16 revealerExtraData;
    }

    /// @notice Computes the type hash for DualSignedReveal
    function computeDualSignedRevealTypehash() internal pure returns (bytes32) {
        return keccak256(
            "DualSignedReveal(bytes32 battleKey,uint64 turnId,bytes32 committerMoveHash,uint8 revealerMoveIndex,uint104 revealerSalt,uint16 revealerExtraData)"
        );
    }

    /// @notice Hashes a DualSignedReveal struct according to EIP-712
    /// @param reveal The DualSignedReveal struct to hash
    /// @return The EIP-712 struct hash
    function hashDualSignedReveal(DualSignedReveal memory reveal) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "DualSignedReveal(bytes32 battleKey,uint64 turnId,bytes32 committerMoveHash,uint8 revealerMoveIndex,uint104 revealerSalt,uint16 revealerExtraData)"
                ),
                reveal.battleKey,
                reveal.turnId,
                reveal.committerMoveHash,
                reveal.revealerMoveIndex,
                reveal.revealerSalt,
                reveal.revealerExtraData
            )
        );
    }

    /// @notice 2-slot variant of DualSignedReveal: each side's whole turn is one packed word
    ///         ([slot0 move 8 | slot0 extra 16 | slot1 move 8 | slot1 extra 16 | salt 104]).
    struct DualSignedSlotReveal {
        bytes32 battleKey;
        uint64 turnId;
        bytes32 committerMovesHash;
        uint256 revealerSidePacked;
    }

    bytes32 internal constant DUAL_SIGNED_SLOT_REVEAL_TYPEHASH =
        0xe4967167cd99f2b483c72c1fe6037d2653962173ef5ea9cb44d0f1a30d295b7a;

    /// @dev Typehash string: DualSignedSlotReveal(bytes32 battleKey,uint64 turnId,bytes32 committerMovesHash,uint256 revealerSidePacked)
    function hashDualSignedSlotReveal(DualSignedSlotReveal memory reveal) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DUAL_SIGNED_SLOT_REVEAL_TYPEHASH,
                reveal.battleKey,
                reveal.turnId,
                reveal.committerMovesHash,
                reveal.revealerSidePacked
            )
        );
    }
}
