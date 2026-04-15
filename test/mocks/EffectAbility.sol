// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {IEngine} from "../../src/IEngine.sol";
import {IAbility} from "../../src/abilities/IAbility.sol";
import {IEffect} from "../../src/effects/IEffect.sol";

contract EffectAbility is IAbility {
    IEffect immutable EFFECT;

    constructor(IEffect _EFFECT) {
        EFFECT = _EFFECT;
    }

    function name() external pure returns (string memory) {
        return "";
    }

    function activateOnSwitch(IEngine engine, bytes32, uint256 playerIndex, uint256 monIndex) external {
        engine.addEffect(playerIndex, monIndex, EFFECT, "");
    }
}
