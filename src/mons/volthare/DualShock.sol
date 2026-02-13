// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";
import {Overclock} from "../../effects/battlefield/Overclock.sol";

contract DualShock is StandardAttack {

    IEffect immutable ZAP_STATUS;
    Overclock immutable OVERCLOCK;

    constructor(IEngine ENGINE, ITypeCalculator TYPE_CALCULATOR, IEffect _ZAP_STATUS, Overclock _OVERCLOCK)
        StandardAttack(
            address(msg.sender),
            ENGINE,
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Dual Shock",
                BASE_POWER: 60,
                STAMINA_COST: 0,
                ACCURACY: 100,
                MOVE_TYPE: Type.Cyber,
                MOVE_CLASS: MoveClass.Special,
                PRIORITY: DEFAULT_PRIORITY,
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        )
    {
        ZAP_STATUS = _ZAP_STATUS;
        OVERCLOCK = _OVERCLOCK;
    }

    function move(
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderMonIndex,
        uint240 extraData,
        uint256 rng
    ) public override {
        // Deal the damage
        super.move(battleKey, attackerPlayerIndex, attackerMonIndex, defenderMonIndex, extraData, rng);

        // Apply Zap to self
        ENGINE.addEffect(attackerPlayerIndex, attackerMonIndex, ZAP_STATUS, "");

        // Apply Overclock to team
        OVERCLOCK.applyOverclock(battleKey, attackerPlayerIndex);
    }
}
