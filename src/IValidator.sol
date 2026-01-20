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

    // Validates a move for a specific slot in doubles mode
    function validatePlayerMoveForSlot(
        bytes32 battleKey,
        uint256 moveIndex,
        uint256 playerIndex,
        uint256 slotIndex,
        uint240 extraData
    ) external returns (bool);

    // Validates a move for a specific slot, accounting for what the other slot is switching to
    // claimedByOtherSlot is the mon index the other slot is switching to (type(uint256).max if not applicable)
    function validatePlayerMoveForSlotWithClaimed(
        bytes32 battleKey,
        uint256 moveIndex,
        uint256 playerIndex,
        uint256 slotIndex,
        uint240 extraData,
        uint256 claimedByOtherSlot
    ) external returns (bool);

    // Validates that a move selection is valid (specifically wrt stamina)
    // slotIndex is the slot (0 or 1) of the mon making the move in doubles
    function validateSpecificMoveSelection(
        bytes32 battleKey,
        uint256 moveIndex,
        uint256 playerIndex,
        uint256 slotIndex,
        uint240 extraData
    ) external returns (bool);

    // Validates that a switch is valid
    function validateSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monToSwitchIndex) external returns (bool);

    // Validates that there is a valid timeout, returns address(0) if no winner, otherwise returns the winner
    function validateTimeout(bytes32 battleKey, uint256 presumedAFKPlayerIndex) external returns (address);
}
