// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

/**
 * Mock move that removes an effect from a target mon.
 * The effect's slot index is passed as extraData. Targets the opponent's active mon.
 */
contract MockEffectRemover is IMoveSet {

    function name() public pure override returns (string memory) {
        return "Mock Effect Remover";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256,
        uint256 defenderMonIndex,
        uint16 extraData,
        uint256
    ) external {
        // extraData is the slot index of the effect to remove (from getEffects).
        uint256 slotIndex = uint256(extraData);

        // Target the opponent's active mon
        uint256 targetPlayerIndex = 1 - attackerPlayerIndex;

        // Verify the slot is still occupied at this index before removing
        (EffectInstance[] memory effects, uint256[] memory indices) =
            engine.getEffects(battleKey, targetPlayerIndex, defenderMonIndex);
        for (uint256 i = 0; i < indices.length; i++) {
            if (indices[i] == slotIndex) {
                if (address(effects[i].effect) != address(0)) {
                    engine.removeEffect(targetPlayerIndex, defenderMonIndex, slotIndex);
                }
                break;
            }
        }
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 0;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.None;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
    }

    function isValidTarget(IEngine, bytes32, uint16) external pure returns (bool) {
        return true;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            extraDataType: extraDataType(),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }

}
