// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT} from "../../src/Constants.sol";
import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

contract WideDataEffect is BasicEffect {
    bytes32 public constant INITIAL_DATA = bytes32((uint256(1) << 200) | 123);

    function name() external pure override returns (string memory) {
        return "Wide Data";
    }

    function getStepsBitmap() external pure override returns (uint32) {
        return uint16(1) | ALWAYS_APPLIES_BIT;
    }

    function onApply(IEngine, bytes32, uint256, bytes32, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (INITIAL_DATA, false);
    }
}
