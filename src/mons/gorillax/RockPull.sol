// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {
    DEFAULT_ACCURACY,
    DEFAULT_CRIT_RATE,
    DEFAULT_PRIORITY,
    DEFAULT_VOL,
    MOVE_INDEX_MASK,
    NO_SLOT,
    SWITCH_MOVE_INDEX,
    SWITCH_PRIORITY
} from "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {MoveDecision, MoveMeta} from "../../Structs.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract RockPull is IMoveSet {
    uint32 public constant OPPONENT_BASE_POWER = 80;
    uint32 public constant SELF_DAMAGE_BASE_POWER = 30;

    ITypeCalculator immutable TYPE_CALCULATOR;

    constructor(ITypeCalculator _TYPE_CALCULATOR) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }

    function name() public pure override returns (string memory) {
        return "Rock Pull";
    }

    function _didTargetChooseSwitch(IEngine engine, bytes32 battleKey, uint256 targetSlot)
        internal
        view
        returns (bool)
    {
        MoveDecision memory targetMove = engine.getMoveDecisionForSlot(battleKey, targetSlot >> 1, targetSlot & 1);
        uint8 moveIndex = targetMove.packedMoveIndex & MOVE_INDEX_MASK;
        return moveIndex == SWITCH_MOVE_INDEX;
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256 activesPacked,
        uint16,
        uint256 rng
    ) external {
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot != NO_SLOT && _didTargetChooseSwitch(engine, battleKey, targetSlot)) {
            // Deal damage to the opposing mon
            AttackCalculator._calculateDamage(
                engine,
                TYPE_CALCULATOR,
                battleKey,
                attackerPlayerIndex,
                targetBits,
                OPPONENT_BASE_POWER,
                DEFAULT_ACCURACY,
                DEFAULT_VOL,
                moveType(engine, battleKey),
                moveClass(engine, battleKey),
                rng,
                DEFAULT_CRIT_RATE
            );
        } else {
            // Deal damage to ourselves
            (int32 selfDamage,) = AttackCalculator._calculateDamageView(
                engine,
                TYPE_CALCULATOR,
                battleKey,
                attackerPlayerIndex,
                attackerPlayerIndex,
                SELF_DAMAGE_BASE_POWER,
                DEFAULT_ACCURACY,
                DEFAULT_VOL,
                moveType(engine, battleKey),
                moveClass(engine, battleKey),
                rng,
                DEFAULT_CRIT_RATE
            );
            engine.dealDamage(attackerPlayerIndex, attackerMonIndex, selfDamage);
        }
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 3;
    }

    /// @dev priority() has no target context, so the punisher stance arms off EITHER opposing
    ///      slot committing a switch; move() still requires the TARGETED slot to be switching
    ///      for the punish branch (else the usual self-hit).
    function _didAnyOpponentChooseSwitch(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex)
        internal
        view
        returns (bool)
    {
        uint256 opp = (attackerPlayerIndex + 1) % 2;
        if ((engine.getMoveDecisionForSlot(battleKey, opp, 0).packedMoveIndex & MOVE_INDEX_MASK) == SWITCH_MOVE_INDEX) {
            return true;
        }
        return (engine.getMoveDecisionForSlot(battleKey, opp, 1).packedMoveIndex & MOVE_INDEX_MASK) == SWITCH_MOVE_INDEX;
    }

    function priority(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex) public view returns (uint32) {
        if (_didAnyOpponentChooseSwitch(engine, battleKey, attackerPlayerIndex)) {
            return uint32(SWITCH_PRIORITY) + 1;
        } else {
            return DEFAULT_PRIORITY;
        }
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Earth;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        view
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}
