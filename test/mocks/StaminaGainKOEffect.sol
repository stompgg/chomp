// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

/// @notice On any positive stamina gain, deals lethal damage to the mon that gained it. A generic,
/// mon-agnostic stand-in for effects whose OnUpdateMonState hook reaches dealDamage and can therefore
/// KO a mon off an inline stamina-regen tick.
contract StaminaGainKOEffect is BasicEffect {
    function name() external pure override returns (string memory) {
        return "Stamina Gain KO";
    }

    // Steps: OnUpdateMonState
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x100;
    }

    function onUpdateMonState(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 playerIndex,
        uint256 monIndex,
        uint256,
        MonStateIndexName stateVarIndex,
        int32 valueToAdd
    ) external override returns (bytes32, bool) {
        if (stateVarIndex == MonStateIndexName.Stamina && valueToAdd > 0) {
            uint32 maxHp = engine.getMonValueForBattle(battleKey, playerIndex, monIndex, MonStateIndexName.Hp);
            engine.dealDamage(playerIndex, monIndex, int32(uint32(maxHp)));
        }
        return (extraData, false);
    }
}
