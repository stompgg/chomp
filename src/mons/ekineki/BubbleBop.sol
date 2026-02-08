// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {NineNineNineLib} from "./999Lib.sol";

contract BubbleBop is StandardAttack {
    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR)
        StandardAttack(
            address(msg.sender),
            _ENGINE,
            _TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Bubble Bop",
                BASE_POWER: 50,
                STAMINA_COST: 3,
                ACCURACY: 100,
                MOVE_TYPE: Type.Liquid,
                MOVE_CLASS: MoveClass.Special,
                PRIORITY: DEFAULT_PRIORITY,
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        )
    {}

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256 rng) public override {
        uint32 effectiveCritRate = NineNineNineLib._getEffectiveCritRate(ENGINE, battleKey, attackerPlayerIndex);

        // First hit
        AttackCalculator._calculateDamage(
            ENGINE,
            TYPE_CALCULATOR,
            battleKey,
            attackerPlayerIndex,
            basePower(battleKey),
            accuracy(battleKey),
            volatility(battleKey),
            moveType(battleKey),
            moveClass(battleKey),
            rng,
            effectiveCritRate
        );

        // Second hit with different RNG
        uint256 rng2 = uint256(keccak256(abi.encode(rng, "SECOND_HIT")));
        AttackCalculator._calculateDamage(
            ENGINE,
            TYPE_CALCULATOR,
            battleKey,
            attackerPlayerIndex,
            basePower(battleKey),
            accuracy(battleKey),
            volatility(battleKey),
            moveType(battleKey),
            moveClass(battleKey),
            rng2,
            effectiveCritRate
        );
    }
}
