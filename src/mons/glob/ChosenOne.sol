// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

// Deliberately NOT @inline-ability: that path registers the ability itself as the mon's effect,
// but this one applies a different effect behind a once-per-battle guard.

import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {IEffect} from "../../effects/IEffect.sol";

contract ChosenOne is IAbility {
    IEffect immutable BLESSED_STATUS;

    constructor(IEffect _BLESSED_STATUS) {
        BLESSED_STATUS = _BLESSED_STATUS;
    }

    function activateOnSwitch(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        uint64 blessKey = _getChosenOneKey(playerIndex, monIndex);
        if (engine.getGlobalKV(battleKey, blessKey) != 0) {
            return;
        }
        engine.addEffect(playerIndex, monIndex, BLESSED_STATUS, bytes32(0));
        engine.setGlobalKV(blessKey, 1);
    }

    function _getChosenOneKey(uint256 playerIndex, uint256 monIndex) internal view returns (uint64) {
        return uint64(uint256(keccak256(abi.encode(playerIndex, monIndex, address(this)))));
    }
}