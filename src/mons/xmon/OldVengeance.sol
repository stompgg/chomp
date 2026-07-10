// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {
    DEFAULT_ACCURACY,
    DEFAULT_CRIT_RATE,
    DEFAULT_PRIORITY,
    DEFAULT_VOL,
    EMPTY_ACTIVE_LANE,
    MOVE_INDEX_MASK,
    MOVE_INDEX_OFFSET,
    NO_SLOT,
    SWITCH_MOVE_INDEX
} from "../../Constants.sol";
import {MonStateIndexName, MoveClass, Type} from "../../Enums.sol";
import {MoveDecision, MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract OldVengeance is IMoveSet, BasicEffect {
    uint32 public constant BASE_POWER = 33;

    ITypeCalculator immutable TYPE_CALCULATOR;

    constructor(ITypeCalculator _TYPE_CALCULATOR) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Old Vengeance";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256,
        uint16,
        uint256 rng
    ) external {
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot == NO_SLOT) {
            return; // no chosen target (defensive; the engine fizzles first)
        }

        // Immediate hit.
        AttackCalculator._calculateDamage(
            engine,
            TYPE_CALCULATOR,
            battleKey,
            attackerPlayerIndex,
            attackerMonIndex,
            targetBits,
            BASE_POWER,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            moveType(engine, battleKey),
            moveClass(engine, battleKey),
            rng,
            DEFAULT_CRIT_RATE
        );

        // Arm the end-of-turn follow-up against the same slot.
        (bool exists, uint256 effectIndex,) =
            engine.getEffectData(battleKey, attackerPlayerIndex, attackerMonIndex, address(this));
        if (exists) {
            engine.editEffect(attackerPlayerIndex, effectIndex, bytes32(targetSlot));
        } else {
            engine.addEffect(attackerPlayerIndex, attackerMonIndex, this, bytes32(targetSlot));
        }
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 3;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY + 1;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Cosmic;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Special;
    }

    // Steps: RoundEnd (0x04), OnMonSwitchOut (0x20), ALWAYS_APPLIES (0x8000)
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8024;
    }

    // At end of turn, hit the target once more for each stamina the opponent spent this turn.
    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external override returns (bytes32, bool) {
        uint256 targetSlot = uint256(extraData) & 0xFF;
        uint256 defenderPlayerIndex = targetSlot >> 1;
        uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, targetSlot);
        if (defenderMonIndex == EMPTY_ACTIVE_LANE) {
            return (extraData, true);
        }

        uint256 extraHits = _opponentStaminaSpent(engine, battleKey, defenderPlayerIndex, defenderMonIndex, targetSlot);

        for (uint256 i; i < extraHits; i++) {
            AttackCalculator._calculateDamage(
                engine,
                TYPE_CALCULATOR,
                battleKey,
                targetIndex,
                monIndex,
                uint256(1) << targetSlot,
                BASE_POWER,
                DEFAULT_ACCURACY,
                DEFAULT_VOL,
                moveType(engine, battleKey),
                moveClass(engine, battleKey),
                // Fold the owner identity + hit index so same-side instances roll independently
                // and the stream can't collide with the engine's scheduler keccak domain.
                uint256(keccak256(abi.encode(rng, targetIndex, monIndex, i, "OLD_VENGEANCE"))),
                DEFAULT_CRIT_RATE
            );
            // Stop once the target is down.
            if (
                engine.getMonStateForBattle(
                        battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.IsKnockedOut
                    ) != 0
            ) {
                break;
            }
        }
        return (extraData, true);
    }

    // Stamina the opponent spent this turn = the cost of the move they locked in.
    function _opponentStaminaSpent(
        IEngine engine,
        bytes32 battleKey,
        uint256 defenderPlayerIndex,
        uint256 defenderMonIndex,
        uint256 targetSlot
    ) internal view returns (uint256) {
        MoveDecision memory decision = engine.getMoveDecisionForSlot(battleKey, defenderPlayerIndex, targetSlot & 1);
        uint8 storedMoveIndex = decision.packedMoveIndex & MOVE_INDEX_MASK;
        // Switch (125) / no-op (126) / unsubmitted (0) spend no stamina.
        if (storedMoveIndex == 0 || storedMoveIndex >= SWITCH_MOVE_INDEX) {
            return 0;
        }
        uint256 rawMoveSlot = engine.getMoveForMonForBattle(
            battleKey, defenderPlayerIndex, defenderMonIndex, storedMoveIndex - MOVE_INDEX_OFFSET
        );
        if (rawMoveSlot == 0) {
            return 0;
        }
        // Inline-packed StandardAttack: stamina lives in bits 236-239. Otherwise it's a move contract.
        if (rawMoveSlot >> 160 != 0) {
            return (rawMoveSlot >> 236) & 0xF;
        }
        return IMoveSet(address(uint160(rawMoveSlot))).stamina(engine, battleKey, defenderPlayerIndex, defenderMonIndex);
    }

    function onMonSwitchOut(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32, bool)
    {
        // Drop the pending follow-up if the caster leaves the field.
        return (extraData, true);
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: BASE_POWER
        });
    }
}
