// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

contract SelfSwitchAndDamageMove is IMoveSet {

    IEngine immutable ENGINE;
    int32 immutable DAMAGE;

    constructor(IEngine _ENGINE, int32 power) {
        ENGINE = _ENGINE;
        DAMAGE = power;
    }

    function name() external pure returns (string memory) {
        return "Self Switch And Damage Move";
    }

    function move(bytes32, uint256 attackerPlayerIndex, uint240 extraData, uint256) external {
        uint256 monToSwitchIndex = uint256(extraData);

        // Deal damage first to opponent
        uint256 otherPlayerIndex = (attackerPlayerIndex + 1) % 2;
        uint256 otherPlayerActiveMonIndex =
            ENGINE.getActiveMonIndexForBattleState(ENGINE.battleKeyForWrite())[otherPlayerIndex];
        ENGINE.dealDamage(otherPlayerIndex, otherPlayerActiveMonIndex, DAMAGE);

        // Use the new switchActiveMon function
        ENGINE.switchActiveMon(attackerPlayerIndex, monToSwitchIndex);
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return 0;
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 0;
    }

    function moveType(bytes32) external pure returns (Type) {
        return Type.Fire;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function moveClass(bytes32) external pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function basePower(bytes32) external view returns (uint32) {
        return uint32(DAMAGE);
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.SelfTeamIndex;
    }
}