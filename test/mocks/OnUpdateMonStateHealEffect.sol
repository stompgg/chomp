// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

/**
 * @title OnUpdateMonStateHealEffect
 * @notice Mock effect that heals a mon's HP when its SpecialAttack stat is reduced
 * @dev This demonstrates the OnUpdateMonState lifecycle hook
 */
contract OnUpdateMonStateHealEffect is BasicEffect {
    IEngine immutable ENGINE;
    int32 public constant HEAL_AMOUNT = 5;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function getStepsBitmap() external pure override returns (uint16) {
        return 0x100;
    }

    function getStepsToRun() external pure override returns (EffectStep[] memory) {
        EffectStep[] memory steps = new EffectStep[](1);
        steps[0] = EffectStep.OnUpdateMonState;
        return steps;
    }

    // WARNING: Avoid chaining this effect to prevent recursive calls
    // This effect is safe because it only heals HP, it doesn't trigger state updates that would recurse
    function onUpdateMonState(
        uint256,
        bytes32 extraData,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex,
        int32 valueToAdd
    ) external override returns (bytes32, bool) {
        // Only trigger if SpecialAttack is being reduced (negative valueToAdd)
        if (stateVarIndex == MonStateIndexName.SpecialAttack && valueToAdd < 0) {
            // Heal the mon by HEAL_AMOUNT
            ENGINE.updateMonState(playerIndex, monIndex, MonStateIndexName.Hp, HEAL_AMOUNT);
        }
        return (extraData, false);
    }
}
