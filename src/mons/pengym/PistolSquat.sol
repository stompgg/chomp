// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";

import {IEffect} from "../../effects/IEffect.sol";
import {SwitchTargetLib} from "../../lib/SwitchTargetLib.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract PistolSquat is StandardAttack {
    constructor(ITypeCalculator TYPE_CALCULATOR)
        StandardAttack(
            address(msg.sender),
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Pistol Squat",
                BASE_POWER: 80,
                STAMINA_COST: 2,
                ACCURACY: 100,
                MOVE_TYPE: Type.Metal,
                MOVE_CLASS: MoveClass.Physical,
                PRIORITY: DEFAULT_PRIORITY - 1, // This is -1 priority
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
        if (targetSlot == NO_SLOT) {
            return; // no chosen target (defensive; the engine fizzles first)
        }
        uint256 otherPlayerIndex = TargetLib.sideOf(targetSlot);
        uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, targetSlot);
        // Deal the damage
        engine.dispatchStandardAttack(
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

        // Deal damage and then force a switch if the opposing mon is not KO'ed
        bool isKOed = engine.getMonStateForBattle(
            battleKey, otherPlayerIndex, defenderMonIndex, MonStateIndexName.IsKnockedOut
        ) == 1;
        if (!isKOed) {
            int32 target = SwitchTargetLib.findRandomNonKOed(
                engine,
                battleKey,
                otherPlayerIndex,
                targetSlot & 1,
                defenderMonIndex,
                TargetLib.activeAt(activesPacked, targetSlot ^ 1),
                rng
            );
            if (target != -1) {
                engine.switchActiveMonForSlot(otherPlayerIndex, targetSlot & 1, uint256(uint32(target)));
            }
        }
    }
}
