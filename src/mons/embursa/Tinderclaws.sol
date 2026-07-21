// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

// @inline-ability: singleton-local

import {
    MOVE_INDEX_MASK,
    NO_OP_MOVE_INDEX,
    NO_SLOT,
    STATUS_CLASS_MASK,
    STATUS_CLASS_SHIFT,
    SWITCH_MOVE_INDEX
} from "../../Constants.sol";
import {MonStateIndexName, StatBoostFlag, StatBoostType} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {EffectInstance, IEffect, StatBoostToApply} from "../../Structs.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";

contract Tinderclaws is IAbility, BasicEffect {
    uint256 constant BURN_CHANCE = 3; // 1 in 3 chance
    uint8 constant SP_ATTACK_BOOST_PERCENT = 50;

    IEffect immutable BURN_STATUS;
    uint256 immutable BURN_CLASS;

    constructor(IEffect _BURN_STATUS) {
        BURN_STATUS = _BURN_STATUS;
        BURN_CLASS = (uint256(_BURN_STATUS.getStepsBitmap()) >> STATUS_CLASS_SHIFT) & STATUS_CLASS_MASK;
    }

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Tinderclaws";
    }

    function activateOnSwitch(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        // Check if the effect has already been set for this mon
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, playerIndex, monIndex);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                return;
            }
        }
        engine.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
    }

    // Steps: RoundEnd, AfterMove
    function getStepsBitmap() external pure override returns (uint32) {
        // Low 16 bits: lifecycle steps. High 16 bits: requested fresh-context steps.
        return 0x00848084; // RoundEnd+AfterMove context | ALWAYS_APPLIES | AfterMove | RoundEnd
    }

    // extraData: 0 = no SpATK boost applied, 1 = SpATK boost applied
    function onAfterMove(
        IEngine engine,
        bytes32,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        uint256 ownSlot = TargetLib.slotOfMon(activesPacked, targetIndex, monIndex);
        if (ownSlot == NO_SLOT) {
            return (updatedExtraData, removeAfterRun);
        }
        // Engine embeds a fresh current-move lane immediately before every AfterMove callback.
        // Reading it here avoids a warm external round-trip while remaining correct when an
        // earlier effect rewrites the move during the same pass.
        uint8 moveIndex = uint8(TargetLib.hookMoveWordAt(activesPacked, ownSlot)) & MOVE_INDEX_MASK;

        // If resting, remove burn
        if (moveIndex == NO_OP_MOVE_INDEX) {
            engine.clearMonStatus(targetIndex, monIndex, BURN_CLASS);
        }
        // If used a move (not switch), 1/3 chance to self-burn
        else if (moveIndex != SWITCH_MOVE_INDEX) {
            // Make rng unique to this mon
            rng = uint256(keccak256(abi.encode(rng, targetIndex, monIndex, address(this))));
            if (rng % BURN_CHANCE == BURN_CHANCE - 1) {
                // Apply burn to self. No shouldApply pre-check: the engine's _addEffectInternal
                // runs the exact same check and silently no-ops on false — the external pre-check
                // was a duplicate ~1.4k round-trip on every proc.
                engine.addEffect(targetIndex, monIndex, BURN_STATUS, bytes32(0));
            }
        }

        return (extraData, false);
    }

    function onRoundEnd(
        IEngine engine,
        bytes32,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 hookContext
    ) external override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        bool isBurned = TargetLib.hookStatusClass(hookContext, targetIndex, monIndex) == BURN_CLASS;
        bool hasBoost = uint256(extraData) == 1;

        if (isBurned && !hasBoost) {
            // Add SpATK boost
            StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
            statBoosts[0] = StatBoostToApply({
                stat: MonStateIndexName.SpecialAttack,
                boostPercent: SP_ATTACK_BOOST_PERCENT,
                boostType: StatBoostType.Multiply
            });
            engine.addStatBoost(targetIndex, monIndex, statBoosts, StatBoostFlag.Perm);
            return (bytes32(uint256(1)), false);
        } else if (!isBurned && hasBoost) {
            // Remove SpATK boost
            engine.removeStatBoost(targetIndex, monIndex, StatBoostFlag.Perm);
            return (bytes32(0), false);
        }

        return (extraData, false);
    }
}
