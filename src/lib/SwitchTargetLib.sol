// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MonStateIndexName} from "../Enums.sol";
import {IEngine} from "../IEngine.sol";
import {RNGLib} from "./RNGLib.sol";

library SwitchTargetLib {
    /// Returns a non-KO'd replacement index (other than `currentMonIndex`) legal for the given
    /// slot, chosen by walking the slot's roster range from a random offset, or -1 if none exists.
    /// The range matters in Multi, where each slot may only switch within its seat's quarter.
    function findRandomNonKOed(
        IEngine engine,
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 slotIndex,
        uint256 currentMonIndex,
        uint256 rng
    ) internal view returns (int32) {
        // Mix in target player index to break symmetry on mirror matchups
        uint256 offset = RNGLib.mixForAttacker(rng, playerIndex);
        (uint256 lo, uint256 hi) = engine.getRosterBoundsForSlot(battleKey, playerIndex, slotIndex);
        uint256 span = hi - lo;
        for (uint256 i; i < span; ++i) {
            uint256 candidate = lo + ((i + offset) % span);
            if (candidate != currentMonIndex) {
                bool isKOed =
                    engine.getMonStateForBattle(battleKey, playerIndex, candidate, MonStateIndexName.IsKnockedOut) == 1;
                if (!isKOed) {
                    return int32(int256(candidate));
                }
            }
        }
        return -1;
    }
}
