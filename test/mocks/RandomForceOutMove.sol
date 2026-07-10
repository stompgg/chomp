// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {SwitchTargetLib} from "../../src/lib/SwitchTargetLib.sol";
import {TargetLib} from "../../src/lib/TargetLib.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

/// @dev Forces the targeted slot to swap to a random legal replacement (the PistolSquat /
///      HardReset force-out shape, minus the damage).
contract RandomForceOutMove is IMoveSet {
    function name() external pure returns (string memory) {
        return "Random Force Out";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        uint256,
        uint256 targetBits,
        uint256 activesPacked,
        uint16,
        uint256 rng
    ) external {
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot == NO_SLOT) {
            return;
        }
        uint256 targetSide = TargetLib.sideOf(targetSlot);
        uint256 targetMon = TargetLib.activeAt(activesPacked, targetSlot);
        int32 pick = SwitchTargetLib.findRandomNonKOed(engine, battleKey, targetSide, targetSlot & 1, targetMon, rng);
        if (pick != -1) {
            engine.switchActiveMonForSlot(targetSide, targetSlot & 1, uint256(uint32(pick)));
        }
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 1;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Air;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}
