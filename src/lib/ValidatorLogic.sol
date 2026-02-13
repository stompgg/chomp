// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../moves/IMoveSet.sol";

/// @title ValidatorLogic
/// @notice Pure validation logic extracted from DefaultValidator for reuse by Engine
/// @dev This library contains no external calls - all data must be passed in
library ValidatorLogic {
    /// @notice Validates a specific move selection (stamina + move's own validation)
    /// @param battleKey The battle identifier
    /// @param moveSet The move being used
    /// @param playerIndex The player using the move
    /// @param activeMonIndex The active mon index for this player
    /// @param extraData Extra data for the move
    /// @param baseStamina The mon's base stamina
    /// @param staminaDelta The mon's current stamina delta (or CLEARED_MON_STATE_SENTINEL if unset)
    /// @return valid Whether the move selection is valid
    function validateSpecificMoveSelection(
        bytes32 battleKey,
        IMoveSet moveSet,
        uint256 playerIndex,
        uint256 activeMonIndex,
        uint240 extraData,
        uint32 baseStamina,
        int32 staminaDelta
    ) internal view returns (bool valid) {
        // Handle sentinel value
        int256 effectiveDelta = staminaDelta == CLEARED_MON_STATE_SENTINEL ? int256(0) : int256(staminaDelta);
        uint256 currentStamina = uint256(int256(uint256(baseStamina)) + effectiveDelta);

        // Check stamina cost
        if (moveSet.stamina(battleKey, playerIndex, activeMonIndex) > currentStamina) {
            return false;
        }

        // Check move's own validation
        if (!moveSet.isValidTarget(battleKey, extraData)) {
            return false;
        }

        return true;
    }

    /// @notice Validates a switch to a different mon
    /// @param turnId Current turn ID
    /// @param activeMonIndex The current active mon index for this player
    /// @param monToSwitchIndex The mon index to switch to
    /// @param isTargetKnockedOut Whether the target mon is knocked out
    /// @param monsPerTeam Maximum mons per team
    /// @return valid Whether the switch is valid
    function validateSwitch(
        uint64 turnId,
        uint256 activeMonIndex,
        uint256 monToSwitchIndex,
        bool isTargetKnockedOut,
        uint256 monsPerTeam
    ) internal pure returns (bool valid) {
        // Check bounds
        if (monToSwitchIndex >= monsPerTeam) {
            return false;
        }

        // Cannot switch to a knocked out mon
        if (isTargetKnockedOut) {
            return false;
        }

        // Cannot switch to the same mon (except on turn 0 for initial switch-in)
        if (turnId != 0 && monToSwitchIndex == activeMonIndex) {
            return false;
        }

        return true;
    }

    /// @notice Validates a player's move selection (high-level validation)
    /// @dev This combines switch validation and move validation logic
    /// @param moveIndex The move index (0-3 for moves, SWITCH_MOVE_INDEX for switch, NO_OP_MOVE_INDEX for no-op)
    /// @param turnId Current turn ID
    /// @param isActiveMonKnockedOut Whether the active mon is knocked out
    /// @param movesPerMon Maximum moves per mon
    /// @return requiresSwitch Whether the validation requires a switch
    /// @return isNoOp Whether this is a no-op move
    /// @return isSwitch Whether this is a switch move
    /// @return isRegularMove Whether this is a regular move (0-3)
    /// @return valid Whether basic validation passes (bounds check, forced switch check)
    function validatePlayerMoveBasics(
        uint256 moveIndex,
        uint64 turnId,
        bool isActiveMonKnockedOut,
        uint256 movesPerMon
    )
        internal
        pure
        returns (bool requiresSwitch, bool isNoOp, bool isSwitch, bool isRegularMove, bool valid)
    {
        // On turn 0 or if active mon is KO'd, must switch
        requiresSwitch = (turnId == 0) || isActiveMonKnockedOut;

        if (requiresSwitch && moveIndex != SWITCH_MOVE_INDEX) {
            return (requiresSwitch, false, false, false, false);
        }

        // Identify move type
        isNoOp = (moveIndex == NO_OP_MOVE_INDEX);
        isSwitch = (moveIndex == SWITCH_MOVE_INDEX);
        isRegularMove = !isNoOp && !isSwitch;

        // Bounds check for regular moves
        if (isRegularMove && moveIndex >= movesPerMon) {
            return (requiresSwitch, isNoOp, isSwitch, isRegularMove, false);
        }

        return (requiresSwitch, isNoOp, isSwitch, isRegularMove, true);
    }
}
