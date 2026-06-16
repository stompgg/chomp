// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/// @notice Trusted-relayer entry for writing a user's phantom team config against the
/// caller (a whitelisted CPU). Lets a matchmaker bundle team-config + battle-start
/// in one tx while preserving per-user phantom-slot isolation.
interface IPhantomTeamRegistry {
    function setOpponentTeamFor(
        address user,
        uint256[] memory monIndices,
        uint8[] memory facetIds,
        uint8[] memory moveSelections
    ) external;
}
