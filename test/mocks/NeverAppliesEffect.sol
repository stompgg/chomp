// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

/// @notice Effect whose shouldApply() returns false and does NOT have ALWAYS_APPLIES_BIT.
/// Used to verify that normal shouldApply() rejection still works.
contract NeverAppliesEffect is BasicEffect {
    function name() external pure override returns (string memory) {
        return "NeverApplies";
    }

    // RoundEnd (0x04), NO ALWAYS_APPLIES_BIT
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x04;
    }

    function shouldApply(IEngine, bytes32, bytes32, uint256, uint256) external pure override returns (bool) {
        return false;
    }
}
