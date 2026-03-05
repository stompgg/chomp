// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEffect} from "../../effects/IEffect.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract PoundGround is StandardAttack {
    constructor(ITypeCalculator _TYPE_CALCULATOR)
        StandardAttack(
            address(msg.sender),
            _TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Pound Ground",
                BASE_POWER: 95,
                STAMINA_COST: 3,
                ACCURACY: 100,
                MOVE_TYPE: Type.Earth,
                MOVE_CLASS: MoveClass.Physical,
                PRIORITY: DEFAULT_PRIORITY,
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        )
    {}
}
