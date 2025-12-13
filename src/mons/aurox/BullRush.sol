// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {IEffect} from "../../effects/IEffect.sol";

contract BullRush is StandardAttack {
    int32 public constant SELF_DAMAGE_PERCENT = 10; // 10% of max HP

    constructor(IEngine ENGINE, ITypeCalculator TYPE_CALCULATOR)
        StandardAttack(
            address(msg.sender),
            ENGINE,
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Bull Rush",
                BASE_POWER: 80,
                STAMINA_COST: 2,
                ACCURACY: 100,
                MOVE_TYPE: Type.Metal,
                MOVE_CLASS: MoveClass.Physical,
                PRIORITY: DEFAULT_PRIORITY,
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        )
    {}

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256 rng)
        public
        override
    {
        // Deal the damage to opponent
        (int32 damage,) = _move(battleKey, attackerPlayerIndex, rng);

        // Deal self-damage (10% of max HP)
        if (damage > 0) {
            uint256[] memory activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey);
            uint256 attackerMonIndex = activeMonIndex[attackerPlayerIndex];

            int32 maxHp = int32(
                ENGINE.getMonValueForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp)
            );
            int32 selfDamage = (maxHp * SELF_DAMAGE_PERCENT) / 100;

            ENGINE.dealDamage(attackerPlayerIndex, attackerMonIndex, selfDamage);
        }
    }
}
