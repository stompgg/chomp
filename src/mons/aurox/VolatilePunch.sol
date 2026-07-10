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

contract VolatilePunch is StandardAttack {
    uint32 public constant STATUS_EFFECT_CHANCE = 50;

    IEffect immutable BURN_STATUS;
    IEffect immutable FROSTBITE_STATUS;

    constructor(ITypeCalculator TYPE_CALCULATOR, IEffect _BURN_STATUS, IEffect _FROSTBITE_STATUS)
        StandardAttack(
            address(msg.sender),
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Volatile Punch",
                BASE_POWER: 40,
                STAMINA_COST: 3,
                ACCURACY: 100,
                MOVE_TYPE: Type.Metal,
                MOVE_CLASS: MoveClass.Physical,
                PRIORITY: DEFAULT_PRIORITY,
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        )
    {
        BURN_STATUS = _BURN_STATUS;
        FROSTBITE_STATUS = _FROSTBITE_STATUS;
    }

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
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot == NO_SLOT) {
            return; // no chosen target (defensive; the engine fizzles first)
        }
        uint256 defenderPlayerIndex = TargetLib.sideOf(targetSlot);
        uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, targetSlot);
        (int32 damage,) = engine.dispatchStandardAttack(
            attackerPlayerIndex,
            attackerMonIndex,
            targetBits,
            basePower(battleKey),
            accuracy(battleKey),
            volatility(battleKey),
            moveType(engine, battleKey),
            moveClass(engine, battleKey),
            critRate(battleKey),
            uint8(effectAccuracy(battleKey)),
            effect(battleKey),
            rng
        );

        // Apply status effects if damage was dealt
        if (damage > 0) {
            // Use a different part of the RNG for status application. Mix in attacker player index
            // to break symmetry on mirror matchups.
            uint256 statusRng = uint256(keccak256(abi.encode(rng, attackerPlayerIndex, "STATUS_EFFECT")));

            if ((statusRng % 100) < STATUS_EFFECT_CHANCE) {
                uint256 statusSelectorRng = uint256(keccak256(abi.encode(rng, attackerPlayerIndex, "STATUS_SELECTOR")));
                if (statusSelectorRng % 2 == 0) {
                    engine.addEffect(defenderPlayerIndex, defenderMonIndex, BURN_STATUS, "");
                } else {
                    engine.addEffect(defenderPlayerIndex, defenderMonIndex, FROSTBITE_STATUS, "");
                }
            }
        }
    }
}
