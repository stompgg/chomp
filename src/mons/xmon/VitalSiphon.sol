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

contract VitalSiphon is StandardAttack {
    uint32 public constant STAMINA_STEAL_PERCENT = 50;

    constructor(ITypeCalculator _TYPE_CALCULATOR)
        StandardAttack(
            address(msg.sender),
            _TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Vital Siphon",
                BASE_POWER: 40,
                STAMINA_COST: 2,
                ACCURACY: 90,
                MOVE_TYPE: Type.Cosmic,
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
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot == 4) return; // no chosen target (defensive; the engine fizzles first)
        uint256 defenderPlayerIndex = TargetLib.sideOf(targetSlot);
        uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, targetSlot);
        // Deal the damage
        (int32 damage,) = engine.dispatchStandardAttack(
            attackerPlayerIndex,
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

        // 50% chance to steal stamina (assuming move dealt damage). Mix in attacker player index to
        // break symmetry on mirror matchups.
        uint256 stealRng = uint256(keccak256(abi.encode(rng, attackerPlayerIndex, "STAMINA_STEAL")));
        if (damage > 0 && stealRng % 100 >= STAMINA_STEAL_PERCENT) {

            // Check if opponent has at least 1 stamina
            int32 defenderStamina = engine.getMonStateForBattle(
                battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Stamina
            );
            uint32 defenderBaseStamina = engine.getMonValueForBattle(
                battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Stamina
            );
            int32 totalDefenderStamina = int32(defenderBaseStamina) + defenderStamina;

            if (totalDefenderStamina >= 1) {
                // Steal 1 stamina from opponent
                engine.updateMonState(defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Stamina, -1);

                // Give 1 stamina to self
                engine.updateMonState(attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Stamina, 1);
            }
        }
    }
}
