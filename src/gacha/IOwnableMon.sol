// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

interface IOwnableMon {
    function isOwner(address player, uint256 monId) external view returns (bool);
    function isOwnerBatch(address player, uint256[] calldata monIds) external view returns (bool);
    function balanceOf(address player) external view returns (uint256);
    function getOwned(address player) external view returns (uint256[] memory);
}
