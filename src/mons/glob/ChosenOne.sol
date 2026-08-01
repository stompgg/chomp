// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

// @inline-ability: singleton-local

import {IEngine} from "../../IEngine.sol";
import {EffectInstance, StatBoostToApply} from "../../Structs.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";

contract ChosenOne is IAbility {

    uint64 constant MAX_MON_INDEX = 8;

    IEffect immutable BLESSED_STATUS;

    constructor(IEffect _BLESSED_STATUS) {
        BLESSED_STATUS = _BLESSED_STATUS;
    }

    function name() public pure override returns (string memory) {
        return "Chosen One";
    }

    function activateOnSwitch(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        // Check if global KV has already been set
        if (engine.getGlobalKV(battleKey, _getChosenOneKey(playerIndex, monIndex)) == 1) {
            return;
        }
        engine.addEffect(playerIndex, monIndex, BLESSED_STATUS, bytes32(0));
        engine.setGlobalKV(_getChosenOneKey(playerIndex, monIndex), 1);
    }

    function _getChosenOneKey(uint256 playerIndex, uint256 monIndex) internal pure returns (uint64 scaledKey) {
        scaledKey = uint64(playerIndex * MAX_MON_INDEX + monIndex);
    }
}