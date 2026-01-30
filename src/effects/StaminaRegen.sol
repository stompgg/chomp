// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {NO_OP_MOVE_INDEX, MOVE_INDEX_MASK} from "../Constants.sol";
import "../Enums.sol";
import {MoveDecision, EffectContext} from "../Structs.sol";

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
    function _regenStamina(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) internal {
        int256 currentActiveMonStaminaDelta =
            ENGINE.getMonStateForBattle(battleKey, playerIndex, monIndex, MonStateIndexName.Stamina);
        if (currentActiveMonStaminaDelta < 0) {
            ENGINE.updateMonState(playerIndex, monIndex, MonStateIndexName.Stamina, 1);
        }
    }

    // Regen stamina on round end for both active mons
    function onRoundEnd(EffectContext calldata ctx, uint256, bytes32, uint256, uint256) external override returns (bytes32, bool) {
        // Use context directly instead of external calls
        // Update stamina for both active mons only if it's a 2 player turn
        if (ctx.playerSwitchForTurnFlag == 2) {
            _regenStamina(ctx.battleKey, 0, ctx.p0ActiveMonIndex);
            _regenStamina(ctx.battleKey, 1, ctx.p1ActiveMonIndex);
        }
        return (bytes32(0), false);
    }

    // Regen stamina if the mon did a No Op (i.e. resting)
    function onAfterMove(EffectContext calldata ctx, uint256, bytes32, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32, bool)
    {
        MoveDecision memory moveDecision = ENGINE.getMoveDecisionForBattleState(ctx.battleKey, targetIndex);
        // Unpack the move index from packedMoveIndex
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;
        if (moveIndex == NO_OP_MOVE_INDEX) {
            _regenStamina(ctx.battleKey, targetIndex, monIndex);
        }
        return (bytes32(0), false);
    }
}
