// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

contract StatBoostsMove is IMoveSet {
    function name() external pure returns (string memory) {
        return "";
    }

    function move(
        IEngine engine,
        bytes32,
        uint256 attackerPlayerIndex,
        uint256,
        uint256 targetBits,
        uint256 activesPacked,
        uint16 extraData,
        uint256
    ) external {
        // Unpack the 12-bit payload: [boostAmount:7 | statIndex:3 | monIndex:2]; the boost
        // targets the submitter's own side.
        uint256 playerIndex = attackerPlayerIndex;
        uint256 monIndex = uint256(extraData) & 0x3;
        uint256 statIndex = (uint256(extraData) >> 2) & 0x7;
        int32 boostAmount = int32(uint32((uint256(extraData) >> 5) & 0x7F));

        StatBoostType boostType = StatBoostType.Multiply;

        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName(statIndex), boostPercent: uint8(uint32(boostAmount)), boostType: boostType
        });
        engine.addStatBoost(playerIndex, monIndex, statBoosts, StatBoostFlag.Temp);
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return 0;
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 0;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Air;
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
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}
