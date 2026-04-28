// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {NO_OP_MOVE_INDEX, DEFAULT_PRIORITY, MOVE_INDEX_MASK} from "../../Constants.sol";
import {ExtraDataType, MoveClass, Type} from "../../Enums.sol";
import { MoveDecision, MonStateIndexName, EffectInstance, MoveMeta } from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";

contract Somniphobia is IMoveSet, BasicEffect {
    uint256 public constant DURATION = 6;
    int32 public constant DAMAGE_DENOM = 8;

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Somniphobia";
    }

    function move(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256, uint256, uint16, uint256) external {
        // Add effect globally for 6 turns (only if it's not already in global effects)
        (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, 2, 2);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                return;
            }
        }
        engine.addEffect(2, attackerPlayerIndex, this, bytes32(DURATION));
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 1;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Cosmic;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
    }

    function isValidTarget(IEngine, bytes32, uint16) external pure returns (bool) {
        return true;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    // Steps: RoundEnd, AfterMove
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8084;
    }

    function onAfterMove(IEngine engine, bytes32 battleKey, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, uint256, uint256)
        external
        override
        returns (bytes32, bool)
    {
        MoveDecision memory moveDecision = engine.getMoveDecisionForBattleState(battleKey, targetIndex);

        // Unpack the move index from packedMoveIndex
        uint8 moveIndex = moveDecision.packedMoveIndex & MOVE_INDEX_MASK;

        // If this player rested (NO_OP), deal damage
        if (moveIndex == NO_OP_MOVE_INDEX) {
            uint32 maxHp = engine.getMonValueForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp);
            int32 damage = int32(uint32(maxHp)) / DAMAGE_DENOM;

            if (damage > 0) {
                engine.dealDamage(targetIndex, monIndex, damage);
            }
        }

        return (extraData, false);
    }

    function onRoundEnd(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256)
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
