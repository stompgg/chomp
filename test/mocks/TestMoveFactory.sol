// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
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

    function move(IEngine engine, bytes32, uint256 attackerPlayerIndex, uint256, uint256 defenderMonIndex, uint240, uint256) external {
        uint256 opponentIndex = (attackerPlayerIndex + 1) % 2;
        engine.dealDamage(opponentIndex, defenderMonIndex, _damage);
    }

    function priority(IEngine, bytes32, uint256) external pure returns (uint32) {
        return 1;
    }

    function stamina(IEngine, bytes32, uint256, uint256) external view returns (uint32) {
        return _staminaCost;
    }

    function moveType(IEngine, bytes32) external view returns (Type) {
        return _moveType;
    }

    function isValidTarget(IEngine, bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function moveClass(IEngine, bytes32) external view returns (MoveClass) {
        return _moveClass;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

contract TestMoveFactory {

    function createMove(MoveClass moveClassToUse, Type moveTypeToUse, uint32 staminaCost, int32 damage) external returns (IMoveSet) {
        return new TestMove(moveClassToUse, moveTypeToUse, staminaCost, damage);
    }
}
