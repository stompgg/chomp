// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MoveDecision} from "../../Structs.sol";
import {NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, MOVE_INDEX_MASK } from "../../Constants.sol";
import {EffectStep, MonStateIndexName} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";

import {StatusEffect} from "./StatusEffect.sol";

contract ZapStatus is StatusEffect {
    
    uint8 private constant ALREADY_SKIPPED = 1;

    constructor(IEngine engine) StatusEffect(engine) {}

    function name() public pure override returns (string memory) {
        return "Zap";
    }

    function shouldRunAtStep(EffectStep r) external pure override returns (bool) {
        return (r == EffectStep.OnApply || r == EffectStep.RoundStart || r == EffectStep.RoundEnd
                || r == EffectStep.OnRemove);
    }

    function onApply(uint256 rng, bytes32 data, uint256 targetIndex, uint256 monIndex)
        public
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        super.onApply(rng, data, targetIndex, monIndex);

        // Get the battle key and compute priority player index
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        uint256 priorityPlayerIndex = ENGINE.computePriorityPlayerIndex(battleKey, rng);

        uint8 state;

        // Check if opponent has yet to move
        if (targetIndex != priorityPlayerIndex) {
            // Opponent hasn't moved yet (they're the non-priority player)
            // Set skip turn flag immediately
            ENGINE.updateMonState(targetIndex, monIndex, MonStateIndexName.ShouldSkipTurn, 1);
            state = ALREADY_SKIPPED; // Ready to remove at RoundEnd
        }
        // else: Opponent has already moved, state = 0 (not yet skipped), wait for RoundStart

        return (bytes32(uint256(state)), false);
    }

    function onRoundStart(uint256, bytes32, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        // If we're at RoundStart and effect is still present, always set skip flag and mark as skipped, unless the selected move is a switch move
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        MoveDecision memory moveDecision = ENGINE.getMoveDecisionForBattleState(battleKey, targetIndex);
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;
        if (moveIndex == SWITCH_MOVE_INDEX) {
            return (bytes32(uint256(0)), false);
        }
        ENGINE.updateMonState(targetIndex, monIndex, MonStateIndexName.ShouldSkipTurn, 1);
        return (bytes32(uint256(ALREADY_SKIPPED)), false);
    }

    function onRemove(bytes32 data, uint256 targetIndex, uint256 monIndex) public override {
        super.onRemove(data, targetIndex, monIndex);
    }

    function onRoundEnd(uint256, bytes32 extraData, uint256, uint256)
        public
        pure
        override
        returns (bytes32, bool)
    {
        uint8 state = uint8(uint256(extraData));

        // Otherwise keep the effect
        return (extraData, state == ALREADY_SKIPPED);
    }
}