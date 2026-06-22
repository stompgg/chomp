// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/// @notice Mixes the acting player index into the per-turn rng to break symmetry on mirror matchups.
/// The standard-attack path does this in the engine; custom moves/effects that consume rng directly
/// call this themselves.
library RNGLib {
    function mixForAttacker(uint256 rng, uint256 attackerPlayerIndex) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(rng, attackerPlayerIndex)));
    }
}
