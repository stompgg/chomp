// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import {MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {StatusEffectLib} from "../../effects/status/StatusEffectLib.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract GildedRecovery is IMoveSet {
    int32 public constant HEAL_PERCENT = 50;
    int32 public constant STAMINA_BONUS = 1;

    function name() public pure override returns (string memory) {
        return "Gilded Recovery";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256 activesPacked,
        uint16 extraData,
        uint256
    ) external {
        // extraData contains the mon index as raw uint16
        uint256 targetMonIndex = uint256(extraData);

        // Check if the target mon has a status effect
        uint64 statusKey = StatusEffectLib.getKeyForMonIndex(attackerPlayerIndex, targetMonIndex);
        uint192 statusFlag = engine.getGlobalKV(battleKey, statusKey);

        // If the mon has a status effect, remove it and heal
        if (statusFlag != 0) {
            // Find and remove the status effect
            // Targeted lookup: engine scans for the status effect internally, no full-array build.
            address statusEffectAddress = address(uint160(statusFlag));
            (bool exists, uint256 idx,) =
                engine.getEffectData(battleKey, attackerPlayerIndex, targetMonIndex, statusEffectAddress);
            if (exists) {
                engine.removeEffect(attackerPlayerIndex, targetMonIndex, idx);
            }
            // Give +1 stamina
            engine.updateMonState(attackerPlayerIndex, targetMonIndex, MonStateIndexName.Stamina, STAMINA_BONUS);

            // Heal 50% of max HP for self
            int32 maxHp = int32(
                engine.getMonValueForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp)
            );
            int32 healAmount = (maxHp * HEAL_PERCENT) / 100;

            // Don't overheal
            int32 currentHpDelta =
                engine.getMonStateForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp);
            if (currentHpDelta + healAmount > 0) {
                healAmount = -currentHpDelta;
            }

            if (healAmount != 0) {
                engine.updateMonState(attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp, healAmount);
            }
        }
        // If no status effect, do nothing
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 2;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Faith;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
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
