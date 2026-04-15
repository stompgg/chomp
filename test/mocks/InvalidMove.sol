// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

contract InvalidMove is IMoveSet {

    function name() external pure returns (string memory) {
        return "Effect Attack";
    }

    function move(IEngine, bytes32, uint256, uint256, uint256, uint240, uint256) external pure {
        // No-op
    }

    function priority(IEngine, bytes32, uint256) external pure returns (uint32) {
        return 1;
    }

    function stamina(IEngine, bytes32, uint256, uint256) external pure returns (uint32) {
        return 1;
    }

    function moveType(IEngine, bytes32) external pure returns (Type) {
        return Type.Fire;
    }

    function isValidTarget(IEngine, bytes32, uint240) external pure returns (bool) {
        return false;
    }

    function moveClass(IEngine, bytes32) external pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function basePower(bytes32) external pure returns (uint32) {
        return 0;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}
