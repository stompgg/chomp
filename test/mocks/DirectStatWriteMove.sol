// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

/**
 * @title DirectStatWriteMove
 * @notice Move that attempts to write a stat delta directly via updateMonState. Used to assert the
 *         Engine rejects direct stat writes (stats are owned by the inlined stat-boost system).
 */
contract DirectStatWriteMove is IMoveSet {
    function name() external pure returns (string memory) {
        return "Direct Stat Write";
    }

    function move(IEngine engine, bytes32, uint256 attackerPlayerIndex, uint256 attackerMonIndex, uint256, uint16, uint256)
        external
    {
        // Forbidden: stat deltas may only be changed through add/removeStatBoost.
        engine.updateMonState(attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Attack, 1);
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
