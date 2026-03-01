// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../moves/IMoveSet.sol";

/// @dev Parameters for timeout validation (allows pure function)
struct TimeoutCheckParams {
    uint64 turnId;
    uint256 playerSwitchForTurnFlag;
    uint256 playerIndexToCheck;
    uint256 lastTurnTimestamp;
    uint256 timeoutDuration;
    uint256 prevTurnMultiplier;
    // Commit data for player being checked
    bytes32 playerMoveHash;
    uint256 playerCommitTurnId;
    // Commit data for other player
    uint256 otherPlayerRevealCount;
    uint256 otherPlayerTimestamp;
    bytes32 otherPlayerMoveHash;
    uint256 otherPlayerCommitTurnId;
}

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

    /// @notice Validates whether a player has timed out
    /// @dev View function (uses block.timestamp) - all commit manager data must be pre-fetched and passed in
    /// @param params All parameters needed for timeout validation
    /// @return isTimeout Whether the player has timed out
    function validateTimeoutLogic(TimeoutCheckParams memory params) internal view returns (bool isTimeout) {
        // Single player turn, and it's the player's turn:
        if (params.playerSwitchForTurnFlag == params.playerIndexToCheck) {
            if (block.timestamp >= params.lastTurnTimestamp + params.prevTurnMultiplier * params.timeoutDuration) {
                return true;
            }
        }
        // Two player turn:
        else if (params.playerSwitchForTurnFlag == 2) {
            // Player is committing + revealing:
            if (params.turnId % 2 == params.playerIndexToCheck) {
                // If player has already committed:
                if (params.playerCommitTurnId == params.turnId && params.playerMoveHash != bytes32(0)) {
                    // Check if other player has already revealed
                    // If so, check for timeout from their reveal timestamp
                    if (params.otherPlayerRevealCount > params.turnId) {
                        if (block.timestamp >= params.otherPlayerTimestamp + params.timeoutDuration) {
                            return true;
                        }
                    }
                }
                // If player has not committed yet:
                else {
                    if (block.timestamp >= params.lastTurnTimestamp + params.prevTurnMultiplier * params.timeoutDuration) {
                        return true;
                    }
                }
            }
            // Player is revealing:
            else {
                // If other player has already committed:
                if (params.otherPlayerCommitTurnId == params.turnId && params.otherPlayerMoveHash != bytes32(0)) {
                    if (block.timestamp >= params.otherPlayerTimestamp + params.timeoutDuration) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /// @notice Validates a switch for a specific slot in doubles
    /// @dev Extends validateSwitch with doubles-specific checks (other slot active, claimed by other slot)
    /// @param turnId Current turn ID
    /// @param monToSwitchIndex The mon index to switch to
    /// @param currentSlotActiveMonIndex The current active mon index for this slot
    /// @param otherSlotActiveMonIndex The active mon index for the other slot
    /// @param claimedByOtherSlot Mon index claimed by other slot (type(uint256).max if none)
    /// @param isTargetKnockedOut Whether the target mon is knocked out
    /// @param monsPerTeam Maximum mons per team
    /// @return valid Whether the switch is valid
    function validateSwitchForSlot(
        uint64 turnId,
        uint256 monToSwitchIndex,
        uint256 currentSlotActiveMonIndex,
        uint256 otherSlotActiveMonIndex,
        uint256 claimedByOtherSlot,
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

        // Cannot switch to mon already active in the other slot
        if (monToSwitchIndex == otherSlotActiveMonIndex) {
            return false;
        }

        // Cannot switch to mon being claimed by the other slot
        if (monToSwitchIndex == claimedByOtherSlot) {
            return false;
        }

        // Cannot switch to same mon (except on turn 0 for initial switch-in)
        if (turnId != 0 && monToSwitchIndex == currentSlotActiveMonIndex) {
            return false;
        }

        return true;
    }

    /// @notice Validates basic player move selection for a slot in doubles
    /// @dev Extends validatePlayerMoveBasics with NO_OP fallback when no valid switch targets exist
    /// @param moveIndex The move index
    /// @param turnId Current turn ID
    /// @param isActiveMonKnockedOut Whether the active mon is knocked out
    /// @param hasValidSwitchTarget Whether there is at least one valid switch target
    /// @param movesPerMon Maximum moves per mon
    /// @return requiresSwitch Whether the validation requires a switch
    /// @return isNoOp Whether this is a no-op move
    /// @return isSwitch Whether this is a switch move
    /// @return isRegularMove Whether this is a regular move (0-3)
    /// @return valid Whether basic validation passes
    function validatePlayerMoveBasicsForSlot(
        uint256 moveIndex,
        uint64 turnId,
        bool isActiveMonKnockedOut,
        bool hasValidSwitchTarget,
        uint256 movesPerMon
    )
        internal
        pure
        returns (bool requiresSwitch, bool isNoOp, bool isSwitch, bool isRegularMove, bool valid)
    {
        // On turn 0 or if active mon is KO'd, must switch
        requiresSwitch = (turnId == 0) || isActiveMonKnockedOut;

        if (requiresSwitch && moveIndex != SWITCH_MOVE_INDEX) {
            // In doubles, NO_OP is allowed if there are no valid switch targets
            if (moveIndex == NO_OP_MOVE_INDEX && !hasValidSwitchTarget) {
                return (requiresSwitch, true, false, false, true);
            }
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

    /// @notice Pure game-over check using KO bitmaps and team sizes
    /// @param p0KOBitmap Bitmap where bit i is set if p0's mon i is knocked out
    /// @param p1KOBitmap Bitmap where bit i is set if p1's mon i is knocked out
    /// @param p0TeamSize Number of mons on p0's team
    /// @param p1TeamSize Number of mons on p1's team
    /// @return winnerIndex 0 if p0 wins, 1 if p1 wins, 2 if no winner yet
    function checkGameOver(
        uint256 p0KOBitmap,
        uint256 p1KOBitmap,
        uint256 p0TeamSize,
        uint256 p1TeamSize
    ) internal pure returns (uint256 winnerIndex) {
        uint256 p0FullMask = (1 << p0TeamSize) - 1;
        uint256 p1FullMask = (1 << p1TeamSize) - 1;
        if (p0KOBitmap == p0FullMask) return 1; // p1 wins (all p0 mons KO'd)
        if (p1KOBitmap == p1FullMask) return 0; // p0 wins (all p1 mons KO'd)
        return 2; // No winner yet
    }

    /// @notice Checks if there's a valid switch target for a slot using a KO bitmap
    /// @param koBitmap Bitmap where bit i is set if mon i is knocked out
    /// @param otherSlotActiveMonIndex Mon index active in the other slot
    /// @param claimedByOtherSlot Mon index claimed by other slot (type(uint256).max if none)
    /// @param monsPerTeam Maximum mons per team
    /// @return Whether at least one valid switch target exists
    function hasValidSwitchTargetForSlotBitmap(
        uint256 koBitmap,
        uint256 otherSlotActiveMonIndex,
        uint256 claimedByOtherSlot,
        uint256 monsPerTeam
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < monsPerTeam; i++) {
            if (i == otherSlotActiveMonIndex) continue;
            if (i == claimedByOtherSlot) continue;
            // Bit not set means mon is alive
            if ((koBitmap & (1 << i)) == 0) return true;
        }
        return false;
    }
}
