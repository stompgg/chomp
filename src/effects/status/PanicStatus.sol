// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {EffectStep, MonStateIndexName} from "../../Enums.sol";
import {EffectContext} from "../../Structs.sol";
import {IEngine} from "../../IEngine.sol";

import {StatusEffect} from "./StatusEffect.sol";

contract PanicStatus is StatusEffect {
    uint256 constant DURATION = 3;

    constructor(IEngine engine) StatusEffect(engine) {}

    function name() public pure override returns (string memory) {
        return "Panic";
    }

    function shouldRunAtStep(EffectStep r) external pure override returns (bool) {
        // Need to also return OnRemove to remove the global status flag
        return
            r == EffectStep.RoundStart || r == EffectStep.RoundEnd || r == EffectStep.OnApply
                || r == EffectStep.OnRemove;
    }

    // At the start of the turn, check to see if we should apply stamina debuff or end early
    function onRoundStart(EffectContext calldata, uint256 rng, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        pure
        override
        returns (bytes32, bool)
    {
        // Set rng to be unique to the target index and mon index
        rng = uint256(keccak256(abi.encode(rng, targetIndex, monIndex)));
        bool wakeEarly = rng % 3 == 0;
        if (wakeEarly) {
            return (extraData, true);
        }
        return (extraData, false);
    }

    // On apply, checks to apply the flag, and then sets the extraData to be the duration
    function onApply(EffectContext calldata ctx, uint256 rng, bytes32 data, uint256 targetIndex, uint256 monIndex)
        public
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        super.onApply(ctx, rng, data, targetIndex, monIndex);
        return (bytes32(DURATION), false);
    }

    // Apply effect on end of turn, and then check how many turns are left
    function onRoundEnd(EffectContext calldata ctx, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32, bool removeAfterRun)
    {
        // Get current stamina delta of the target mon
        int32 staminaDelta = ENGINE.getMonStateForBattle(ctx.battleKey, targetIndex, monIndex, MonStateIndexName.Stamina);

        // If the stamina is less than the max stamina, then reduce stamina by 1 (as long as it's not already 0)
        uint32 maxStamina = ENGINE.getMonValueForBattle(ctx.battleKey, targetIndex, monIndex, MonStateIndexName.Stamina);
        if (staminaDelta + int32(maxStamina) > 0) {
            ENGINE.updateMonState(targetIndex, monIndex, MonStateIndexName.Stamina, -1);
        }

        uint256 turnsLeft = uint256(extraData);
        if (turnsLeft == 1) {
            return (extraData, true);
        } else {
            return (bytes32(turnsLeft - 1), false);
        }
    }
}
