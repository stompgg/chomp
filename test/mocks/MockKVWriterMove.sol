// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

/// @notice Test-only move that writes a single, caller-chosen (key, value) pair to globalKV.
/// @dev extraData layout: lower 64 bits = key, upper 176 bits = value. A 0-value input
///      writes 1 by default so tests can quickly assert "something was written" without
///      encoding a non-zero value every time.
contract MockKVWriterMove is IMoveSet {
    function name() external pure returns (string memory) {
        return "MockKVWriter";
    }

    function move(IEngine engine, bytes32, uint256, uint256, uint256, uint240 extraData, uint256) external {
        uint64 key = uint64(extraData);
        uint192 value = uint192(uint256(extraData) >> 64);
        if (value == 0) {
            value = 1;
        }
        engine.setGlobalKV(key, value);
    }

    function stamina(IEngine, bytes32, uint256, uint256) external pure returns (uint32) {
        return 0;
    }

    function priority(IEngine, bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) external pure returns (Type) {
        return Type.None;
    }

    function moveClass(IEngine, bytes32) external pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function isValidTarget(IEngine, bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}
