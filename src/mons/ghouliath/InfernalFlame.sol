// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEffect} from "../../effects/IEffect.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract InfernalFlame is StandardAttack {
    constructor(ITypeCalculator TYPE_CALCULATOR, IEffect BURN_STATUS)
        StandardAttack(
            address(msg.sender),
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Infernal Flame",
                BASE_POWER: 120,
                STAMINA_COST: 2,
                ACCURACY: 85,
                MOVE_TYPE: Type.Fire,
                MOVE_CLASS: MoveClass.Special,
                PRIORITY: DEFAULT_PRIORITY,
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 30,
                EFFECT: BURN_STATUS
            })
        )
    {}
}
