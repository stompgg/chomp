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

    function move(IEngine engine, bytes32, uint256, uint256, uint256, uint16 extraData, uint256) external {
        // Unpack extraData (16 bits): bits 0..1 = targetIndex (0=p0, 1=p1, 2=global),
        // bits 2..5 = monIndex (max 15), bits 6..15 = effectIndex (max 1023).
        uint256 targetIndex = uint256(extraData) & 0x3;
        uint256 monIndex = (uint256(extraData) >> 2) & 0xF;
        uint256 effectIndex = (uint256(extraData) >> 6) & 0x3FF;
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

    function isValidTarget(IEngine, bytes32, uint16) external pure returns (bool) {
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
