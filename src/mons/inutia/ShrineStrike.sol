// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";

import {IEffect} from "../../effects/IEffect.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract ShrineStrike is StandardAttack {
    int32 public constant HEAL_DENOM = 16;

    constructor(IEngine ENGINE, ITypeCalculator TYPE_CALCULATOR)
        StandardAttack(
            address(msg.sender),
            ENGINE,
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Shrine Strike",
                BASE_POWER: 90,
                STAMINA_COST: 2,
                ACCURACY: 100,
                MOVE_TYPE: Type.Water,
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
        // Deal the damage and inflict panic
        super.move(battleKey, attackerPlayerIndex, extraData, rng);

        // Heal HP for heal denom
        uint256 activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex];
        int32 healAmount =
            int32(ENGINE.getMonValueForBattle(battleKey, attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp))
            / HEAL_DENOM;

        // Prevent overhealing
        int32 existingHpDelta =
            ENGINE.getMonStateForBattle(battleKey, attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp);
        if (existingHpDelta + healAmount > 0) {
            healAmount = 0 - existingHpDelta;
        }
        ENGINE.updateMonState(attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp, healAmount);
    }
}
