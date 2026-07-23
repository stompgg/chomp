// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {
    ALWAYS_APPLIES_BIT, MOVE_INDEX_MASK, NO_SLOT, STATUS_CLASS_SHIFT, SWITCH_MOVE_INDEX
} from "../../Constants.sol";
import {MonStateIndexName} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {MoveDecision} from "../../Structs.sol";

import {TargetLib} from "../../lib/TargetLib.sol";
import {StatusEffect} from "./StatusEffect.sol";

contract ZapStatus is StatusEffect {
    uint256 constant STATUS_CLASS = 5;

    uint8 private constant ALREADY_SKIPPED = 1;

    function name() public pure override returns (string memory) {
        return "Zap";
    }

    // Steps: OnApply, RoundStart, RoundEnd, OnRemove
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x0F | uint16(STATUS_CLASS << STATUS_CLASS_SHIFT) | ALWAYS_APPLIES_BIT;
    }

    function onApply(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) public override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        uint8 state;

        // If the target hasn't acted yet this turn, skip it immediately; otherwise wait for
        // next RoundStart (a lingering flag would eat a forced switch instead of a move).
        uint256 slot = TargetLib.slotOfMon(activesPacked, targetIndex, monIndex);
        if (slot != NO_SLOT && !engine.hasSlotActedThisTurn(slot)) {
            engine.updateMonState(targetIndex, monIndex, MonStateIndexName.ShouldSkipTurn, 1);
            state = ALREADY_SKIPPED; // Ready to remove at RoundEnd
        }

        return (bytes32(uint256(state)), false);
    }

    function onRoundStart(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        // If we're at RoundStart and effect is still present, always set skip flag and mark as skipped, unless the selected move is a switch move
        uint256 slot = TargetLib.slotOfMon(activesPacked, targetIndex, monIndex);
        if (slot == NO_SLOT) {
            return (bytes32(uint256(0)), false); // benched: nothing to skip this round
        }
        MoveDecision memory moveDecision = engine.getMoveDecisionForSlot(battleKey, targetIndex, slot & 1);
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;
        if (moveIndex == SWITCH_MOVE_INDEX) {
            return (bytes32(uint256(0)), false);
        }
        engine.updateMonState(targetIndex, monIndex, MonStateIndexName.ShouldSkipTurn, 1);
        return (bytes32(uint256(ALREADY_SKIPPED)), false);
    }

    function onRoundEnd(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256)
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
