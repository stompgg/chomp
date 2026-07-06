// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

// @inline-ability: singleton-local

import {EMPTY_ACTIVE_LANE} from "../../Constants.sol";
import {MonStateIndexName, StatBoostFlag, StatBoostType} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {EffectInstance, StatBoostToApply} from "../../Structs.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";

contract ActusReus is IAbility, BasicEffect {
    uint8 public constant SPEED_DEBUFF_PERCENT = 50;
    bytes32 public constant INDICTMENT = bytes32("INDICTMENT");

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Actus Reus";
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

    // Steps: AfterDamage, AfterMove
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x80C0;
    }

    function onAfterMove(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256,
        uint256 activesPacked
    ) external view override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        // Arm if EITHER opposing occupant fell after Malalien's move (kit-audit ruling: the
        // singles check was "the opposing active"; with two opposing slots we arm on any).
        uint256 otherPlayerIndex = (targetIndex + 1) % 2;
        uint256 oppSlot0 = otherPlayerIndex << 1;
        uint256 otherPlayerActiveMonIndex = TargetLib.activeAt(activesPacked, oppSlot0);
        uint256 oppPartnerMon = TargetLib.activeAt(activesPacked, oppSlot0 | 1);
        if (oppPartnerMon != EMPTY_ACTIVE_LANE) {
            bool partnerKOed = engine.getMonStateForBattle(
                battleKey, otherPlayerIndex, oppPartnerMon, MonStateIndexName.IsKnockedOut
            ) == 1;
            if (partnerKOed) {
                return (bytes32(uint256(1)), false);
            }
        }
        bool isOtherMonKOed = engine.getMonStateForBattle(
            battleKey, otherPlayerIndex, otherPlayerActiveMonIndex, MonStateIndexName.IsKnockedOut
        ) == 1;
        if (isOtherMonKOed) {
            return (bytes32(uint256(1)), false);
        }
        return (extraData, false);
    }

    function onAfterDamage(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked,
        int32,
        uint256
    ) external override returns (bytes32, bool) {
        // Mirror-slot ruling: the speed halving lands opposite Malalien's slot (its lane still
        // holds it at the KO instant).
        uint256 ownSlot = TargetLib.slotOfMon(activesPacked, targetIndex, monIndex);
        uint256 oppSlot = ownSlot == 4 ? 4 : TargetLib.mirrorOpposingSlot(activesPacked, ownSlot);
        // Check if we have an indictment
        if (uint256(extraData) == 1) {
            // If we are KO'ed, set a speed delta of half of the opposing mon's base speed
            bool isKOed =
                engine.getMonStateForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.IsKnockedOut) == 1;
            if (isKOed && oppSlot != 4) {
                uint256 otherPlayerIndex = oppSlot >> 1;
                uint256 otherPlayerActiveMonIndex = TargetLib.activeAt(activesPacked, oppSlot);
                StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
                statBoosts[0] = StatBoostToApply({
                    stat: MonStateIndexName.Speed, boostPercent: SPEED_DEBUFF_PERCENT, boostType: StatBoostType.Divide
                });
                engine.addStatBoost(otherPlayerIndex, otherPlayerActiveMonIndex, statBoosts, StatBoostFlag.Temp);
                return (bytes32(0), false);
            }
        }
        return (extraData, false);
    }
}
