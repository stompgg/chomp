// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEffect} from "../../effects/IEffect.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract Electrocute is StandardAttack {
    constructor(ITypeCalculator TYPE_CALCULATOR, IEffect ZAP_STATUS)
        StandardAttack(
            address(msg.sender),
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Electrocute",
                BASE_POWER: 90,
                STAMINA_COST: 2,
                ACCURACY: 100,
                MOVE_TYPE: Type.Lightning,
                MOVE_CLASS: MoveClass.Special,
                PRIORITY: DEFAULT_PRIORITY,
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 10,
                EFFECT: ZAP_STATUS
            })
        )
    {}
}
