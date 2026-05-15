// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/// @notice Owner-gated entry for granting per-mon exp to an arbitrary player. Each monId must
/// exist in the underlying mon registry. monIds may be in any order, but callers should group
/// them by bucket (monId / 16) so the implementation can coalesce SSTOREs. Crossing a level
/// threshold triggers the same facet-draw machinery as battle rewards.
interface IExpAssigner {
    function assignExp(address player, uint256[] calldata monIds, uint256[] calldata amounts) external;
}
