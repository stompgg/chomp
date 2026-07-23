// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEffect} from "./IEffect.sol";

/// @notice Compact prototype command encoding for opted-in read-only effect resolvers.
library EffectCommandLib {
    uint256 internal constant OP_CLEAR_STATUS = 1;
    uint256 internal constant OP_ADD_EFFECT = 2;

    function clearStatus(uint256 targetIndex, uint256 monIndex, uint256 statusClass)
        internal
        pure
        returns (uint256)
    {
        return OP_CLEAR_STATUS | (targetIndex << 8) | (monIndex << 16) | (statusClass << 24);
    }

    function addEffect(uint256 targetIndex, uint256 monIndex, IEffect effect) internal pure returns (uint256) {
        return OP_ADD_EFFECT | (targetIndex << 8) | (monIndex << 16) | (uint256(uint160(address(effect))) << 24);
    }

}
