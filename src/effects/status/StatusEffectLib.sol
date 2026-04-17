// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

library StatusEffectLib {
    function getKeyForMonIndex(uint256 playerIndex, uint256 monIndex) internal pure returns (uint64) {
        bytes32 STATUS_EFFECT = "STATUS_EFFECT";
        return uint64(uint256(keccak256(abi.encodePacked(STATUS_EFFECT, playerIndex, monIndex))));
    }
}
