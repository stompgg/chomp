// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

contract OneTurnStatBoost is BasicEffect {
    function name() external pure override returns (string memory) {
        return "";
    }

    // Steps: OnApply, RoundEnd
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x05;
    }

    // Adds a bonus. Both hooks apply the same-keyed +100% Attack multiply, so they merge: one
    // application takes base 1 -> 2 (delta +1), the second -> 4 (delta +3). The test asserts +3,
    // distinguishing "both hooks ran" from "only onApply ran" (+1).
    function _boost() private pure returns (StatBoostToApply[] memory boosts) {
        boosts = new StatBoostToApply[](1);
        boosts[0] =
            StatBoostToApply({stat: MonStateIndexName.Attack, boostPercent: 100, boostType: StatBoostType.Multiply});
    }

    function onApply(IEngine engine, bytes32, uint256, bytes32, uint256 targetIndex, uint256 monIndex, uint256)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        engine.addStatBoost(targetIndex, monIndex, _boost(), StatBoostFlag.Perm);
        return (bytes32(0), false);
    }

    // Adds another bonus (merges with the onApply boost), then removes this effect.
    function onRoundEnd(IEngine engine, bytes32, uint256, bytes32, uint256 targetIndex, uint256 monIndex, uint256)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        engine.addStatBoost(targetIndex, monIndex, _boost(), StatBoostFlag.Perm);
        return (bytes32(0), true);
    }
}
