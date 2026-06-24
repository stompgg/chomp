// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT, DEFAULT_PRIORITY, MOVE_INDEX_MASK, SWITCH_MOVE_INDEX} from "../../Constants.sol";
import {ExtraDataType, MoveClass, Type} from "../../Enums.sol";
import {MoveDecision, MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";

/// @notice Invoke Taboo declares the opponent's move forbidden. It resolves at -1 priority so it
///         goes after the opponent has already acted, then reads the move they used this turn and
///         brands it taboo. While the brand is on that mon (it is cleared when they switch out), the
///         next time they use the tabooed move they fall asleep.
/// @dev Implemented as an IMoveSet + BasicEffect hybrid. The effect lives on the *opponent's* mon;
///      its AfterMove hook checks whether the move that just resolved matches the branded move and,
///      if so, applies SleepStatus to that mon.
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
        uint256 defenderMonIndex,
        uint16,
        uint256
    ) external {
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;

        // Read the move the opponent used this turn. Invoke Taboo's -1 priority guarantees it
        // resolves after the opponent, so their decision is already recorded.
        MoveDecision memory moveDecision = engine.getMoveDecisionForBattleState(battleKey, defenderPlayerIndex);
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;

        // Only brand actual moves (slots 0..3). Switching (125) or resting/no-op (126) are not
        // tabooable — there is nothing meaningful to forbid.
        if (moveIndex >= SWITCH_MOVE_INDEX) {
            return;
        }

        bytes32 tabooData = bytes32(uint256(moveIndex));
        (bool exists, uint256 effectIndex,) =
            engine.getEffectData(battleKey, defenderPlayerIndex, defenderMonIndex, address(this));
        if (exists) {
            // Re-brand with the most recent move.
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

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    // Steps: OnMonSwitchOut (0x20), AfterMove (0x80), ALWAYS_APPLIES (0x8000)
    function getStepsBitmap() external pure override returns (uint16) {
        return ALWAYS_APPLIES_BIT | 0x00A0;
    }

    /// @notice After the branded mon moves, if it used the tabooed move, put it to sleep.
    function onAfterMove(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256,
        uint256
    ) external override returns (bytes32, bool) {
        MoveDecision memory moveDecision = engine.getMoveDecisionForBattleState(battleKey, targetIndex);
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;
        uint8 tabooMoveIndex = uint8(uint256(extraData));

        if (moveIndex == tabooMoveIndex) {
            engine.addEffect(targetIndex, monIndex, SLEEP_STATUS, "");
        }
        return (extraData, false);
    }

    function onMonSwitchOut(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32, bool)
    {
        // Taboo lasts until the branded mon switches out.
        return (extraData, true);
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            extraDataType: extraDataType(),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}
