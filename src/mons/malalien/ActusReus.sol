// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {EffectStep, MonStateIndexName, StatBoostType, StatBoostFlag} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {EffectInstance, StatBoostToApply} from "../../Structs.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {StatBoosts} from "../../effects/StatBoosts.sol";

contract ActusReus is IAbility, BasicEffect {

    uint8 public constant SPEED_DEBUFF_PERCENT = 50;
    bytes32 public constant INDICTMENT = bytes32("INDICTMENT");

    IEngine immutable ENGINE;
    StatBoosts immutable STAT_BOOSTS;

    constructor(IEngine _ENGINE, StatBoosts _STAT_BOOSTS) {
        ENGINE = _ENGINE;
        STAT_BOOSTS = _STAT_BOOSTS;
    }

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Actus Reus";
    }

    function activateOnSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        // Check if the effect has already been set for this mon
        (EffectInstance[] memory effects, ) = ENGINE.getEffects(battleKey, playerIndex, monIndex);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                return;
            }
        }
        ENGINE.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
    }

    function getStepsBitmap() external pure override returns (uint16) {
        return 0xC0;
    }

    function getStepsToRun() external pure override returns (EffectStep[] memory) {
        EffectStep[] memory steps = new EffectStep[](2);
        steps[0] = EffectStep.AfterMove;
        steps[1] = EffectStep.AfterDamage;
        return steps;
    }

    function shouldRunAtStep(EffectStep step) external pure override returns (bool) {
        return (step == EffectStep.AfterMove || step == EffectStep.AfterDamage);
    }

    function onAfterMove(uint256, bytes32 extraData, uint256 targetIndex, uint256)
        external
        override
        view
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        // Check if opposing mon is KOed
        uint256 otherPlayerIndex = (targetIndex + 1) % 2;
        uint256 otherPlayerActiveMonIndex =
            ENGINE.getActiveMonIndexForBattleState(ENGINE.battleKeyForWrite())[otherPlayerIndex];
        bool isOtherMonKOed =
            ENGINE.getMonStateForBattle(
                ENGINE.battleKeyForWrite(), otherPlayerIndex, otherPlayerActiveMonIndex, MonStateIndexName.IsKnockedOut
            ) == 1;
        if (isOtherMonKOed) {
            return (bytes32(uint256(1)), false);
        }
        return (extraData, false);
    }

    function onAfterDamage(uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, int32)
        external
        override
        returns (bytes32, bool)
    {
        // Check if we have an indictment
        if (uint256(extraData) == 1) {
            // If we are KO'ed, set a speed delta of half of the opposing mon's base speed
            bool isKOed =
                ENGINE.getMonStateForBattle(
                    ENGINE.battleKeyForWrite(), targetIndex, monIndex, MonStateIndexName.IsKnockedOut
                ) == 1;
            if (isKOed) {
                uint256 otherPlayerIndex = (targetIndex + 1) % 2;
                uint256 otherPlayerActiveMonIndex =
                    ENGINE.getActiveMonIndexForBattleState(ENGINE.battleKeyForWrite())[otherPlayerIndex];
                StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
                statBoosts[0] = StatBoostToApply({
                    stat: MonStateIndexName.Speed,
                    boostPercent: SPEED_DEBUFF_PERCENT,
                    boostType: StatBoostType.Divide
                });
                STAT_BOOSTS.addStatBoosts(otherPlayerIndex, otherPlayerActiveMonIndex, statBoosts, StatBoostFlag.Temp);
                return (bytes32(0), false);
            }
        }
        return (extraData, false);
    }
}
