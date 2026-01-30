// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

contract TempStatBoostEffect is BasicEffect {
    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() external pure override returns (string memory) {
        return "";
    }

    // Should run at end of round and on apply
    function shouldRunAtStep(EffectStep r) external pure override returns (bool) {
        return (r == EffectStep.OnMonSwitchOut || r == EffectStep.OnApply);
    }

    function onApply(EffectContext calldata, uint256, bytes32, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        ENGINE.updateMonState(targetIndex, monIndex, MonStateIndexName.Attack, 1);
        return (bytes32(0), false);
    }

    function onMonSwitchOut(EffectContext calldata, uint256, bytes32, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        ENGINE.updateMonState(targetIndex, monIndex, MonStateIndexName.Attack, 1);
        return (bytes32(0), true);
    }
}
