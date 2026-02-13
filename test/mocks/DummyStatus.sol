// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

contract DummyStatus is BasicEffect {
    function name() external pure override returns (string memory) {
        return "Dummy";
    }

    // Steps: None
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x00;
    }
}
