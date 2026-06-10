// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Structs.sol";

import {SignedCommitHelper} from "./SignedCommitHelper.sol";

/// @notice Test helpers for the batched per-turn-submission flow (SINGLE-SIG model).
/// @dev The committer is `msg.sender` (no committer signature), so callers must `vm.prank` the
///      committer before `submitTurnMoves`. `_committerFor` gives the committer for a turnId.
abstract contract BatchHelper is SignedCommitHelper {
    /// @notice The committer for a turn (parity: even → p0, odd → p1).
    function _committerFor(uint64 turnId, address p0, address p1) internal pure returns (address) {
        return turnId % 2 == 0 ? p0 : p1;
    }

    /// @notice Build a single-sig `TurnSubmission` (committer preimage + revealer sig) for the external
    ///         SignedCommitManager domain.
    function _buildTurnSubmission(
        address signedCommitManagerAddr,
        bytes32 battleKey,
        uint64 turnId,
        uint8 p0MoveIndex,
        uint16 p0ExtraData,
        uint104 p0Salt,
        uint8 p1MoveIndex,
        uint16 p1ExtraData,
        uint104 p1Salt,
        uint256 p0Pk,
        uint256 p1Pk
    ) internal view returns (uint256 packedMoves, bytes32 r, bytes32 vs) {
        return _buildTurnSubmissionImpl(
            signedCommitManagerAddr, false, battleKey, turnId, p0MoveIndex, p0ExtraData, p0Salt, p1MoveIndex, p1ExtraData, p1Salt, p0Pk, p1Pk
        );
    }

    /// @notice Build a single-sig `TurnSubmission` whose revealer signature targets the Engine's
    ///         built-in dual-signed domain (for BUILTIN_DUAL_SIGNED_MANAGER battles).
    function _buildTurnSubmissionForEngine(
        address engineAddr,
        bytes32 battleKey,
        uint64 turnId,
        uint8 p0MoveIndex,
        uint16 p0ExtraData,
        uint104 p0Salt,
        uint8 p1MoveIndex,
        uint16 p1ExtraData,
        uint104 p1Salt,
        uint256 p0Pk,
        uint256 p1Pk
    ) internal view returns (uint256 packedMoves, bytes32 r, bytes32 vs) {
        return _buildTurnSubmissionImpl(
            engineAddr, true, battleKey, turnId, p0MoveIndex, p0ExtraData, p0Salt, p1MoveIndex, p1ExtraData, p1Salt, p0Pk, p1Pk
        );
    }

    function _buildTurnSubmissionImpl(
        address verifyingContract,
        bool useEngineDomain,
        bytes32 battleKey,
        uint64 turnId,
        uint8 p0MoveIndex,
        uint16 p0ExtraData,
        uint104 p0Salt,
        uint8 p1MoveIndex,
        uint16 p1ExtraData,
        uint104 p1Salt,
        uint256 p0Pk,
        uint256 p1Pk
    ) private view returns (uint256 packedMoves, bytes32 r, bytes32 vs) {
        uint8 cM; uint16 cE; uint104 cS;
        uint8 rM; uint16 rE; uint104 rS; uint256 rPk;
        if (turnId % 2 == 0) {
            cM = p0MoveIndex; cE = p0ExtraData; cS = p0Salt;
            rM = p1MoveIndex; rE = p1ExtraData; rS = p1Salt; rPk = p1Pk;
        } else {
            cM = p1MoveIndex; cE = p1ExtraData; cS = p1Salt;
            rM = p0MoveIndex; rE = p0ExtraData; rS = p0Salt; rPk = p0Pk;
        }
        bytes32 committerMoveHash = keccak256(abi.encodePacked(cM, cS, cE));
        // turnId is signed (the revealer binds it) but NOT submitted — the Engine derives it.
        bytes memory sig = useEngineDomain
            ? _signDualRevealForEngine(verifyingContract, rPk, battleKey, turnId, committerMoveHash, rM, rS, rE)
            : _signDualReveal(verifyingContract, rPk, battleKey, turnId, committerMoveHash, rM, rS, rE);
        // Pack committer (low 128 bits) + revealer (high 128) into one word, matching the buffer layout.
        packedMoves = uint256(cM) | (uint256(cE) << 8) | (uint256(cS) << 24)
            | (uint256(rM) << 128) | (uint256(rE) << 136) | (uint256(rS) << 152);
        (r, vs) = _compactSig(sig);
    }

    /// @dev Split a 65-byte (r,s,v) signature into the EIP-2098 compact (r, vs) form the Engine expects.
    function _compactSig(bytes memory sig) internal pure returns (bytes32 r, bytes32 vs) {
        bytes32 s;
        uint8 v;
        // memory-safe: only reads within sig's allocation; required so contracts combining this
        // helper with deep-stack functions (e.g. GasMeasure._tally) keep via-IR stack-to-memory spilling.
        assembly ("memory-safe") {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        vs = s | bytes32(uint256(v - 27) << 255);
    }
}
