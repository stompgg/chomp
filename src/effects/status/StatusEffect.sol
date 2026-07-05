// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../BasicEffect.sol";
import {StatusEffectLib} from "./StatusEffectLib.sol";

abstract contract StatusEffect is BasicEffect {
    // Whether or not to add the effect if the step condition is met
    function shouldApply(IEngine engine, bytes32 battleKey, bytes32, uint256 targetIndex, uint256 monIndex)
        public
        view
        virtual
        override
        returns (bool)
    {
        uint64 keyForMon = StatusEffectLib.getKeyForMonIndex(targetIndex, monIndex);

        // Get value from ENGINE KV
        uint192 monStatusFlag = engine.getGlobalKV(battleKey, keyForMon);

        // Check if a status already exists for the mon
        if (monStatusFlag == 0) {
            return true;
        } else {
            // Otherwise return false
            return false;
        }
    }

    /// @dev ENGINE-ONLY INVARIANT: the engine calls onApply immediately after a passing
    ///      shouldApply with nothing in between (_addEffectInternal), so the per-mon status flag
    ///      is guaranteed clear (or already ours, for statuses whose shouldApply allows that)
    ///      whenever this runs — the old guard re-read of the same key was a pure ~700-gas
    ///      round-trip. No non-engine caller exists (and a direct caller could already write the
    ///      flag via setGlobalKV, so this is not a trust boundary).
    function onApply(IEngine engine, bytes32, uint256, bytes32, uint256 targetIndex, uint256 monIndex, uint256)
        public
        virtual
        override
        returns (bytes32 extraData, bool removeAfterRun)
    {
        // Set the global status flag to be the address of the status (unconditional — see above)
        engine.setGlobalKV(StatusEffectLib.getKeyForMonIndex(targetIndex, monIndex), uint192(uint160(address(this))));
        return (extraData, removeAfterRun);
    }

    function onRemove(IEngine engine, bytes32, bytes32, uint256 targetIndex, uint256 monIndex, uint256)
        public
        virtual
        override
    {
        // On remove, reset the status flag
        engine.setGlobalKV(StatusEffectLib.getKeyForMonIndex(targetIndex, monIndex), 0);
    }
}
