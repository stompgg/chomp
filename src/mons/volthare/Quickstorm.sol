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

contract Quickstorm is StandardAttack {
    IEffect immutable ZAP_STATUS;

    constructor(ITypeCalculator TYPE_CALCULATOR, IEffect _ZAP_STATUS)
        StandardAttack(
            address(msg.sender),
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Quickstorm",
                BASE_POWER: 30,
                STAMINA_COST: 2,
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
    {
        ZAP_STATUS = _ZAP_STATUS;
    }

    // Shared with PreemptiveShock's switch-in anchor: the turn Volthare first gets to act after
    // entering play. Only that turn matches, so Quickstorm is a strict first-action-only move.
    function _windowKey(uint256 playerIndex, uint256 monIndex) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encode(playerIndex, monIndex, "QUICKSTORM"))));
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
        // Anchor stores firstActTurn+1 (0 = unset); usable only on that turn.
        uint192 anchor = engine.getGlobalKV(battleKey, _windowKey(attackerPlayerIndex, attackerMonIndex));
        if (anchor == 0 || uint256(anchor - 1) != engine.getTurnIdForBattleState(battleKey)) {
            return;
        }

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

        // Inflict Zap on the targeted opponent.
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot != NO_SLOT) {
            uint256 defenderPlayerIndex = TargetLib.sideOf(targetSlot);
            uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, targetSlot);
            engine.addEffect(defenderPlayerIndex, defenderMonIndex, ZAP_STATUS, "");
        }
    }
}
