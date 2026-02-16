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

    // Which step this effect should run at
    EffectStep public stepToRunAt;

    constructor(IEngine _ENGINE, EffectStep _step) {
        ENGINE = _ENGINE;
        stepToRunAt = _step;
    }

    function name() external pure override returns (string memory) {
        return "MonIndexTracker";
    }

    function shouldRunAtStep(EffectStep r) external view override returns (bool) {
        return r == stepToRunAt;
    }

    // OnMonSwitchIn - track which mon switched in
    function onMonSwitchIn(uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
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
    function onMonSwitchOut(uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
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
    function onAfterDamage(uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, int32)
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
