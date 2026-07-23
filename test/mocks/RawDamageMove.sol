// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {TargetLib} from "../../src/lib/TargetLib.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

/// Deals an exact `int32` to the target via `dealDamage` — lets a test drive the raw damage value
/// the engine has to absorb, including the clamped `type(int32).max` the damage formula can produce.
contract RawDamageMove is IMoveSet {
    int32 immutable DAMAGE;

    constructor(int32 damage) {
        DAMAGE = damage;
    }

    function name() external pure returns (string memory) {
        return "Raw Damage Move";
    }

    function move(IEngine engine, bytes32, uint256 attackerPlayerIndex, uint256, uint256 targetBits, uint256 activesPacked, uint16, uint256)
        external
    {
        uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, TargetLib.lowestSlot(targetBits));
        engine.dealDamage((attackerPlayerIndex + 1) % 2, defenderMonIndex, DAMAGE);
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
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
