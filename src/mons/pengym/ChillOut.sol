// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEffect} from "../../effects/IEffect.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract ChillOut is StandardAttack {
    constructor(ITypeCalculator TYPE_CALCULATOR, IEffect FROSTBITE_STATUS)
        StandardAttack(
            address(msg.sender),
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Chill Out",
                BASE_POWER: 0,
                STAMINA_COST: 0,
                ACCURACY: 100,
                MOVE_TYPE: Type.Ice,
                MOVE_CLASS: MoveClass.Other,
                PRIORITY: DEFAULT_PRIORITY,
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 100,
                EFFECT: FROSTBITE_STATUS
            })
        )
    {}
}
