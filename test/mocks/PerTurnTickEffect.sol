// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

/// @notice Minimal per-mon effect that ticks every turn: RoundStart + RoundEnd + AfterDamage.
///         Each hook increments the counter in `data`. Used by BatchInstrumentationTest to
///         simulate the "effect-heavy turn" storage-access profile without dragging in the
///         full StatBoosts dependency graph.
contract PerTurnTickEffect is BasicEffect {

    function name() external pure override returns (string memory) {
        return "Tick";
    }

    // RoundStart (bit 1) | RoundEnd (bit 2) | AfterDamage (bit 6) | ALWAYS_APPLIES (bit 15)
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8046;
    }

    function onRoundStart(IEngine, bytes32, uint256, bytes32 data, uint256, uint256, uint256, uint256)
        external
        override
        returns (bytes32, bool)
    {
        return (bytes32(uint256(data) + 1), false);
    }

    function onRoundEnd(IEngine, bytes32, uint256, bytes32 data, uint256, uint256, uint256, uint256)
        external
        override
        returns (bytes32, bool)
    {
        return (bytes32(uint256(data) + 1), false);
    }

    function onAfterDamage(IEngine, bytes32, uint256, bytes32 data, uint256, uint256, uint256, uint256, int32, uint256)
        external
        override
        returns (bytes32, bool)
    {
        return (bytes32(uint256(data) + 1), false);
    }
}
