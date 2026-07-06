// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {MoveClass, Type, TargetSpec} from "../../src/Enums.sol";
import {IEngine} from "../../src/IEngine.sol";
import {MoveMeta} from "../../src/Structs.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

contract EditEffectAttack is IMoveSet {
    function name() external pure returns (string memory) {
        return "Edit Effect Attack";
    }

    function move(
        IEngine engine,
        bytes32,
        uint256,
        uint256,
        uint256 targetBits,
        uint256 activesPacked,
        uint16 extraData,
        uint256
    ) external {
        // Unpack extraData (16 bits): bits 0..1 = targetIndex (0=p0, 1=p1, 2=global),
        // bits 2..15 = effectIndex.
        uint256 targetIndex = uint256(extraData) & 0x3;
        uint256 effectIndex = uint256(extraData) >> 2;
        engine.editEffect(targetIndex, effectIndex, bytes32(uint256(69)));
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

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function basePower(bytes32) external pure returns (uint32) {
        return 0;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            targetSpec: TargetSpec.AnyOtherSlot,
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}
