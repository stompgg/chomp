// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

// @inline-ability: singleton-local

import {MonStateIndexName} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";

import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";

contract CarrotHarvest is IAbility, BasicEffect {
    uint256 constant CHANCE = 2;

    // IAbility implementation
    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Carrot Harvest";
    }

    function activateOnSwitch(IEngine engine, bytes32, uint256 playerIndex, uint256 monIndex)
        external
        override
    {
        engine.addEffectIfNotPresent(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
    }

    // Steps: RoundEnd
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8004;
    }

    // Regain stamina on round end, this can overheal stamina
    function onRoundEnd(IEngine engine, bytes32, uint256 rng, bytes32 extraData, uint256 targetIndex, uint256 monIndex, uint256, uint256)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        if (rng % CHANCE == 1) {
            // Update the stamina of the mon
            engine.updateMonState(targetIndex, monIndex, MonStateIndexName.Stamina, 1);
        }
        return (extraData, false);
    }
}
