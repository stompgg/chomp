// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import {EffectInstance} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {StatusEffectLib} from "../../effects/status/StatusEffectLib.sol";

contract GildedRecovery is IMoveSet {
    int32 public constant HEAL_PERCENT = 50; 
    int32 public constant STAMINA_BONUS = 1;

    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() public pure override returns (string memory) {
        return "Gilded Recovery";
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240 extraData, uint256) external {
        // extraData contains the mon index as raw uint240
        uint256 targetMonIndex = uint256(extraData);

        // Check if the target mon has a status effect
        bytes32 statusKey = StatusEffectLib.getKeyForMonIndex(attackerPlayerIndex, targetMonIndex);
        uint192 statusFlag = ENGINE.getGlobalKV(battleKey, statusKey);

        // If the mon has a status effect, remove it and heal
        if (statusFlag != 0) {
            // Find and remove the status effect
            (EffectInstance[] memory effects, uint256[] memory indices) = ENGINE.getEffects(battleKey, attackerPlayerIndex, targetMonIndex);
            address statusEffectAddress = address(uint160(statusFlag));

            for (uint256 i = 0; i < effects.length; i++) {
                if (address(effects[i].effect) == statusEffectAddress) {
                    ENGINE.removeEffect(attackerPlayerIndex, targetMonIndex, indices[i]);
                    break;
                }
            }
            // Give +1 stamina
            ENGINE.updateMonState(attackerPlayerIndex, targetMonIndex, MonStateIndexName.Stamina, STAMINA_BONUS);

            // Heal 50% of max HP for self
            uint256 activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex];
            int32 maxHp =
                int32(ENGINE.getMonValueForBattle(battleKey, attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp));
            int32 healAmount = (maxHp * HEAL_PERCENT) / 100;

            // Don't overheal
            int32 currentHpDelta =
                ENGINE.getMonStateForBattle(battleKey, attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp);
            if (currentHpDelta + healAmount > 0) {
                healAmount = -currentHpDelta;
            }

            if (healAmount != 0) {
                ENGINE.updateMonState(attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp, healAmount);
            }
        }
        // If no status effect, do nothing
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 2;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Mythic;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.SelfTeamIndex;
    }
}