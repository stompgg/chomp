// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Structs.sol";

import "../abilities/IAbility.sol";
import "../moves/IMoveSet.sol";

interface IMonRegistry {
    function getMonData(uint256 monId)
        external
        view
        returns (MonStats memory mon, uint256[] memory moves, address[] memory abilities);
    function getMonDataBatch(uint256[] calldata monIds)
        external
        view
        returns (MonStats[] memory stats, uint256[][] memory moves, address[][] memory abilities);
    function getMonStats(uint256 monId) external view returns (MonStats memory);
    function getMonMetadata(uint256 monId, bytes32 key) external view returns (bytes32);
    function getMonCount() external view returns (uint256);
    function getMonIds(uint256 start, uint256 end) external view returns (uint256[] memory);
    function isValidMove(uint256 monId, uint256 moveSlot) external view returns (bool);
    function isValidAbility(uint256 monId, IAbility ability) external view returns (bool);
    function validateMon(Mon memory m, uint256 monId) external view returns (bool);
    function validateMonBatch(Mon[] calldata mons, uint256[] calldata monIds) external view returns (bool);
}
