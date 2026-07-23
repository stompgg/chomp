// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";

import {IEffect} from "../../effects/IEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {IMoveResolver} from "../../moves/IMoveResolver.sol";
import {MoveCommandLib} from "../../moves/MoveCommandLib.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

// @move-resolver
contract HitAndDip is StandardAttack, IMoveResolver {
    constructor(ITypeCalculator TYPE_CALCULATOR)
        StandardAttack(
            address(msg.sender),
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Hit And Dip",
                BASE_POWER: 60,
                STAMINA_COST: 2,
                ACCURACY: 100,
                MOVE_TYPE: Type.Faith,
                MOVE_CLASS: MoveClass.Special,
                PRIORITY: DEFAULT_PRIORITY,
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 100,
                EFFECT: IEffect(address(0))
            })
        )
    {}

    function resolveMove(
        uint32 continuation,
        int32 priorResult,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256,
        uint256 activesPacked,
        uint16 extraData,
        uint256
    ) external view returns (uint256 command, uint32 nextContinuation) {
        if (continuation == 0) {
            return (
                MoveCommandLib.attack(
                    uint32(basePower(bytes32(0))),
                    uint8(accuracy(bytes32(0))),
                    uint8(volatility(bytes32(0))),
                    moveType(IEngine(address(0)), bytes32(0)),
                    moveClass(IEngine(address(0)), bytes32(0)),
                    uint8(critRate(bytes32(0))),
                    uint8(effectAccuracy(bytes32(0))),
                    effect(bytes32(0))
                ),
                1
            );
        }
        if (continuation == 1 && priorResult > 0) {
            uint256 slot = TargetLib.slotOfMon(activesPacked, attackerPlayerIndex, attackerMonIndex);
            if (slot != NO_SLOT) {
                command = MoveCommandLib.switchMon(attackerPlayerIndex, slot & 1, uint256(extraData));
            }
        }
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256 activesPacked,
        uint16 extraData,
        uint256 rng
    ) public override {
        // Deal the damage
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

        if (damage > 0) {
            // extraData contains the swap index as raw uint16
            uint256 swapIndex = uint256(extraData);
            engine.switchActiveMonForSlot(
                attackerPlayerIndex,
                TargetLib.slotOfMon(activesPacked, attackerPlayerIndex, attackerMonIndex) & 1,
                swapIndex
            );
        }
    }
}
