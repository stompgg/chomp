// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

/**
 * Mock move that removes an effect from a target mon.
 * The effect address to remove is passed as extraData (targetArgs).
 * Targets the opponent's active mon.
 */
contract MockEffectRemover is IMoveSet {
    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() public pure override returns (string memory) {
        return "Mock Effect Remover";
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240 extraData, uint256) external {
        // extraData contains the address of the effect to remove (packed as uint160)
        address effectToRemove = address(uint160(extraData));

        // Target the opponent's active mon
        uint256 targetPlayerIndex = 1 - attackerPlayerIndex;
        uint256 targetMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[targetPlayerIndex];

        // Find and remove the effect
        (EffectInstance[] memory effects, uint256[] memory indices) = ENGINE.getEffects(battleKey, targetPlayerIndex, targetMonIndex);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == effectToRemove) {
                // Call onRemove on the effect before removing
                effects[i].effect.onRemove(battleKey, effects[i].data, targetPlayerIndex, targetMonIndex);
                ENGINE.removeEffect(targetPlayerIndex, targetMonIndex, indices[i]);
                break;
            }
        }
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 0;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.None;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

