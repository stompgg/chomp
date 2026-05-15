// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/// @notice Owner-gated entry for granting gacha points to an arbitrary player.
/// Implementations restrict callers to an owner-managed allowlist.
interface IGachaPointsAssigner {
    function assignPoints(address player, uint256 amount) external;
}
