// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Structs.sol";
import "./teams/ITeamRegistry.sol";

interface IValidator {
    // Validates that e.g. there are X mons per team w/ Y moves each
    function validateGameStart(
        address p0, address p1, Mon[][] calldata teams, ITeamRegistry teamRegistry, uint256 p0TeamIndex, uint256 p1TeamIndex
    ) external returns (bool);

    // Validates that you can't switch to the same mon, you have enough stamina, the move isn't disabled, etc.
    function validatePlayerMove(bytes32 battleKey, uint256 moveIndex, uint256 playerIndex, uint240 extraData)
        external
        returns (bool);

    // Validates that a move selection is valid (specifically wrt stamina)
    function validateSpecificMoveSelection(
        bytes32 battleKey,
        uint256 moveIndex,
        uint256 playerIndex,
        uint240 extraData
    ) external returns (bool);

    // Validates that a switch is valid
    function validateSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monToSwitchIndex) external returns (bool);

    // Validates that there is a valid timeout, returns address(0) if no winner, otherwise returns the winner
    function validateTimeout(bytes32 battleKey, uint256 presumedAFKPlayerIndex) external returns (address);
}
