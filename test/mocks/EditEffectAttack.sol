// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {ExtraDataType, MoveClass, Type} from "../../src/Enums.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {MoveMeta} from "../../src/Structs.sol";

contract EditEffectAttack is IMoveSet {

    function name() external pure returns (string memory) {
        return "Edit Effect Attack";
    }

    function move(IEngine engine, bytes32, uint256, uint256, uint256, uint240 extraData, uint256) external {
        // Unpack extraData: lower 80 bits = targetIndex, next 80 bits = monIndex, upper 80 bits = effectIndex
        uint256 targetIndex = uint256(extraData) & ((1 << 80) - 1);
        uint256 monIndex = (uint256(extraData) >> 80) & ((1 << 80) - 1);
        uint256 effectIndex = (uint256(extraData) >> 160) & ((1 << 80) - 1);
        engine.editEffect(targetIndex, monIndex, effectIndex, bytes32(uint256(69)));
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return 1;
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
