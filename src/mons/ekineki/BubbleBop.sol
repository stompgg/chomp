// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {NineNineNineLib} from "./NineNineNineLib.sol";

contract BubbleBop is StandardAttack {
    constructor(ITypeCalculator _TYPE_CALCULATOR)
        StandardAttack(
            address(msg.sender),
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

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256,
        uint256 defenderMonIndex,
        uint240,
        uint256 rng
    ) public override {
        uint32 effectiveCritRate = NineNineNineLib._getEffectiveCritRate(engine, battleKey, attackerPlayerIndex);

        // First hit
        engine.dispatchStandardAttack(
            attackerPlayerIndex, defenderMonIndex,
            basePower(battleKey), accuracy(battleKey), volatility(battleKey),
            moveType(engine, battleKey), moveClass(engine, battleKey),
            effectiveCritRate, 0, IEffect(address(0)), rng
        );

        // Second hit with different RNG
        uint256 rng2 = uint256(keccak256(abi.encode(rng, "SECOND_HIT")));
        engine.dispatchStandardAttack(
            attackerPlayerIndex, defenderMonIndex,
            basePower(battleKey), accuracy(battleKey), volatility(battleKey),
            moveType(engine, battleKey), moveClass(engine, battleKey),
            effectiveCritRate, 0, IEffect(address(0)), rng2
        );
    }
}
