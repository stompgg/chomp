// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

// @inline-ability: singleton-local

import {NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, MOVE_INDEX_MASK} from "../../Constants.sol";
import {MonStateIndexName, StatBoostFlag, StatBoostType} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {EffectInstance, IEffect, MoveDecision, StatBoostToApply} from "../../Structs.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {StatBoosts} from "../../effects/StatBoosts.sol";
import {StatusEffectLib} from "../../effects/status/StatusEffectLib.sol";

contract Tinderclaws is IAbility, BasicEffect {
    uint256 constant BURN_CHANCE = 3; // 1 in 3 chance
    uint8 constant SP_ATTACK_BOOST_PERCENT = 50;

    IEffect immutable BURN_STATUS;
    StatBoosts immutable STAT_BOOSTS;

    constructor(IEffect _BURN_STATUS, StatBoosts _STAT_BOOSTS) {
        BURN_STATUS = _BURN_STATUS;
        STAT_BOOSTS = _STAT_BOOSTS;
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
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8084;
    }

    // extraData: 0 = no SpATK boost applied, 1 = SpATK boost applied
    function onAfterMove(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256,
        uint256
    ) external override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        MoveDecision memory moveDecision = engine.getMoveDecisionForBattleState(battleKey, targetIndex);
        // Unpack the move index from packedMoveIndex
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;

        // If resting, remove burn
        if (moveIndex == NO_OP_MOVE_INDEX) {
            _removeBurnIfPresent(engine, battleKey, targetIndex, monIndex);
        }
        // If used a move (not switch), 1/3 chance to self-burn
        else if (moveIndex != SWITCH_MOVE_INDEX) {
            // Make rng unique to this mon
            rng = uint256(keccak256(abi.encode(rng, targetIndex, monIndex, address(this))));
            if (rng % BURN_CHANCE == BURN_CHANCE - 1) {
                // Apply burn to self (if it can be applied)
                if (BURN_STATUS.shouldApply(engine, battleKey, bytes32(0), targetIndex, monIndex)) {
                    engine.addEffect(targetIndex, monIndex, BURN_STATUS, bytes32(0));
                }
            }
        }

        return (extraData, false);
    }

    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256,
        uint256
    ) external override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        bool isBurned = _isBurned(engine, battleKey, targetIndex, monIndex);
        bool hasBoost = uint256(extraData) == 1;

        if (isBurned && !hasBoost) {
            // Add SpATK boost
            StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
            statBoosts[0] = StatBoostToApply({
                stat: MonStateIndexName.SpecialAttack,
                boostPercent: SP_ATTACK_BOOST_PERCENT,
                boostType: StatBoostType.Multiply
            });
            STAT_BOOSTS.addStatBoosts(engine, targetIndex, monIndex, statBoosts, StatBoostFlag.Perm);
            return (bytes32(uint256(1)), false);
        } else if (!isBurned && hasBoost) {
            // Remove SpATK boost
            STAT_BOOSTS.removeStatBoosts(engine, targetIndex, monIndex, StatBoostFlag.Perm);
            return (bytes32(0), false);
        }

        return (extraData, false);
    }

    function _isBurned(IEngine engine, bytes32 battleKey, uint256 targetIndex, uint256 monIndex)
        internal
        view
        returns (bool)
    {
        bytes32 keyForMon = StatusEffectLib.getKeyForMonIndex(targetIndex, monIndex);
        uint192 monStatusFlag = engine.getGlobalKV(battleKey, keyForMon);
        return monStatusFlag == uint192(uint160(address(BURN_STATUS)));
    }

    function _removeBurnIfPresent(IEngine engine, bytes32 battleKey, uint256 targetIndex, uint256 monIndex) internal {
        (EffectInstance[] memory effects, uint256[] memory indices) =
            engine.getEffects(battleKey, targetIndex, monIndex);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(BURN_STATUS)) {
                engine.removeEffect(targetIndex, monIndex, indices[i]);
                return;
            }
        }
    }
}
