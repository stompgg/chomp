// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Enums.sol";
import "../Structs.sol";

import {IEngine} from "../IEngine.sol";
import {ITypeCalculator} from "../types/ITypeCalculator.sol";

library AttackCalculator {
    uint32 constant RNG_SCALING_DENOM = 100;

    /// @notice Mix the raw rng with the attacker index so mirror mons using the same move
    /// against each other don't roll identical accuracy/damage/crit values. Deterministic —
    /// keyed only by (rng, attackerPlayerIndex) — so the oracle's rng is still the only source.
    function mixRngForAttacker(uint256 rng, uint256 attackerPlayerIndex) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(rng, attackerPlayerIndex)));
    }

    /// @notice Decide whether a move's post-hit effect should fire.
    /// Status moves (basePower == 0) have no accuracy check and always "land" — they are
    /// eligible to apply subject to effectAccuracy. Damaging moves must have dealt nonzero
    /// damage (didn't miss via accuracy and weren't type-immune).
    /// The rng is rerolled with an independent keccak so the effect trigger is uncorrelated
    /// with the accuracy/crit/volatility rolls that already consumed the damage-path rng.
    function shouldApplyEffect(uint256 rng, uint32 basePower, int32 damage, uint32 effectAccuracy)
        internal
        pure
        returns (bool)
    {
        if (effectAccuracy == 0) return false;
        if (basePower > 0 && damage <= 0) return false;
        uint256 effectRng = uint256(keccak256(abi.encode(rng)));
        return effectRng % 100 < effectAccuracy;
    }

    function _calculateDamage(
        IEngine ENGINE,
        ITypeCalculator TYPE_CALCULATOR,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint32 basePower,
        uint32 accuracy, // out of 100
        uint256 volatility,
        Type attackType,
        MoveClass attackSupertype,
        uint256 rng,
        uint256 critRate // out of 100
    ) internal returns (int32, bytes32) {
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        // Use batch getter to reduce external calls (7 -> 1)
        DamageCalcContext memory ctx = ENGINE.getDamageCalcContext(battleKey, attackerPlayerIndex, defenderPlayerIndex);
        (int32 damage, bytes32 eventType) = _calculateDamageFromContext(
            TYPE_CALCULATOR,
            ctx,
            basePower,
            accuracy,
            volatility,
            attackType,
            attackSupertype,
            rng,
            critRate
        );
        if (damage != 0) {
            ENGINE.dealDamage(defenderPlayerIndex, ctx.defenderMonIndex, damage);
        }
        return (damage, eventType);
    }

    function _calculateDamageView(
        IEngine ENGINE,
        ITypeCalculator TYPE_CALCULATOR,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 defenderPlayerIndex,
        uint32 basePower,
        uint32 accuracy, // out of 100
        uint256 volatility,
        Type attackType,
        MoveClass attackSupertype,
        uint256 rng,
        uint256 critRate // out of 100
    ) internal view returns (int32, bytes32) {
        // Use batch getter to reduce external calls (7 -> 1)
        DamageCalcContext memory ctx = ENGINE.getDamageCalcContext(battleKey, attackerPlayerIndex, defenderPlayerIndex);
        return _calculateDamageFromContext(
            TYPE_CALCULATOR,
            ctx,
            basePower,
            accuracy,
            volatility,
            attackType,
            attackSupertype,
            rng,
            critRate
        );
    }

    function _calculateDamageFromContext(
        ITypeCalculator TYPE_CALCULATOR,
        DamageCalcContext memory ctx,
        uint32 basePower,
        uint32 accuracy, // out of 100
        uint256 volatility,
        Type attackType,
        MoveClass attackSupertype,
        uint256 rng,
        uint256 critRate // out of 100
    ) internal view returns (int32, bytes32) {
        // Do accuracy check first to decide whether or not to short circuit
        // [0... accuracy] [accuracy + 1, ..., 100]
        // [succeeds     ] [fails                 ]
        if ((rng % 100) >= accuracy) {
            return (0, MOVE_MISS_EVENT_TYPE);
        }

        // Type effectiveness via external ITypeCalculator (for test compat)
        uint32 scaledBasePower = TYPE_CALCULATOR.getTypeEffectiveness(attackType, ctx.defenderType1, basePower);
        if (ctx.defenderType2 != Type.None) {
            scaledBasePower = TYPE_CALCULATOR.getTypeEffectiveness(attackType, ctx.defenderType2, scaledBasePower);
        }

        return _calculateDamageCore(ctx, scaledBasePower, attackSupertype, volatility, rng, critRate);
    }

    function _calculateDamageCore(
        DamageCalcContext memory ctx,
        uint32 scaledBasePower,
        MoveClass attackSupertype,
        uint256 volatility,
        uint256 rng,
        uint256 critRate
    ) internal pure returns (int32, bytes32) {
        uint32 attackStat;
        uint32 defenceStat;

        // Grab the right atk/defense stats from pre-fetched context
        if (attackSupertype == MoveClass.Physical) {
            attackStat = uint32(int32(ctx.attackerAttack) + ctx.attackerAttackDelta);
            defenceStat = uint32(int32(ctx.defenderDef) + ctx.defenderDefDelta);
        } else {
            attackStat = uint32(int32(ctx.attackerSpAtk) + ctx.attackerSpAtkDelta);
            defenceStat = uint32(int32(ctx.defenderSpDef) + ctx.defenderSpDefDelta);
        }

        // Prevent weird stat bugs from messing up the math
        if (attackStat <= 0) {
            attackStat = 1;
        }
        if (defenceStat <= 0) {
            defenceStat = 1;
        }

        // Calculate move volatility
        uint256 rng2 = uint256(keccak256(abi.encode(rng)));
        uint32 rngScaling = 100;
        if (volatility > 0) {
            if (rng2 % 100 > 50) {
                rngScaling = 100 + uint32(rng2 % (volatility + 1));
            } else {
                rngScaling = 100 - uint32(rng2 % (volatility + 1));
            }
        }

        // Calculate crit chance
        uint256 rng3 = uint256(keccak256(abi.encode(rng2)));
        uint32 critNum = 1;
        uint32 critDenom = 1;
        bytes32 eventType = NONE_EVENT_TYPE;
        if ((rng3 % 100) <= critRate) {
            critNum = CRIT_NUM;
            critDenom = CRIT_DENOM;
            eventType = MOVE_CRIT_EVENT_TYPE;
        }
        int32 damage = int32(
            critNum * (scaledBasePower * attackStat * rngScaling) / (defenceStat * RNG_SCALING_DENOM * critDenom)
        );
        // Handle the case where the type immunity results in 0 damage
        if (scaledBasePower == 0) {
            eventType = MOVE_TYPE_IMMUNITY_EVENT_TYPE;
        }
        return (damage, eventType);
    }
}
