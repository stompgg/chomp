// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../IEngine.sol";

interface IAbility {
    function name() external view returns (string memory);
    function activateOnSwitch(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external;
}
