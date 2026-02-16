// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";
import "../../src/IEngine.sol";
import "../../src/moves/IMoveSet.sol";
import "../../src/effects/IEffect.sol";

/**
 * @dev An attack that applies an effect to the target mon
 * Used for testing that effects are applied and run on the correct mon
 */
contract EffectApplyingAttack is IMoveSet {
    IEngine immutable ENGINE;
    IEffect public immutable EFFECT;

    struct Args {
        uint32 STAMINA_COST;
        uint32 PRIORITY;
    }

    Args public args;

    constructor(IEngine _ENGINE, IEffect _effect, Args memory _args) {
        ENGINE = _ENGINE;
        EFFECT = _effect;
        args = _args;
    }

    function name() external pure override returns (string memory) {
        return "EffectApplyingAttack";
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240 extraData, uint256) external override {
        // extraData contains the target slot index
        uint256 targetPlayerIndex = (attackerPlayerIndex + 1) % 2;
        uint256 targetSlotIndex = uint256(extraData);
        uint256 targetMonIndex = ENGINE.getActiveMonIndexForSlot(battleKey, targetPlayerIndex, targetSlotIndex);

        // Apply the effect to the target mon
        ENGINE.addEffect(targetPlayerIndex, targetMonIndex, EFFECT, bytes32(0));
    }

    function stamina(bytes32, uint256, uint256) external view override returns (uint32) {
        return args.STAMINA_COST;
    }

    function priority(bytes32, uint256) external view override returns (uint32) {
        return args.PRIORITY;
    }

    function moveType(bytes32) external pure override returns (Type) {
        return Type.Fire;
    }

    function moveClass(bytes32) external pure override returns (MoveClass) {
        return MoveClass.Other;
    }

    function extraDataType() external pure override returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    function isValidTarget(bytes32, uint240) external pure override returns (bool) {
        return true;
    }
}
