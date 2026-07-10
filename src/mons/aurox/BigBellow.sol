// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import {MoveMeta, StatBoostToApply} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract BigBellow is IMoveSet {
    uint8 public constant SP_ATTACK_DEBUFF_PERCENT = 50;
    uint8 public constant SPEED_DEBUFF_PERCENT = 50;

    function name() public pure override returns (string memory) {
        return "Big Bellow";
    }

    function move(
        IEngine engine,
        bytes32,
        uint256,
        uint256,
        uint256 targetBits,
        uint256 activesPacked,
        uint16,
        uint256
    ) external {
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot == NO_SLOT) {
            return; // no chosen target (defensive; the engine fizzles first)
        }
        uint256 defenderPlayerIndex = TargetLib.sideOf(targetSlot);
        uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, targetSlot);
        // Halve the target's SpATK and Speed until it switches out (Temp).
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](2);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack,
            boostPercent: SP_ATTACK_DEBUFF_PERCENT,
            boostType: StatBoostType.Divide
        });
        statBoosts[1] = StatBoostToApply({
            stat: MonStateIndexName.Speed,
            boostPercent: SPEED_DEBUFF_PERCENT,
            boostType: StatBoostType.Divide
        });
        engine.addStatBoost(defenderPlayerIndex, defenderMonIndex, statBoosts, StatBoostFlag.Temp);
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 1;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Metal;
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
