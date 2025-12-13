// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {NO_OP_MOVE_INDEX, MOVE_INDEX_MASK} from "../Constants.sol";
import "../Enums.sol";
import {MoveDecision} from "../Structs.sol";

import {IEngine} from "../IEngine.sol";
import {BasicEffect} from "./BasicEffect.sol";

contract StaminaRegen is BasicEffect {
    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() external pure override returns (string memory) {
        return "Stamina Regen";
    }

    // Should run at end of round
    function shouldRunAtStep(EffectStep r) external pure override returns (bool) {
        return (r == EffectStep.RoundEnd) || (r == EffectStep.AfterMove);
    }

    // No overhealing stamina
    function _regenStamina(uint256 playerIndex, uint256 monIndex) internal {
        int256 currentActiveMonStaminaDelta =
            ENGINE.getMonStateForBattle(ENGINE.battleKeyForWrite(), playerIndex, monIndex, MonStateIndexName.Stamina);
        if (currentActiveMonStaminaDelta < 0) {
            ENGINE.updateMonState(playerIndex, monIndex, MonStateIndexName.Stamina, 1);
        }
    }

    // Regen stamina on round end for both active mons
    function onRoundEnd(uint256, bytes32, uint256, uint256) external override returns (bytes32, bool) {
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        uint256 playerSwitchForTurnFlag = ENGINE.getPlayerSwitchForTurnFlagForBattleState(battleKey);
        uint256[] memory activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey);
        // Update stamina for both active mons only if it's a 2 player turn
        if (playerSwitchForTurnFlag == 2) {
            for (uint256 playerIndex; playerIndex < 2; ++playerIndex) {
                _regenStamina(playerIndex, activeMonIndex[playerIndex]);
            }
        }
        return (bytes32(0), false);
    }

    // Regen stamina if the mon did a No Op (i.e. resting)
    function onAfterMove(uint256, bytes32, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32, bool)
    {
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        MoveDecision memory moveDecision = ENGINE.getMoveDecisionForBattleState(battleKey, targetIndex);
        // Unpack the move index from packedMoveIndex
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;
        if (moveIndex == NO_OP_MOVE_INDEX) {
            _regenStamina(targetIndex, monIndex);
        }
        return (bytes32(0), false);
    }
}
