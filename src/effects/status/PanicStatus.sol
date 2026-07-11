// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MonStateIndexName} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";

import {StatusEffect} from "./StatusEffect.sol";

contract PanicStatus is StatusEffect {
    uint256 constant DURATION = 3;

    function name() public pure override returns (string memory) {
        return "Panic";
    }

    // Steps: OnApply, RoundStart, RoundEnd, OnRemove
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x0F;
    }

    // At the start of the turn, check to see if we should apply stamina debuff or end early
    function onRoundStart(
        IEngine,
        bytes32,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256
    ) external pure override returns (bytes32, bool) {
        // Set rng to be unique to the target index and mon index
        rng = uint256(keccak256(abi.encode(rng, targetIndex, monIndex)));
        bool wakeEarly = rng % 3 == 0;
        if (wakeEarly) {
            return (extraData, true);
        }
        return (extraData, false);
    }

    // On apply, checks to apply the flag, and then sets the extraData to be the duration
    function onApply(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 data,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) public override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        super.onApply(engine, battleKey, rng, data, targetIndex, monIndex, activesPacked);
        return (bytes32(DURATION), false);
    }

    // Apply effect on end of turn, and then check how many turns are left
    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256
    ) external override returns (bytes32, bool removeAfterRun) {
        // Reduce stamina by 1 unless current stamina is already 0
        if (engine.getMonCurrentValue(battleKey, targetIndex, monIndex, MonStateIndexName.Stamina) > 0) {
            engine.updateMonState(targetIndex, monIndex, MonStateIndexName.Stamina, -1);
        }

        uint256 turnsLeft = uint256(extraData);
        if (turnsLeft == 1) {
            return (extraData, true);
        } else {
            return (bytes32(turnsLeft - 1), false);
        }
    }
}
