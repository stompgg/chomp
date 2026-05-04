// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {MoveMeta} from "../../src/Structs.sol";
import {MoveClass, Type, ExtraDataType} from "../../src/Enums.sol";

contract TestMove is IMoveSet {

    MoveClass private _moveClass;
    Type private _moveType;
    uint32 private _staminaCost;
    int32 private _damage;

    constructor(MoveClass moveClassToUse, Type moveTypeToUse, uint32 staminaCost, int32 damage) {
        _moveClass = moveClassToUse;
        _moveType = moveTypeToUse;
        _staminaCost = staminaCost;
        _damage = damage;
    }

    function name() external pure returns (string memory) {
        return "Test Move";
    }

    function move(IEngine engine, bytes32, uint256 attackerPlayerIndex, uint256, uint256 defenderMonIndex, uint16, uint256) external {
        uint256 opponentIndex = (attackerPlayerIndex + 1) % 2;
        engine.dealDamage(opponentIndex, defenderMonIndex, _damage);
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return 1;
    }

    function stamina(IEngine, bytes32, uint256, uint256) public view returns (uint32) {
        return _staminaCost;
    }

    function moveType(IEngine, bytes32) public view returns (Type) {
        return _moveType;
    }

    function isValidTarget(IEngine, bytes32, uint16) external pure returns (bool) {
        return true;
    }

    function moveClass(IEngine, bytes32) public view returns (MoveClass) {
        return _moveClass;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        view
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

contract TestMoveFactory {

    function createMove(MoveClass moveClassToUse, Type moveTypeToUse, uint32 staminaCost, int32 damage) external returns (IMoveSet) {
        return new TestMove(moveClassToUse, moveTypeToUse, staminaCost, damage);
    }
}
