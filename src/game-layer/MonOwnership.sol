// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {EnumerableSetLib} from "../lib/EnumerableSetLib.sol";

/// @notice Per-player mon ownership set.
abstract contract MonOwnership {
    using EnumerableSetLib for *;

    error NotOwner();

    mapping(address => EnumerableSetLib.Uint256Set) internal monsOwned;

    function isOwner(address player, uint256 monId) external view returns (bool) {
        return monsOwned[player].contains(monId);
    }

    function isOwnerBatch(address player, uint256[] calldata ids) external view returns (bool) {
        return _isOwnerBatch(player, ids);
    }

    function balanceOf(address player) external view returns (uint256) {
        return monsOwned[player].length();
    }

    function getOwned(address player) external view returns (uint256[] memory) {
        return monsOwned[player].values();
    }

    function _isOwnerBatch(address player, uint256[] memory ids) internal view returns (bool) {
        EnumerableSetLib.Uint256Set storage owned = monsOwned[player];
        uint256 len = ids.length;
        for (uint256 i; i < len;) {
            if (!owned.contains(ids[i])) {
                return false;
            }
            unchecked { ++i; }
        }
        return true;
    }

    function _validateOwnership(uint256[] memory monIndices) internal view {
        if (!_isOwnerBatch(msg.sender, monIndices)) revert NotOwner();
    }
}
