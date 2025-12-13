// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";

import {IEffect} from "../../effects/IEffect.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract WitherAway is StandardAttack {
    constructor(IEngine ENGINE, ITypeCalculator TYPE_CALCULATOR, IEffect PANIC_STATUS)
        StandardAttack(
            address(msg.sender),
            ENGINE,
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Wither Away",
                BASE_POWER: 60,
                STAMINA_COST: 3,
                ACCURACY: 100,
                MOVE_TYPE: Type.Yang,
                MOVE_CLASS: MoveClass.Special,
                PRIORITY: DEFAULT_PRIORITY,
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 100,
                EFFECT: PANIC_STATUS
            })
        )
    {}

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240 extraData, uint256 rng)
        public
        override
    {
        // Deal the damage and inflict panic
        super.move(battleKey, attackerPlayerIndex, extraData, rng);

        // Also inflict panic on self
        uint256 activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex];
        ENGINE.addEffect(attackerPlayerIndex, activeMonIndex, effect(battleKey), "");
    }
}
