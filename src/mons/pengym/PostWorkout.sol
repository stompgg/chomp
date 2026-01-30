// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {EffectStep, MonStateIndexName} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {EffectContext, EffectInstance} from "../../Structs.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";

import {StatusEffectLib} from "../../effects/status/StatusEffectLib.sol";

contract PostWorkout is IAbility, BasicEffect {
    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Post-Workout";
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

    function shouldRunAtStep(EffectStep step) external pure override returns (bool) {
        return (step == EffectStep.OnMonSwitchOut);
    }

    function onMonSwitchOut(EffectContext calldata ctx, uint256, bytes32, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        bytes32 battleKey = ctx.battleKey;
        bytes32 keyForMon = StatusEffectLib.getKeyForMonIndex(targetIndex, monIndex);
        uint192 statusAddress = ENGINE.getGlobalKV(battleKey, keyForMon);

        // Check if a status exists
        if (statusAddress != 0) {
            IEffect statusEffect = IEffect(address(uint160(statusAddress)));

            // Get the index of the effect and remove it
            uint256 effectIndex;
            (EffectInstance[] memory effects, uint256[] memory indices) = ENGINE.getEffects(battleKey, targetIndex, monIndex);
            for (uint256 i; i < effects.length; i++) {
                if (effects[i].effect == statusEffect) {
                    effectIndex = indices[i];
                    break;
                }
            }
            ENGINE.removeEffect(targetIndex, monIndex, effectIndex);

            // Boost stamina by 1
            ENGINE.updateMonState(targetIndex, monIndex, MonStateIndexName.Stamina, 1);
        }
        return (bytes32(0), false);
    }
}
