// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Structs.sol";

/// @title StaminaRegenLogic
/// @notice Inline stamina regen logic extracted from StaminaRegen effect for use by Engine
/// @dev This library contains no external calls - operates directly on storage references
library StaminaRegenLogic {
    /// @notice Regen stamina for a single mon if staminaDelta < 0
    function regenStamina(MonState storage monState) internal {
        if (monState.staminaDelta < 0) {
            monState.staminaDelta += 1;
        }
    }

    /// @notice Handle stamina regen for the RoundEnd step (both active mons)
    function onRoundEnd(
        BattleConfig storage config,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) internal {
        regenStamina(config.p0States[p0ActiveMonIndex]);
        regenStamina(config.p1States[p1ActiveMonIndex]);
    }

    /// @notice Handle stamina regen for the AfterMove step (regen if NoOp)
    function onAfterMove(
        BattleConfig storage config,
        uint256 playerIndex,
        uint256 monIndex
    ) internal {
        MoveDecision storage moveDecision = (playerIndex == 0) ? config.p0Move : config.p1Move;
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;
        if (moveIndex == NO_OP_MOVE_INDEX) {
            MonState storage monState = playerIndex == 0
                ? config.p0States[monIndex]
                : config.p1States[monIndex];
            regenStamina(monState);
        }
    }
}
