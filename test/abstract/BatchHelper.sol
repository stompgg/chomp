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

    /// @notice Build a single-sig `TurnSubmission` (committer preimage + revealer sig only).
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
    ) internal view returns (TurnSubmission memory entry) {
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
        entry = TurnSubmission({
            turnId: turnId,
            committerMoveIndex: cM,
            committerExtraData: cE,
            committerSalt: cS,
            revealerMoveIndex: rM,
            revealerExtraData: rE,
            revealerSalt: rS,
            revealerSig: _signDualReveal(signedCommitManagerAddr, rPk, battleKey, turnId, committerMoveHash, rM, rS, rE)
        });
    }
}
