// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MoveClass, Type} from "../Enums.sol";
import {IEffect} from "../effects/IEffect.sol";

library MoveCommandLib {
    uint256 internal constant OP_ATTACK = 1;
    uint256 internal constant OP_SWITCH = 2;

    function attack(
        uint32 basePower,
        uint8 accuracy,
        uint8 volatility,
        Type moveType,
        MoveClass moveClass,
        uint8 critRate,
        uint8 effectAccuracy,
        IEffect effect
    ) internal pure returns (uint256) {
        return OP_ATTACK | (uint256(basePower) << 8) | (uint256(accuracy) << 40) | (uint256(volatility) << 48)
            | (uint256(uint8(moveType)) << 56) | (uint256(uint8(moveClass)) << 64) | (uint256(critRate) << 72)
            | (uint256(effectAccuracy) << 80) | (uint256(uint160(address(effect))) << 88);
    }

    function switchMon(uint256 playerIndex, uint256 slotIndex, uint256 monIndex) internal pure returns (uint256) {
        return OP_SWITCH | (playerIndex << 8) | (slotIndex << 16) | (monIndex << 24);
    }
}

