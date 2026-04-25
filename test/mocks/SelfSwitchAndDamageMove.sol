// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

contract SelfSwitchAndDamageMove is IMoveSet {

    int32 immutable DAMAGE;

    constructor(int32 power) {
        DAMAGE = power;
    }

    function name() external pure returns (string memory) {
        return "Self Switch And Damage Move";
    }

    function move(IEngine engine, bytes32, uint256 attackerPlayerIndex, uint256, uint256 defenderMonIndex, uint240 extraData, uint256) external {
        uint256 monToSwitchIndex = uint256(extraData);

        // Deal damage first to opponent
        uint256 otherPlayerIndex = (attackerPlayerIndex + 1) % 2;
        engine.dealDamage(otherPlayerIndex, defenderMonIndex, DAMAGE);

        // Use the new switchActiveMon function
        engine.switchActiveMon(attackerPlayerIndex, monToSwitchIndex);
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return 0;
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 0;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Fire;
    }

    function isValidTarget(IEngine, bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function basePower(bytes32) external view returns (uint32) {
        return uint32(DAMAGE);
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.SelfTeamIndex;
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
