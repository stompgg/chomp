// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {EffectStep} from "../Enums.sol";

/// @notice Optional read-only effect hook that returns one Engine-validated mutation command.
interface IEffectResolver {
    function resolveEffect(
        EffectStep step,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 hookContext
    ) external view returns (bytes32 updatedExtraData, bool removeAfterRun, uint256 command);
}

