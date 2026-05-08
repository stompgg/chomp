// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MonStateIndexName} from "../Enums.sol";
import {IEngine} from "../IEngine.sol";

library SwitchTargetLib {
    /// Returns a non-KO'd teammate index (other than `currentMonIndex`) chosen by walking the
    /// team from a random offset, or -1 if no such teammate exists.
    function findRandomNonKOed(
        IEngine engine,
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 currentMonIndex,
        uint256 rng
    ) internal view returns (int32) {
        uint256 teamSize = engine.getTeamSize(battleKey, playerIndex);
        for (uint256 i; i < teamSize; ++i) {
            uint256 candidate = (i + rng) % teamSize;
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
