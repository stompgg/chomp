// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract FoulLanguage is StandardAttack {
    // Half of the damage dealt is also dealt to Malalien.
    int32 public constant RECOIL_DENOM = 2;

    constructor(ITypeCalculator TYPE_CALCULATOR)
        StandardAttack(
            address(msg.sender),
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Foul Language",
                BASE_POWER: 60,
                STAMINA_COST: 2,
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
    {}

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256 activesPacked,
        uint16,
        uint256 rng
    ) public override {
        (int32 damage,) = _move(engine, battleKey, attackerPlayerIndex, targetBits, rng);
        if (damage > 0) {
            engine.dealDamage(attackerPlayerIndex, attackerMonIndex, damage / RECOIL_DENOM);
        }
    }
}
