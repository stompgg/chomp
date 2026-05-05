// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

import {StatBoosts} from "../../src/effects/StatBoosts.sol";

contract StatBoostsMove is IMoveSet {
    StatBoosts immutable STAT_BOOSTS;

    constructor(StatBoosts _STAT_BOOSTS) {
        STAT_BOOSTS = _STAT_BOOSTS;
    }

    function name() external pure returns (string memory) {
        return "";
    }

    function move(IEngine engine, bytes32, uint256, uint256, uint256, uint16 extraData, uint256) external {
        // Unpack extraData: [boostAmount:8 | statIndex:4 | monIndex:3 | playerIndex:1]
        uint256 playerIndex = uint256(extraData) & 0x1;
        uint256 monIndex = (uint256(extraData) >> 1) & 0x7;
        uint256 statIndex = (uint256(extraData) >> 4) & 0xF;
        int32 boostAmount = int32(int8(uint8(uint256(extraData) >> 8)));

        // For all tests, we'll use Temp stat boosts with Multiply type for positive boosts
        // and Divide type for negative boosts
        StatBoostType boostType = boostAmount > 0 ? StatBoostType.Multiply : StatBoostType.Divide;

        // Convert negative boosts to positive for the divide operation
        if (boostAmount < 0) {
            boostAmount = -boostAmount;
        }

        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName(statIndex),
            boostPercent: uint8(uint32(boostAmount)),
            boostType: boostType
        });
        STAT_BOOSTS.addStatBoosts(engine, playerIndex, monIndex, statBoosts, StatBoostFlag.Temp);
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
