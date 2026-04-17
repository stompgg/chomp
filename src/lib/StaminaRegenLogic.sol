// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Enums.sol";
import "../Structs.sol";
import {IEngine} from "../IEngine.sol";

/// @title StaminaRegenLogic
/// @notice Shared stamina regen logic used by both the inline Engine path and the external StaminaRegen effect.
/// @dev Exposes two parallel entry-point sets (storage-based and IEngine-based) that share the same
/// pure decision predicates, so inline and external regen behave identically.
library StaminaRegenLogic {
    // ---------------------------------------------------------------------
    // Pure decision predicates (shared by both paths)
    // ---------------------------------------------------------------------

    /// @notice Round-end regen only fires on full two-player turns.
    function _shouldRegenOnRoundEnd(uint256 playerSwitchForTurnFlag) internal pure returns (bool) {
        return playerSwitchForTurnFlag == 2;
    }

    /// @notice After-move regen fires only when the chosen move was a no-op (resting).
    function _isRestingMove(uint8 packedMoveIndex) internal pure returns (bool) {
        return (packedMoveIndex & MOVE_INDEX_MASK) == NO_OP_MOVE_INDEX;
    }

    // ---------------------------------------------------------------------
    // Storage-based entry points (inline Engine path)
    // ---------------------------------------------------------------------

    /// @notice Regen stamina for a single mon if staminaDelta < 0
    function regenStamina(MonState storage monState) internal {
        if (monState.staminaDelta < 0) {
            monState.staminaDelta += 1;
        }
    }

    /// @notice Handle stamina regen for the RoundEnd step (both active mons)
    function onRoundEnd(
        BattleConfig storage config,
        uint256 playerSwitchForTurnFlag,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) internal {
        if (!_shouldRegenOnRoundEnd(playerSwitchForTurnFlag)) return;
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
        if (!_isRestingMove(moveDecision.packedMoveIndex)) return;
        MonState storage monState = playerIndex == 0
            ? config.p0States[monIndex]
            : config.p1States[monIndex];
        regenStamina(monState);
    }

    // ---------------------------------------------------------------------
    // IEngine-based entry points (external StaminaRegen contract path)
    // ---------------------------------------------------------------------

    /// @notice Regen stamina via IEngine if the mon's staminaDelta < 0
    function _regenStaminaExternal(
        IEngine engine,
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 monIndex
    ) internal {
        int256 currentStaminaDelta =
            engine.getMonStateForBattle(battleKey, playerIndex, monIndex, MonStateIndexName.Stamina);
        if (currentStaminaDelta < 0) {
            engine.updateMonState(playerIndex, monIndex, MonStateIndexName.Stamina, 1);
        }
    }

    /// @notice External RoundEnd entry point — gated on the same flag==2 check as the inline path.
    function onRoundEndExternal(
        IEngine engine,
        bytes32 battleKey,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) internal {
        uint256 playerSwitchForTurnFlag = engine.getPlayerSwitchForTurnFlagForBattleState(battleKey);
        if (!_shouldRegenOnRoundEnd(playerSwitchForTurnFlag)) return;
        _regenStaminaExternal(engine, battleKey, 0, p0ActiveMonIndex);
        _regenStaminaExternal(engine, battleKey, 1, p1ActiveMonIndex);
    }

    /// @notice External AfterMove entry point — gated on the same NoOp check as the inline path.
    function onAfterMoveExternal(
        IEngine engine,
        bytes32 battleKey,
        uint256 targetIndex,
        uint256 monIndex
    ) internal {
        MoveDecision memory moveDecision = engine.getMoveDecisionForBattleState(battleKey, targetIndex);
        if (!_isRestingMove(moveDecision.packedMoveIndex)) return;
        _regenStaminaExternal(engine, battleKey, targetIndex, monIndex);
    }
}
