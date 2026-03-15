// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

/// @notice Effect whose shouldApply() returns false, but has ALWAYS_APPLIES_BIT set.
/// Used to test that the Engine bypasses shouldApply() when the bit is set.
contract AlwaysRejectsEffect is BasicEffect {
    function name() external pure override returns (string memory) {
        return "AlwaysRejects";
    }

    // ALWAYS_APPLIES_BIT (0x8000) | RoundEnd (0x04)
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8004;
    }

    // This returns false, but ALWAYS_APPLIES_BIT should cause Engine to skip this check
    function shouldApply(IEngine, bytes32, bytes32, uint256, uint256) external pure override returns (bool) {
        return false;
    }

    function onRoundEnd(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }
}
