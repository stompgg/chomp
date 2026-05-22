// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Structs.sol";

import {Engine} from "../../src/Engine.sol";
import {SignedCommitManager} from "../../src/commit-manager/SignedCommitManager.sol";

import {SignedCommitHelper} from "./SignedCommitHelper.sol";

/// @notice Test helpers for the batched per-turn-submission flow (OPT_PLAN §10).
/// @dev Inherits `SignedCommitHelper` so subclasses get `_signCommit` / `_signDualReveal`
///      out of the box.
abstract contract BatchHelper is SignedCommitHelper {
    /// @notice Build + sign a `TurnSubmission` for the given (turnId, p0Move, p1Move).
    ///         Roles (committer/revealer) are derived from `turnId % 2`, matching the manager.
    /// @dev Returns the entry AND the committer's address so the caller can `vm.prank` it
    ///      (single-sig design requires msg.sender == committer).
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
    ) internal view returns (TurnSubmission memory entry, address committerAddr) {
        uint8 committerMoveIndex;
        uint16 committerExtraData;
        uint104 committerSalt;
        uint8 revealerMoveIndex;
        uint16 revealerExtraData;
        uint104 revealerSalt;
        uint256 committerPk;
        uint256 revealerPk;

        if (turnId % 2 == 0) {
            committerMoveIndex = p0MoveIndex;
            committerExtraData = p0ExtraData;
            committerSalt = p0Salt;
            revealerMoveIndex = p1MoveIndex;
            revealerExtraData = p1ExtraData;
            revealerSalt = p1Salt;
            committerPk = p0Pk;
            revealerPk = p1Pk;
        } else {
            committerMoveIndex = p1MoveIndex;
            committerExtraData = p1ExtraData;
            committerSalt = p1Salt;
            revealerMoveIndex = p0MoveIndex;
            revealerExtraData = p0ExtraData;
            revealerSalt = p0Salt;
            committerPk = p1Pk;
            revealerPk = p0Pk;
        }

        bytes32 committerMoveHash =
            keccak256(abi.encodePacked(committerMoveIndex, committerSalt, committerExtraData));

        entry = TurnSubmission({
            turnId: turnId,
            committerMoveIndex: committerMoveIndex,
            committerExtraData: committerExtraData,
            committerSalt: committerSalt,
            revealerMoveIndex: revealerMoveIndex,
            revealerExtraData: revealerExtraData,
            revealerSalt: revealerSalt,
            revealerSig: _signDualReveal(
                signedCommitManagerAddr,
                revealerPk,
                battleKey,
                turnId,
                committerMoveHash,
                revealerMoveIndex,
                revealerSalt,
                revealerExtraData
            )
        });
        committerAddr = vm.addr(committerPk);
    }

    /// @notice Submit a single turn into the buffer. No execute happens.
    function _submitTurnMoves(
        SignedCommitManager mgr,
        bytes32 battleKey,
        uint64 turnId,
        uint8 p0MoveIndex,
        uint16 p0ExtraData,
        uint8 p1MoveIndex,
        uint16 p1ExtraData,
        uint256 p0Pk,
        uint256 p1Pk
    ) internal {
        // Deterministic per-(turn, side) salts so tests are reproducible across runs.
        uint104 p0Salt = uint104(uint256(keccak256(abi.encode("p0", battleKey, turnId))));
        uint104 p1Salt = uint104(uint256(keccak256(abi.encode("p1", battleKey, turnId))));

        (TurnSubmission memory entry, address committerAddr) = _buildTurnSubmission(
            address(mgr),
            battleKey,
            turnId,
            p0MoveIndex,
            p0ExtraData,
            p0Salt,
            p1MoveIndex,
            p1ExtraData,
            p1Salt,
            p0Pk,
            p1Pk
        );

        vm.prank(committerAddr);
        mgr.submitTurnMoves(battleKey, entry);
    }

    /// @notice Drain all currently buffered turns.
    function _executeBuffered(Engine engine, SignedCommitManager mgr, bytes32 battleKey) internal {
        mgr.executeBuffered(battleKey);
        engine.resetCallContext();
    }
}
