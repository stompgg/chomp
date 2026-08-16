// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {MoveMeta} from "../../Structs.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

/// @notice Arms a delayed strike at the chosen slot that fires the next time Mulong rests. The
///         rest itself is untouched, so it still regenerates stamina as normal.
contract GrandRespite is IMoveSet, BasicEffect {
    uint32 public constant BASE_POWER = 120;

    ITypeCalculator immutable TYPE_CALCULATOR;

    constructor(ITypeCalculator _TYPE_CALCULATOR) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256,
        uint16,
        uint256
    ) external {
        // Slot-bound like Q5: a later switch redirects the strike onto whoever holds the slot.
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot == NO_SLOT) {
            return;
        }
        (bool exists, uint256 effectIndex,) =
            engine.getEffectData(battleKey, attackerPlayerIndex, attackerMonIndex, address(this));
        if (exists) {
            engine.editEffect(attackerPlayerIndex, effectIndex, bytes32(targetSlot));
            return;
        }
        engine.addEffect(attackerPlayerIndex, attackerMonIndex, IEffect(address(this)), bytes32(targetSlot));
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 2;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Air;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Special;
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
            // The strike is deferred to the next rest, so this turn's damage is 0.
            basePower: 0
        });
    }

    // Steps: AfterMove, ALWAYS_APPLIES; fresh AfterMove context for rest detection.
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x00808080;
    }

    function onAfterMove(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 hookContext
    ) external override returns (bytes32, bool) {
        uint256 restSlot = TargetLib.slotOfMon(hookContext, targetIndex, monIndex);
        if (restSlot == NO_SLOT) {
            return (extraData, false);
        }
        if (uint8(TargetLib.hookMoveWordAt(hookContext, restSlot)) & MOVE_INDEX_MASK != NO_OP_MOVE_INDEX) {
            return (extraData, false);
        }

        AttackCalculator._calculateDamage(
            engine,
            TYPE_CALCULATOR,
            battleKey,
            targetIndex,
            monIndex,
            uint256(1) << uint256(extraData),
            BASE_POWER,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            Type.Air,
            MoveClass.Special,
            rng,
            DEFAULT_CRIT_RATE
        );
        return (extraData, true);
    }
}
