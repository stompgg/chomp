// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";
import {StaminaRegenLogic} from "../lib/StaminaRegenLogic.sol";
import {TargetLib} from "../lib/TargetLib.sol";
import {BasicEffect} from "./BasicEffect.sol";

/// @dev Singles test scaffolding: prod uses the engine-inline regen (which is slot-aware);
///      this external effect only regens each side's slot-0 lane in 2-slot battles.
contract StaminaRegen is BasicEffect {
    function name() external pure override returns (string memory) {
        return "Stamina Regen";
    }

    // Steps: RoundEnd, AfterMove
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8084;
    }

    // Regen stamina on round end for both active mons (only on 2-player turns)
    function onRoundEnd(IEngine engine, bytes32 battleKey, uint256, bytes32, uint256, uint256, uint256 activesPacked)
        external
        override
        returns (bytes32, bool)
    {
        uint256 p0ActiveMonIndex = TargetLib.sideActive(activesPacked, 0);
        uint256 p1ActiveMonIndex = TargetLib.sideActive(activesPacked, 1);
        StaminaRegenLogic.onRoundEndExternal(engine, battleKey, p0ActiveMonIndex, p1ActiveMonIndex);
        return (bytes32(0), false);
    }

    // Regen stamina if the mon did a No Op (i.e. resting)
    function onAfterMove(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32,
        uint256 targetIndex,
        uint256 monIndex,
        uint256
    ) external override returns (bytes32, bool) {
        StaminaRegenLogic.onAfterMoveExternal(engine, battleKey, targetIndex, monIndex);
        return (bytes32(0), false);
    }
}
