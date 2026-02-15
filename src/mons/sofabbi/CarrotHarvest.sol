// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {MonStateIndexName} from "../../Enums.sol";
import {EffectInstance} from "../../Structs.sol";
import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";

import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";

contract CarrotHarvest is IAbility, BasicEffect {
    uint256 constant CHANCE = 2;

    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    // IAbility implementation
    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Carrot Harvest";
    }

    function activateOnSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external override {
        // Check if the effect has already been set for this mon
        (EffectInstance[] memory effects, ) = ENGINE.getEffects(battleKey, playerIndex, monIndex);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                return;
            }
        }
        ENGINE.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
    }

    // Steps: RoundEnd
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x04;
    }

    // Regain stamina on round end, this can overheal stamina
    function onRoundEnd(bytes32, uint256 rng, bytes32 extraData, uint256 targetIndex, uint256 monIndex, uint256, uint256)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        if (rng % CHANCE == 1) {
            // Update the stamina of the mon
            ENGINE.updateMonState(targetIndex, monIndex, MonStateIndexName.Stamina, 1);
        }
        return (extraData, false);
    }
}
