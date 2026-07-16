// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../../IEngine.sol";

/// @dev Implemented only by statuses that set HAS_REAPPLY_BIT in their steps bitmap: the Engine
///      calls onReapply when the status is applied to a mon already carrying the same class
///      (e.g. Burn's degree escalation). `existingData` is the live entry's extraData; the
///      return either rewrites it in place or removes the entry. Statuses with the bit clear
///      never receive this call — a same-class re-apply is a zero-call no-op.
///      RULE (validator-enforced): a status's onApply must not apply another status to the same
///      mon — the lane is written once per stored entry, so a nested same-mon apply would alias.
interface IStatusEffect {
    function onReapply(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 existingData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external returns (bytes32 newData, bool removeAfterRun);
}
