// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {IEffect} from "../../effects/IEffect.sol";

contract VitalSiphon is StandardAttack {

    uint32 public constant STAMINA_STEAL_PERCENT = 50;

    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR)
        StandardAttack(
            address(msg.sender),
            _ENGINE,
            _TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Vital Siphon",
                BASE_POWER: 40,
                STAMINA_COST: 2,
                ACCURACY: 90,
                MOVE_TYPE: Type.Cosmic,
                MOVE_CLASS: MoveClass.Special,
                PRIORITY: DEFAULT_PRIORITY,
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        )
    {}

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240 extraData, uint256 rng)
        public
        override
    {
        // Deal the damage
        super.move(battleKey, attackerPlayerIndex, extraData, rng);

        // 50% chance to steal stamina
        if (rng % 100 >= STAMINA_STEAL_PERCENT) {
            uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
            uint256 defenderMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[defenderPlayerIndex];
            
            // Check if opponent has at least 1 stamina
            int32 defenderStamina = ENGINE.getMonStateForBattle(battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Stamina);
            uint32 defenderBaseStamina = ENGINE.getMonValueForBattle(battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Stamina);
            int32 totalDefenderStamina = int32(defenderBaseStamina) + defenderStamina;
            
            if (totalDefenderStamina >= 1) {
                // Steal 1 stamina from opponent
                ENGINE.updateMonState(defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Stamina, -1);
                
                // Give 1 stamina to self
                uint256 activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex];
                ENGINE.updateMonState(attackerPlayerIndex, activeMonIndex, MonStateIndexName.Stamina, 1);
            }
        }
    }
}

