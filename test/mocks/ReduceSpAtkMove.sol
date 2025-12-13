// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

/**
 * @title ReduceSpAtkMove
 * @notice Simple move that reduces the opposing mon's SpecialAttack stat by 1
 * @dev Used to test the OnUpdateMonState lifecycle hook
 */
contract ReduceSpAtkMove is IMoveSet {
    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() external pure returns (string memory) {
        return "Reduce SpAtk";
    }

    function move(bytes32, uint256 attackerPlayerIndex, uint240, uint256) external {
        // Get the opposing player's index
        uint256 opposingPlayerIndex = (attackerPlayerIndex + 1) % 2;

        // Get the opposing player's active mon index
        uint256 opposingMonIndex = ENGINE.getActiveMonIndexForBattleState(ENGINE.battleKeyForWrite())[opposingPlayerIndex];

        // Reduce the opposing mon's SpecialAttack by 1
        ENGINE.updateMonState(opposingPlayerIndex, opposingMonIndex, MonStateIndexName.SpecialAttack, -1);
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return 0;
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 0;
    }

    function moveType(bytes32) external pure returns (Type) {
        return Type.Mind;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function moveClass(bytes32) external pure returns (MoveClass) {
        return MoveClass.Other;
    }

    function basePower(bytes32) external pure returns (uint32) {
        return 0;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}
