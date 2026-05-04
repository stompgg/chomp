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

    function name() external pure returns (string memory) {
        return "Reduce SpAtk";
    }

    function move(IEngine engine, bytes32, uint256 attackerPlayerIndex, uint256, uint256 defenderMonIndex, uint16, uint256) external {
        // Get the opposing player's index
        uint256 opposingPlayerIndex = (attackerPlayerIndex + 1) % 2;

        // Reduce the opposing mon's SpecialAttack by 1
        engine.updateMonState(opposingPlayerIndex, defenderMonIndex, MonStateIndexName.SpecialAttack, -1);
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return 0;
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 0;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Math;
    }

    function isValidTarget(IEngine, bytes32, uint16) external pure returns (bool) {
        return true;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
    }

    function basePower(bytes32) external pure returns (uint32) {
        return 0;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            extraDataType: extraDataType(),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }

}
