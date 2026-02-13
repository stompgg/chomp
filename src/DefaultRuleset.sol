// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Constants.sol";
import "./Structs.sol";
import "./moves/IMoveSet.sol";

import {IEngine} from "./IEngine.sol";
import {IRuleset} from "./IRuleset.sol";

import {IEffect} from "./effects/IEffect.sol";

contract DefaultRuleset is IRuleset {
    IEngine immutable ENGINE;

    IEffect[] public effects;

    constructor(IEngine _ENGINE, IEffect[] memory _effects) {
        ENGINE = _ENGINE;
        for (uint256 i; i < _effects.length;) {
            effects.push(_effects[i]);
            unchecked { ++i; }
        }
    }

    function getInitialGlobalEffects() external view returns (IEffect[] memory, bytes32[] memory) {
        bytes32[] memory data = new bytes32[](effects.length);
        return (effects, data);
    }
}
