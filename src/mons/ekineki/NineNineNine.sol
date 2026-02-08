// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {EkinekiLib} from "./EkinekiLib.sol";

contract NineNineNine is IMoveSet {
    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() external pure returns (string memory) {
        return "999";
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256) external {
        // Set crit boost for the next turn
        uint256 currentTurn = ENGINE.getTurnIdForBattleState(battleKey);
        bytes32 key = EkinekiLib._getNineNineNineKey(attackerPlayerIndex);
        ENGINE.setGlobalKV(key, uint192(currentTurn + 1));
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 2;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(bytes32) external pure returns (Type) {
        return Type.Math;
    }

    function moveClass(bytes32) external pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}
