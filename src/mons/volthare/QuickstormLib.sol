// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

/// @notice The switch-in anchor PreemptiveShock arms and Quickstorm reads. Lives here so the two
///         contracts share one derivation rather than two matching literals.
library QuickstormLib {
    // Explicit tag rather than address(this): the key is read from a different contract than the
    // one that writes it, so it cannot be scoped to either.
    bytes32 private constant KEY_TAG = "QUICKSTORM";

    function _windowKey(uint256 playerIndex, uint256 monIndex) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encode(playerIndex, monIndex, KEY_TAG))));
    }
}
