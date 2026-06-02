// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

contract TempStatBoostEffect is BasicEffect {

    function name() external pure override returns (string memory) {
        return "";
    }

    // Steps: OnApply
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x01;
    }

    // Applies a TEMPORARY +100% Attack multiply (base 1 -> 2, i.e. delta +1). The engine drops temp
    // stat boosts natively on switch-out, so this no longer needs its own OnMonSwitchOut hook.
    function onApply(IEngine engine, bytes32, uint256, bytes32, uint256 targetIndex, uint256 monIndex, uint256, uint256)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        StatBoostToApply[] memory boosts = new StatBoostToApply[](1);
        boosts[0] = StatBoostToApply({stat: MonStateIndexName.Attack, boostPercent: 100, boostType: StatBoostType.Multiply});
        engine.addStatBoost(targetIndex, monIndex, boosts, StatBoostFlag.Temp);
        return (bytes32(0), false);
    }
}
