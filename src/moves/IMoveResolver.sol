// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/// @notice Prototype continuation resolver for external moves.
interface IMoveResolver {
    function resolveMove(
        uint32 continuation,
        int32 priorResult,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256 activesPacked,
        uint16 extraData,
        uint256 rng
    ) external view returns (uint256 command, uint32 nextContinuation);
}

