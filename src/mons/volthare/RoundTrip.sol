// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";

import {IEffect} from "../../effects/IEffect.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract RoundTrip is StandardAttack {
    constructor(ITypeCalculator TYPE_CALCULATOR)
        StandardAttack(
            address(msg.sender),
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Round Trip",
                BASE_POWER: 30,
                STAMINA_COST: 1,
                ACCURACY: 100,
                MOVE_TYPE: Type.Lightning,
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
        uint256,
        uint256 defenderMonIndex,
        uint240 extraData,
        uint256 rng
    ) public override {
        // Deal the damage
        (int32 damage,) = engine.dispatchStandardAttack(
            attackerPlayerIndex, defenderMonIndex,
            basePower(battleKey), accuracy(battleKey), volatility(battleKey),
            moveType(engine, battleKey), moveClass(engine, battleKey),
            critRate(battleKey), uint8(effectAccuracy(battleKey)), effect(battleKey), rng
        );

        if (damage > 0) {
            // extraData contains the swap index as raw uint240
            uint256 swapIndex = uint256(extraData);
            engine.switchActiveMon(attackerPlayerIndex, swapIndex);
        }
    }

    function extraDataType() public pure override returns (ExtraDataType) {
        return ExtraDataType.SelfTeamIndex;
    }
    // Inherits StandardAttack.getMeta, which calls extraDataType() internally and resolves
    // to this override.
}
