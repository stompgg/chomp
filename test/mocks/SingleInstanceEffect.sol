// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

contract SingleInstanceEffect is BasicEffect {

    function name() external pure override returns (string memory) {
        return "Instant Death";
    }

    // Steps: OnApply
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x01;
    }

    function onApply(IEngine engine, bytes32, uint256, bytes32, uint256 targetIndex, uint256 monIndex, uint256, uint256)
        external
        override
        returns (bytes32, bool removeAfterRun)
    {
        bytes32 indexHash = keccak256(abi.encode(targetIndex, monIndex));
        engine.setGlobalKV(indexHash, 1);
        return (bytes32(0), false);
    }

    function shouldApply(IEngine engine, bytes32 battleKey, bytes32, uint256 targetIndex, uint256 monIndex) external view override returns (bool) {
        bytes32 indexHash = keccak256(abi.encode(targetIndex, monIndex));
        uint192 value = engine.getGlobalKV(battleKey, indexHash);
        return value == 0;
    }
}
