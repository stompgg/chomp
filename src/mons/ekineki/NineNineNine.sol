// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {MoveMeta} from "../../Structs.sol";
import {NineNineNineLib} from "./NineNineNineLib.sol";

contract NineNineNine is IMoveSet {
    constructor() {}

    function name() external pure returns (string memory) {
        return "Nine Nine Nine";
    }

    function move(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256, uint256, uint16, uint256) external {
        // Set crit boost for the next turn
        uint256 currentTurn = engine.getTurnIdForBattleState(battleKey);
        uint64 key = NineNineNineLib._getKey(attackerPlayerIndex);
        engine.setGlobalKV(key, uint192(currentTurn + 1));
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 1;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Math;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function isValidTarget(IEngine, bytes32, uint16) external pure returns (bool) {
        return true;
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
