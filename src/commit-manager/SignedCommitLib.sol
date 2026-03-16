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
        bytes32 revealerSalt;
        uint240 revealerExtraData;
    }

    /// @notice Computes the type hash for DualSignedReveal
    function computeDualSignedRevealTypehash() internal pure returns (bytes32) {
        return keccak256(
            "DualSignedReveal(bytes32 battleKey,uint64 turnId,bytes32 committerMoveHash,uint8 revealerMoveIndex,bytes32 revealerSalt,uint240 revealerExtraData)"
        );
    }

    /// @notice Hashes a DualSignedReveal struct according to EIP-712
    /// @param reveal The DualSignedReveal struct to hash
    /// @return The EIP-712 struct hash
    function hashDualSignedReveal(DualSignedReveal memory reveal) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "DualSignedReveal(bytes32 battleKey,uint64 turnId,bytes32 committerMoveHash,uint8 revealerMoveIndex,bytes32 revealerSalt,uint240 revealerExtraData)"
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

    /// @notice Struct for the dual-signed reveal flow in doubles battles
    /// @dev Like DualSignedReveal but covers 2 slot moves per player.
    ///      The committer's hash covers both their slot moves (matching revealMovePair preimage).
    ///      The revealer signs over both their slot moves + the committer's hash.
    struct DualSignedRevealDoubles {
        bytes32 battleKey;
        uint64 turnId;
        bytes32 committerMoveHash; // hash(moveIndex0, moveIndex1, salt, extraData0, extraData1)
        uint8 revealerMoveIndex0; // Slot 0 move
        uint8 revealerMoveIndex1; // Slot 1 move
        bytes32 revealerSalt;
        uint240 revealerExtraData0; // Slot 0 extra data
        uint240 revealerExtraData1; // Slot 1 extra data
    }

    /// @notice Hashes a DualSignedRevealDoubles struct according to EIP-712
    /// @param reveal The DualSignedRevealDoubles struct to hash
    /// @return The EIP-712 struct hash
    function hashDualSignedRevealDoubles(DualSignedRevealDoubles memory reveal) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "DualSignedRevealDoubles(bytes32 battleKey,uint64 turnId,bytes32 committerMoveHash,uint8 revealerMoveIndex0,uint8 revealerMoveIndex1,bytes32 revealerSalt,uint240 revealerExtraData0,uint240 revealerExtraData1)"
                ),
                reveal.battleKey,
                reveal.turnId,
                reveal.committerMoveHash,
                reveal.revealerMoveIndex0,
                reveal.revealerMoveIndex1,
                reveal.revealerSalt,
                reveal.revealerExtraData0,
                reveal.revealerExtraData1
            )
        );
    }
}
