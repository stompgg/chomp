// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MOVE_INDEX_MASK, NO_OP_MOVE_INDEX, NO_SLOT, SWITCH_MOVE_INDEX} from "../../Constants.sol";
import {MonStateIndexName} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {MoveDecision} from "../../Structs.sol";

import {TargetLib} from "../../lib/TargetLib.sol";
import {StatusEffect} from "./StatusEffect.sol";

contract SleepStatus is StatusEffect {
    uint256 constant DURATION = 3;

    function name() public pure override returns (string memory) {
        return "Sleep";
    }

    // Steps: OnApply, RoundStart, RoundEnd, OnRemove
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x0F;
    }

    function _globalSleepKey(uint256 targetIndex) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encodePacked(name(), targetIndex))));
    }

    // Whether or not to add the effect if the step condition is met.
    // Enforces one sleeper per player: the global sleep key stores
    // [monIndex+1 (bits 160+) | status address (lower 160 bits)] for the player's current sleeper.
    function shouldApply(IEngine engine, bytes32 battleKey, bytes32 data, uint256 targetIndex, uint256 monIndex)
        public
        view
        override
        returns (bool)
    {
        if (!super.shouldApply(engine, battleKey, data, targetIndex, monIndex)) {
            return false;
        }
        uint192 sleeperFlag = engine.getGlobalKV(battleKey, _globalSleepKey(targetIndex));
        if (sleeperFlag == 0) {
            return true;
        }
        // A KO'd sleeper releases the gate: its frozen Sleep effect can never tick down or be
        // removed, so without this check one KO'd sleeper would lock the gate for the whole battle.
        uint256 sleeperMonIndex = uint256(sleeperFlag >> 160) - 1;
        return engine.getMonStateForBattle(battleKey, targetIndex, sleeperMonIndex, MonStateIndexName.IsKnockedOut) != 0;
    }

    function _applySleep(
        IEngine engine,
        bytes32 battleKey,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) internal {
        // Rewrite the sleeper's own slot; a benched sleeper (possible mid-pass in 2-slot
        // battles) has no pending move to overwrite.
        uint256 slot = TargetLib.slotOfMon(activesPacked, targetIndex, monIndex);
        if (slot == NO_SLOT) return;
        MoveDecision memory moveDecision = engine.getMoveDecisionForSlot(battleKey, targetIndex, slot & 1);
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;
        if (moveIndex != SWITCH_MOVE_INDEX) {
            engine.setMoveForSlot(battleKey, targetIndex, slot & 1, NO_OP_MOVE_INDEX, 0);
        }
    }

    // At the start of the turn, check to see if we should apply sleep or end early
    function onRoundStart(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external override returns (bytes32, bool) {
        rng = uint256(keccak256(abi.encode(rng, targetIndex, monIndex)));
        bool wakeEarly = rng % 3 == 0;
        if (!wakeEarly) {
            _applySleep(engine, battleKey, targetIndex, monIndex, activesPacked);
        }
        return (extraData, wakeEarly);
    }

    // On apply, checks to apply the sleep flag, and then sets the extraData to be the duration
    function onApply(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 data,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) public override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        super.onApply(engine, battleKey, rng, data, targetIndex, monIndex, activesPacked);
        // Register this mon as the player's single sleeper (read by the shouldApply gate).
        engine.setGlobalKV(
            _globalSleepKey(targetIndex), uint192(uint160(address(this))) | (uint192(monIndex + 1) << 160)
        );
        // Check if opponent has yet to move and if so, also affect their move for this round
        uint256 priorityPlayerIndex = engine.computePriorityPlayerIndex(battleKey, rng);
        if (targetIndex != priorityPlayerIndex) {
            _applySleep(engine, battleKey, targetIndex, monIndex, activesPacked);
        }
        return (bytes32(DURATION), false);
    }

    function onRoundEnd(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256)
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

    function onRemove(
        IEngine engine,
        bytes32 battleKey,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) public override {
        super.onRemove(engine, battleKey, extraData, targetIndex, monIndex, activesPacked);
        // Clear the sleeper flag only if it still points at this mon: after a KO'd sleeper
        // releases the gate, a successor sleeper owns the flag and must keep it.
        uint192 sleeperFlag = engine.getGlobalKV(battleKey, _globalSleepKey(targetIndex));
        if (uint256(sleeperFlag >> 160) == monIndex + 1) {
            engine.setGlobalKV(_globalSleepKey(targetIndex), 0);
        }
    }
}
