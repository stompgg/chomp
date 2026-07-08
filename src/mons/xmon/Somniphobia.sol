// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT, DEFAULT_PRIORITY, NO_SLOT} from "../../Constants.sol";
import {MonStateIndexName, MoveClass, Type} from "../../Enums.sol";
import {MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract Somniphobia is IMoveSet, BasicEffect {
    uint256 public constant DURATION = 4;
    int32 public constant DAMAGE_DENOM = 8;

    // Global-coordinator data: [stack: bits 8-15 | remainingDuration: bits 0-7].
    // Per-mon-punisher data: this marker bit set (distinguishes the two roles, which share a contract).
    uint256 internal constant PUNISHER_MARKER = 1 << 255;

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Somniphobia";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
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

        (bool exists, uint256 effectIndex, bytes32 data) = engine.getEffectData(battleKey, 2, 2, address(this));
        if (exists) {
            // Bump the stack but keep the original countdown; the effect must fade before it resets.
            uint256 stack = ((uint256(data) >> 8) & 0xFF) + 1;
            engine.editEffect(2, effectIndex, bytes32((stack << 8) | (uint256(data) & 0xFF)));
        } else {
            engine.addEffect(2, attackerPlayerIndex, this, bytes32((uint256(1) << 8) | DURATION));
        }

        _applyPunisher(engine, battleKey, attackerPlayerIndex, attackerMonIndex);
        _applyPunisher(engine, battleKey, defenderPlayerIndex, defenderMonIndex);
    }

    function _applyPunisher(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) internal {
        (bool exists,,) = engine.getEffectData(battleKey, playerIndex, monIndex, address(this));
        if (!exists) {
            engine.addEffect(playerIndex, monIndex, this, bytes32(PUNISHER_MARKER));
        }
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

    // Steps: RoundEnd (0x04), OnMonSwitchIn (0x10), OnMonSwitchOut (0x20), OnUpdateMonState (0x100), ALWAYS_APPLIES (0x8000)
    function getStepsBitmap() external pure override returns (uint16) {
        return ALWAYS_APPLIES_BIT | 0x0134;
    }

    function onUpdateMonState(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 playerIndex,
        uint256 monIndex,
        uint256,
        MonStateIndexName stateVarIndex,
        int32 valueToAdd
    ) external override returns (bytes32, bool) {
        if (stateVarIndex == MonStateIndexName.Stamina && valueToAdd > 0) {
            (bool exists,, bytes32 data) = engine.getEffectData(battleKey, 2, 2, address(this));
            if (exists) {
                int32 stack = int32(uint32((uint256(data) >> 8) & 0xFF));
                uint32 maxHp = engine.getMonValueForBattle(battleKey, playerIndex, monIndex, MonStateIndexName.Hp);
                int32 damage = int32(uint32(maxHp)) / DAMAGE_DENOM * stack;
                if (damage > 0) {
                    engine.dealDamage(playerIndex, monIndex, damage);
                }
            }
        }
        return (extraData, false);
    }

    function onMonSwitchIn(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256
    ) external override returns (bytes32, bool) {
        // Global coordinator only: apply the punisher to the mon that just switched in.
        if (uint256(extraData) & PUNISHER_MARKER == 0) {
            _applyPunisher(engine, battleKey, targetIndex, monIndex);
        }
        return (extraData, false);
    }

    function onMonSwitchOut(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32, bool)
    {
        // Punisher clears with its mon; the global coordinator persists.
        return (extraData, uint256(extraData) & PUNISHER_MARKER != 0);
    }

    function onRoundEnd(IEngine engine, bytes32 battleKey, uint256, bytes32 extraData, uint256, uint256, uint256)
        external
        view
        override
        returns (bytes32, bool)
    {
        if (uint256(extraData) & PUNISHER_MARKER != 0) {
            // Punisher: drop self once the coordinator is gone.
            (bool exists,,) = engine.getEffectData(battleKey, 2, 2, address(this));
            return (extraData, !exists);
        }
        // Global coordinator: count down, preserving the stack.
        uint256 duration = uint256(extraData) & 0xFF;
        if (duration <= 1) {
            return (extraData, true);
        }
        return (bytes32((uint256(extraData) & 0xFF00) | (duration - 1)), false);
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
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
