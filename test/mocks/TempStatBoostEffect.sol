// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

contract TempStatBoostEffect is BasicEffect {

    function name() external pure override returns (string memory) {
        return "";
    }

    // Steps: OnApply, OnMonSwitchOut
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x21;
    }

    function onApply(IEngine engine, bytes32, uint256, bytes32, uint256 targetIndex, uint256 monIndex, uint256, uint256)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        engine.updateMonState(targetIndex, monIndex, MonStateIndexName.Attack, 1);
        return (bytes32(0), false);
    }

    function onMonSwitchOut(IEngine engine, bytes32, uint256, bytes32, uint256 targetIndex, uint256 monIndex, uint256, uint256)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        engine.updateMonState(targetIndex, monIndex, MonStateIndexName.Attack, 1);
        return (bytes32(0), true);
    }
}
