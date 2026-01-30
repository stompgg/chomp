// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {EffectStep} from "../../Enums.sol";

import {MonStateIndexName} from "../../Enums.sol";
import {EffectContext, EffectInstance} from "../../Structs.sol";
import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";

import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";

contract Angery is IAbility, BasicEffect {
    uint256 public constant CHARGE_COUNT = 3; // After 3 charges, consume all charges to heal
    int32 public constant MAX_HP_DENOM = 6; // Heal for 1/6 of HP

    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    // IAbility implementation
    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Angery";
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

    // IEffect implementation
    function shouldRunAtStep(EffectStep step) external pure override returns (bool) {
        return (step == EffectStep.RoundEnd || step == EffectStep.AfterDamage);
    }

    function onRoundEnd(EffectContext calldata ctx, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        uint256 numCharges = uint256(extraData);
        if (numCharges == CHARGE_COUNT) {
            // Heal
            int32 healAmount =
                int32(
                    ENGINE.getMonValueForBattle(ctx.battleKey, targetIndex, monIndex, MonStateIndexName.Hp)
                ) / MAX_HP_DENOM;
            ENGINE.updateMonState(targetIndex, monIndex, MonStateIndexName.Hp, healAmount);
            // Reset the charges
            return (bytes32(numCharges - CHARGE_COUNT), false);
        } else {
            return (extraData, false);
        }
    }

    function onAfterDamage(EffectContext calldata, uint256, bytes32 extraData, uint256, uint256, int32)
        external
        pure
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        uint256 numCharges = uint256(extraData);
        return (bytes32(numCharges + 1), false);
    }
}
