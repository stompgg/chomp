// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

contract SingleInstanceEffect is BasicEffect {
    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() external pure override returns (string memory) {
        return "Instant Death";
    }

    function getStepsBitmap() external pure override returns (uint16) {
        return 0x01;
    }

    function getStepsToRun() external pure override returns (EffectStep[] memory) {
        EffectStep[] memory steps = new EffectStep[](1);
        steps[0] = EffectStep.OnApply;
        return steps;
    }

    function shouldRunAtStep(EffectStep r) external pure override returns (bool) {
        return r == EffectStep.OnApply;
    }

    function onApply(uint256, bytes32, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32, bool removeAfterRun)
    {
        bytes32 indexHash = keccak256(abi.encode(targetIndex, monIndex));
        ENGINE.setGlobalKV(indexHash, 1);
        return (bytes32(0), false);
    }

    function shouldApply(bytes32, uint256 targetIndex, uint256 monIndex) external view override returns (bool) {
        bytes32 indexHash = keccak256(abi.encode(targetIndex, monIndex));
        uint192 value = ENGINE.getGlobalKV(ENGINE.battleKeyForWrite(), indexHash);
        return value == 0;
    }
}
