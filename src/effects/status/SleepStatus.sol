// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, MOVE_INDEX_MASK} from "../../Constants.sol";
import {EffectStep} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {MoveDecision} from "../../Structs.sol";

import {StatusEffect} from "./StatusEffect.sol";

contract SleepStatus is StatusEffect {
    uint256 constant DURATION = 3;

    constructor(IEngine engine) StatusEffect(engine) {}

    function name() public pure override returns (string memory) {
        return "Sleep";
    }

    function shouldRunAtStep(EffectStep r) external pure override returns (bool) {
        return
            r == EffectStep.RoundStart || r == EffectStep.RoundEnd || r == EffectStep.OnApply
                || r == EffectStep.OnRemove;
    }

    function _globalSleepKey(uint256 targetIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(name(), targetIndex));
    }

    // Whether or not to add the effect if the step condition is met
    function shouldApply(bytes32 data, uint256 targetIndex, uint256 monIndex) public view override returns (bool) {
        bool shouldApplyStatusInGeneral = super.shouldApply(data, targetIndex, monIndex);
        bool playerHasZeroSleepers =
            address(uint160(ENGINE.getGlobalKV(ENGINE.battleKeyForWrite(), _globalSleepKey(targetIndex)))) == address(0);
        return (shouldApplyStatusInGeneral && playerHasZeroSleepers);
    }

    function _applySleep(uint256 targetIndex, uint256) internal {
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        // Get exiting move index (unpack from packedMoveIndex)
        MoveDecision memory moveDecision = ENGINE.getMoveDecisionForBattleState(battleKey, targetIndex);
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;
        if (moveIndex != SWITCH_MOVE_INDEX) {
            ENGINE.setMove(battleKey, targetIndex, NO_OP_MOVE_INDEX, "", 0);
        }
    }

    // At the start of the turn, check to see if we should apply sleep or end early
    function onRoundStart(uint256 rng, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32, bool)
    {
        bool wakeEarly = rng % 3 == 0;
        if (!wakeEarly) {
            _applySleep(targetIndex, monIndex);
        }
        return (extraData, wakeEarly);
    }

    // On apply, checks to apply the sleep flag, and then sets the extraData to be the duration
    function onApply(uint256 rng, bytes32 data, uint256 targetIndex, uint256 monIndex)
        public
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        super.onApply(rng, data, targetIndex, monIndex);
        // Check if opponent has yet to move and if so, also affect their move for this round
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        uint256 priorityPlayerIndex = ENGINE.computePriorityPlayerIndex(battleKey, rng);
        if (targetIndex != priorityPlayerIndex) {
            _applySleep(targetIndex, monIndex);
        }
        return (bytes32(DURATION), false);
    }

    function onRoundEnd(uint256, bytes32 extraData, uint256, uint256)
        external
        pure
        override
        returns (bytes32, bool removeAfterRun)
    {
        uint256 turnsLeft = uint256(extraData);
        if (turnsLeft == 1) {
            return (extraData, true);
        } else {
            return (bytes32(turnsLeft - 1), false);
        }
    }

    function onRemove(bytes32 extraData, uint256 targetIndex, uint256 monIndex) public override {
        super.onRemove(extraData, targetIndex, monIndex);
        ENGINE.setGlobalKV(_globalSleepKey(targetIndex), 0);
    }
}
