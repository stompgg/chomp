// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Enums.sol";
import "../Structs.sol";

import {IEngine} from "../IEngine.sol";
import {RNGLib} from "../lib/RNGLib.sol";
import {ITypeCalculator} from "../types/ITypeCalculator.sol";

library AttackCalculator {
    uint32 constant RNG_SCALING_DENOM = 100;

    /// @notice Mix the attacker index into the rng to break symmetry on mirror matchups.
    function mixRngForAttacker(uint256 rng, uint256 attackerPlayerIndex) internal pure returns (uint256) {
        return RNGLib.mixForAttacker(rng, attackerPlayerIndex);
    }

    /// @notice Decide whether a move's post-hit effect should fire.
    /// Status moves (basePower == 0) have no accuracy check and always "land" — they are
    /// eligible to apply subject to effectAccuracy. Damaging moves must have dealt nonzero
    /// damage (didn't miss via accuracy and weren't type-immune).
    /// Folds the attacker index for mirror desymmetry; the tag keeps the roll independent of the
    /// accuracy/crit/volatility rolls drawn from keccak(rng, attackerPlayerIndex).
    function shouldApplyEffect(
        uint256 rng,
        uint256 attackerPlayerIndex,
        uint32 basePower,
        int32 damage,
        uint32 effectAccuracy
    ) internal pure returns (bool) {
        if (effectAccuracy == 0) return false;
        if (basePower > 0 && damage <= 0) return false;
        uint256 effectRng = uint256(keccak256(abi.encode(rng, attackerPlayerIndex, "EFFECT")));
        return effectRng % 100 < effectAccuracy;
    }

    /// @dev Delegates to the engine's one-call custom-attack path (context + TypeCalcLib + core
    ///      + damage application in a single frame). The TYPE_CALCULATOR / battleKey params are
    ///      kept so the ~10 mon call sites compile unchanged; type effectiveness now comes from
    ///      the engine-side TypeCalcLib — identical in production, where the deployed
    ///      TypeCalculator is a passthrough over the same lib (and almost always cold, ~2.6k+).
    function _calculateDamage(
        IEngine ENGINE,
        ITypeCalculator, /* TYPE_CALCULATOR — unused, see above */
        bytes32, /* battleKey — unused, the engine resolves its own transient context */
        uint256 attackerPlayerIndex,
        uint256 targetBits,
        uint32 basePower,
        uint32 accuracy, // out of 100
        uint256 volatility,
        Type attackType,
        MoveClass attackSupertype,
        uint256 rng,
        uint256 critRate // out of 100
    ) internal returns (int32, bytes32) {
        return ENGINE.dispatchCustomAttack(
            attackerPlayerIndex, targetBits, basePower, accuracy, volatility, attackType, attackSupertype, rng, critRate
        );
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
            TYPE_CALCULATOR, ctx, basePower, accuracy, volatility, attackType, attackSupertype, rng, critRate
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
        // Hash once: accuracy uses the low 64 bits, _calculateDamageCore the higher slices.
        uint256 h = uint256(keccak256(abi.encode(rng)));
        if ((uint64(h) % 100) >= accuracy) {
            return (0, MOVE_MISS_EVENT_TYPE);
        }

        // Type effectiveness via external ITypeCalculator (for test compat)
        uint32 scaledBasePower = TYPE_CALCULATOR.getTypeEffectiveness(attackType, ctx.defenderType1, basePower);
        if (ctx.defenderType2 != Type.None) {
            scaledBasePower = TYPE_CALCULATOR.getTypeEffectiveness(attackType, ctx.defenderType2, scaledBasePower);
        }

        return _calculateDamageCore(ctx, scaledBasePower, attackSupertype, volatility, h, critRate);
    }

    function _calculateDamageCore(
        DamageCalcContext memory ctx,
        uint32 scaledBasePower,
        MoveClass attackSupertype,
        uint256 volatility,
        uint256 h,
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

        // Volatility and crit read disjoint high slices of the hash; the caller's accuracy uses the low 64 bits.
        uint256 scalingRoll = uint64(h >> 64);
        uint32 rngScaling = 100;
        if (volatility > 0) {
            if (scalingRoll % 100 > 50) {
                rngScaling = 100 + uint32(scalingRoll % (volatility + 1));
            } else {
                rngScaling = 100 - uint32(scalingRoll % (volatility + 1));
            }
        }

        // Calculate crit chance
        uint256 critRoll = h >> 128;
        uint32 critNum = 1;
        uint32 critDenom = 1;
        bytes32 eventType = NONE_EVENT_TYPE;
        if ((critRoll % 100) <= critRate) {
            critNum = CRIT_NUM;
            critDenom = CRIT_DENOM;
            eventType = MOVE_CRIT_EVENT_TYPE;
        }
        // Compute in uint256 so heavily-boosted stats don't overflow the uint32 product, then
        // clamp to int32 max. With the StatBoosts apply-time clamp upstream, attackStat itself
        // is bounded by int32 max; this widening also covers any future tuning headroom.
        uint256 rawDamage = uint256(critNum) * scaledBasePower * attackStat * rngScaling
            / (uint256(defenceStat) * RNG_SCALING_DENOM * critDenom);
        int32 damage = rawDamage > uint256(uint32(type(int32).max)) ? type(int32).max : int32(uint32(rawDamage));
        // Handle the case where the type immunity results in 0 damage
        if (scaledBasePower == 0) {
            eventType = MOVE_TYPE_IMMUNITY_EVENT_TYPE;
        }
        return (damage, eventType);
    }
}
