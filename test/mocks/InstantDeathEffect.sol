// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

contract InstantDeathEffect is BasicEffect {
    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() external pure override returns (string memory) {
        return "Instant Death";
    }

    function getStepsBitmap() external pure override returns (uint16) {
        return 0x04;
    }

    function getStepsToRun() external pure override returns (EffectStep[] memory) {
        EffectStep[] memory steps = new EffectStep[](1);
        steps[0] = EffectStep.RoundEnd;
        return steps;
    }

    function onRoundEnd(uint256, bytes32, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        ENGINE.updateMonState(targetIndex, monIndex, MonStateIndexName.IsKnockedOut, 1);
        return (bytes32(0), true);
    }
}
