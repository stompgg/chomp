// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT, DEFAULT_PRIORITY, MOVE_INDEX_MASK, NO_SLOT, SWITCH_MOVE_INDEX} from "../../Constants.sol";
import {MoveClass, TargetSpec, Type} from "../../Enums.sol";
import {MoveDecision, MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract InvokeTaboo is IMoveSet, BasicEffect {
    IEffect immutable SLEEP_STATUS;

    constructor(IEffect _SLEEP_STATUS) {
        SLEEP_STATUS = _SLEEP_STATUS;
    }

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Invoke Taboo";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256,
        uint256 targetBits,
        uint256 activesPacked,
        uint16,
        uint256
    ) external {
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot == NO_SLOT) {
            return; // no chosen target (defensive; the engine fizzles first)
        }
        uint256 defenderPlayerIndex = TargetLib.sideOf(targetSlot);
        uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, targetSlot);

        MoveDecision memory moveDecision = engine.getMoveDecisionForSlot(battleKey, defenderPlayerIndex, targetSlot & 1);
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;

        // Only brand regular move slots, not a switch (125) or no-op (126).
        if (moveIndex >= SWITCH_MOVE_INDEX) {
            return;
        }

        bytes32 tabooData = bytes32(uint256(moveIndex));
        (bool exists, uint256 effectIndex,) =
            engine.getEffectData(battleKey, defenderPlayerIndex, defenderMonIndex, address(this));
        if (exists) {
            engine.editEffect(defenderPlayerIndex, effectIndex, tabooData);
        } else {
            engine.addEffect(defenderPlayerIndex, defenderMonIndex, this, tabooData);
        }
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 1;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY - 1;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Cosmic;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
    }

    // Steps: OnMonSwitchOut (0x20), AfterMove (0x80), ALWAYS_APPLIES (0x8000)
    function getStepsBitmap() external pure override returns (uint16) {
        return ALWAYS_APPLIES_BIT | 0x00A0;
    }

    function onAfterMove(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external override returns (bytes32, bool) {
        uint256 ownSlot = TargetLib.slotOfMon(activesPacked, targetIndex, monIndex);
        if (ownSlot == NO_SLOT) {
            return (extraData, false);
        }
        MoveDecision memory moveDecision = engine.getMoveDecisionForSlot(battleKey, targetIndex, ownSlot & 1);
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;
        uint8 tabooMoveIndex = uint8(uint256(extraData));

        if (moveIndex == tabooMoveIndex) {
            engine.addEffect(targetIndex, monIndex, SLEEP_STATUS, "");
        }
        return (extraData, false);
    }

    function onMonSwitchOut(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32, bool)
    {
        return (extraData, true);
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            targetSpec: TargetSpec.AnyOtherSlot,
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}
