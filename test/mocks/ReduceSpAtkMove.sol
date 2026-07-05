// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {TargetLib} from "../../src/lib/TargetLib.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

/**
 * @title ReduceSpAtkMove
 * @notice Simple move that reduces the opposing mon's SpecialAttack stat by 1
 * @dev Used to test the OnUpdateMonState lifecycle hook
 */
contract ReduceSpAtkMove is IMoveSet {
    function name() external pure returns (string memory) {
        return "Reduce SpAtk";
    }

    function move(
        IEngine engine,
        bytes32,
        uint256 attackerPlayerIndex,
        uint256,
        uint256 targetBits,
        uint256 activesPacked,
        uint16,
        uint256
    ) external {
        uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, TargetLib.lowestSlot(targetBits));
        // Get the opposing player's index
        uint256 opposingPlayerIndex = (attackerPlayerIndex + 1) % 2;

        // Reduce the opposing mon's SpecialAttack via the stat-boost system. Stats can only be
        // written through stat boosts now; a 10% divide on a base of 10 lands exactly -1, matching
        // the legacy direct updateMonState(SpecialAttack, -1), and still fires OnUpdateMonState.
        StatBoostToApply[] memory boosts = new StatBoostToApply[](1);
        boosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack, boostPercent: 10, boostType: StatBoostType.Divide
        });
        engine.addStatBoost(opposingPlayerIndex, defenderMonIndex, boosts, StatBoostFlag.Temp);
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return 0;
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 0;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Math;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
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
            targetSpec: TargetSpec.AnyOtherSlot,
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            extraDataType: extraDataType(),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}
