// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Enums.sol";
import {IEngine} from "../IEngine.sol";
import "../Structs.sol";

/// @title StaminaRegenLogic
/// @notice Shared decision predicates + external-effect entry points for stamina regen.
/// @dev The inline Engine path used to live here too as storage-mutating helpers, but those
/// bypassed engine.updateMonState() and so never fired OnUpdateMonState — abilities like
/// Dreamcatcher silently missed inline regen ticks. The inline path now lives in Engine.sol
/// (_inlineRegenStaminaForMon), which mirrors the storage write and then fires the hook
/// fan-out. This library keeps the pure predicates and the external-IEngine entry points
/// used by the StaminaRegen effect contract.
library StaminaRegenLogic {
    // ---------------------------------------------------------------------
    // Pure decision predicates (shared by inline + external paths)
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
    // IEngine-based entry points (external StaminaRegen contract path)
    // ---------------------------------------------------------------------

    /// @notice Regen stamina via IEngine if the mon's staminaDelta < 0
    function _regenStaminaExternal(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) internal {
        int256 currentStaminaDelta =
            engine.getMonStateForBattle(battleKey, playerIndex, monIndex, MonStateIndexName.Stamina);
        if (currentStaminaDelta < 0) {
            engine.updateMonState(playerIndex, monIndex, MonStateIndexName.Stamina, 1);
        }
    }

    /// @notice External RoundEnd entry point — gated on the same flag==2 check as the inline path.
    function onRoundEndExternal(IEngine engine, bytes32 battleKey, uint256 p0ActiveMonIndex, uint256 p1ActiveMonIndex)
        internal
    {
        // Reads the flag off the batched BattleContext (the dedicated getPlayerSwitchForTurnFlagForBattleState
        // getter was removed); this external-regen path is not the production hot path, so the extra
        // SLOADs are acceptable.
        uint256 playerSwitchForTurnFlag = engine.getBattleContext(battleKey).playerSwitchForTurnFlag;
        if (!_shouldRegenOnRoundEnd(playerSwitchForTurnFlag)) {
            return;
        }
        _regenStaminaExternal(engine, battleKey, 0, p0ActiveMonIndex);
        _regenStaminaExternal(engine, battleKey, 1, p1ActiveMonIndex);
    }

    /// @notice External AfterMove entry point — gated on the same NoOp check as the inline path.
    function onAfterMoveExternal(IEngine engine, bytes32 battleKey, uint256 targetIndex, uint256 monIndex) internal {
        MoveDecision memory moveDecision = engine.getMoveDecisionForSlot(battleKey, targetIndex, 0);
        if (!_isRestingMove(moveDecision.packedMoveIndex)) {
            return;
        }
        _regenStaminaExternal(engine, battleKey, targetIndex, monIndex);
    }
}
