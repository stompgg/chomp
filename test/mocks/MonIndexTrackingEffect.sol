// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

/**
 * @dev A test effect that tracks which mon index it was run on.
 * Used to verify effects run on the correct mon in doubles.
 */
contract MonIndexTrackingEffect is BasicEffect {
    IEngine immutable ENGINE;

    // Track the last mon index the effect was run on for each player
    mapping(bytes32 => mapping(uint256 => uint256)) public lastMonIndexForPlayer;
    // Track how many times the effect was run
    mapping(bytes32 => uint256) public runCount;

    // Bitmap of which steps this effect should run at
    uint16 public stepsBitmap;

    // Bitmap constants matching IEffect
    uint16 constant ON_MON_SWITCH_IN = 0x10;
    uint16 constant ON_MON_SWITCH_OUT = 0x20;
    uint16 constant AFTER_DAMAGE = 0x40;

    constructor(IEngine _ENGINE, EffectStep _step) {
        ENGINE = _ENGINE;
        // Convert EffectStep to bitmap
        if (_step == EffectStep.OnMonSwitchIn) {
            stepsBitmap = ON_MON_SWITCH_IN;
        } else if (_step == EffectStep.OnMonSwitchOut) {
            stepsBitmap = ON_MON_SWITCH_OUT;
        } else if (_step == EffectStep.AfterDamage) {
            stepsBitmap = AFTER_DAMAGE;
        }
    }

    function name() external pure override returns (string memory) {
        return "MonIndexTracker";
    }

    function getStepsBitmap() external pure override returns (uint16) {
        // Return all steps we might want (will be filtered by the bitmap in the constructor)
        // Actually we need to return the stored value, but pure won't allow storage reads.
        // Use a different approach - return all the steps we implement
        return ON_MON_SWITCH_IN | ON_MON_SWITCH_OUT | AFTER_DAMAGE;
    }

    // OnMonSwitchIn - track which mon switched in
    function onMonSwitchIn(bytes32, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, uint256, uint256)
        external
        override
        returns (bytes32, bool)
    {
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        lastMonIndexForPlayer[battleKey][targetIndex] = monIndex;
        runCount[battleKey]++;
        return (extraData, false);
    }

    // OnMonSwitchOut - track which mon switched out
    function onMonSwitchOut(bytes32, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, uint256, uint256)
        external
        override
        returns (bytes32, bool)
    {
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        lastMonIndexForPlayer[battleKey][targetIndex] = monIndex;
        runCount[battleKey]++;
        return (extraData, false);
    }

    // AfterDamage - track which mon took damage
    function onAfterDamage(bytes32, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, uint256, uint256, int32)
        external
        override
        returns (bytes32, bool)
    {
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        lastMonIndexForPlayer[battleKey][targetIndex] = monIndex;
        runCount[battleKey]++;
        return (extraData, false);
    }

    // Helper to get last mon index
    function getLastMonIndex(bytes32 battleKey, uint256 playerIndex) external view returns (uint256) {
        return lastMonIndexForPlayer[battleKey][playerIndex];
    }

    // Helper to get run count
    function getRunCount(bytes32 battleKey) external view returns (uint256) {
        return runCount[battleKey];
    }
}
