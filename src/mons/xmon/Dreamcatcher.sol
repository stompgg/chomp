// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Enums.sol";
import {MonStateIndexName, EffectInstance} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";

contract Dreamcatcher is IAbility, BasicEffect {
    int32 public constant HEAL_DENOM = 16;

    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Dreamcatcher";
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

    // Steps: OnUpdateMonState
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x100;
    }

    function onUpdateMonState(
        uint256,
        bytes32 extraData,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex,
        int32 valueToAdd
    ) external override returns (bytes32, bool) {
        // Only trigger if Stamina is being increased (positive valueToAdd)
        if (stateVarIndex == MonStateIndexName.Stamina && valueToAdd > 0) {
            bytes32 battleKey = ENGINE.battleKeyForWrite();
            uint32 maxHp = ENGINE.getMonValueForBattle(battleKey, playerIndex, monIndex, MonStateIndexName.Hp);
            int32 healAmount = int32(uint32(maxHp)) / HEAL_DENOM;

            // Prevent overhealing
            int32 existingHpDelta = ENGINE.getMonStateForBattle(battleKey, playerIndex, monIndex, MonStateIndexName.Hp);
            if (existingHpDelta + healAmount > 0) {
                healAmount = 0 - existingHpDelta;
            }

            if (healAmount > 0) {
                ENGINE.updateMonState(playerIndex, monIndex, MonStateIndexName.Hp, healAmount);
            }
        }
        return (extraData, false);
    }
}

