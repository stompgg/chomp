// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT, DEFAULT_PRIORITY, EMPTY_ACTIVE_LANE} from "../../Constants.sol";
import {MonStateIndexName, MoveClass, Type} from "../../Enums.sol";
import {MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract Somniphobia is IMoveSet, BasicEffect {
    uint256 public constant DURATION = 4;
    int32 public constant DAMAGE_DENOM = 8;

    // Global-coordinator data: one independent 16-bit lane per caster side at bit offset side*16,
    // each [stack: bits 8-15 | remainingDuration: bits 0-7]; a side's cast punishes the other side.
    // Per-mon-punisher data: this marker bit set (distinguishes the two roles, which share a contract).
    uint256 internal constant PUNISHER_MARKER = 1 << 255;

    function _lane(bytes32 data, uint256 casterSide) internal pure returns (uint256) {
        return (uint256(data) >> (casterSide << 4)) & 0xFFFF;
    }

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Somniphobia";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256,
        uint256,
        uint256 activesPacked,
        uint16,
        uint256
    ) external {
        (bool exists, uint256 effectIndex, bytes32 data) = engine.getEffectData(battleKey, 2, 2, address(this));
        // Bump this side's stack but keep its countdown; an expired lane restarts fresh.
        uint256 lane = _lane(data, attackerPlayerIndex);
        lane = lane == 0 ? (uint256(1) << 8) | DURATION : lane + (1 << 8);
        uint256 shift = attackerPlayerIndex << 4;
        bytes32 updated = bytes32((uint256(data) & ~(uint256(0xFFFF) << shift)) | ((lane & 0xFFFF) << shift));
        if (exists) {
            engine.editEffect(2, effectIndex, updated);
        } else {
            engine.addEffect(2, 2, this, updated);
        }

        // Opponents only: never punish the caster's own team. Every on-field opposing mon is
        // tagged at cast — the coordinator's onMonSwitchIn only covers later arrivals.
        uint256 defenderPlayerIndex = attackerPlayerIndex ^ 1;
        for (uint256 slotIndex; slotIndex < 2; slotIndex++) {
            uint256 mon = TargetLib.activeAt(activesPacked, TargetLib.toAbsSlot(defenderPlayerIndex, slotIndex));
            if (mon != EMPTY_ACTIVE_LANE) {
                _applyPunisher(engine, battleKey, defenderPlayerIndex, mon);
            }
        }
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
            uint256 lane = exists ? _lane(data, playerIndex ^ 1) : 0;
            if (lane != 0) {
                int32 stack = int32(uint32(lane >> 8));
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
        // Coordinator only: tag an arrival when the opposing side's instance is live.
        if (uint256(extraData) & PUNISHER_MARKER == 0 && _lane(extraData, targetIndex ^ 1) != 0) {
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

    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256,
        uint256
    ) external view override returns (bytes32, bool) {
        if (uint256(extraData) & PUNISHER_MARKER != 0) {
            // Punisher: drop self once the opposing side's instance is gone.
            (bool exists,, bytes32 data) = engine.getEffectData(battleKey, 2, 2, address(this));
            return (extraData, !exists || _lane(data, targetIndex ^ 1) == 0);
        }
        // Global coordinator: count each side's lane down independently; drop once both expire.
        uint256 updated = uint256(extraData);
        for (uint256 side; side < 2; side++) {
            uint256 lane = _lane(extraData, side);
            if (lane != 0) {
                uint256 shift = side << 4;
                uint256 next = (lane & 0xFF) <= 1 ? 0 : lane - 1;
                updated = (updated & ~(uint256(0xFFFF) << shift)) | (next << shift);
            }
        }
        return (bytes32(updated), updated == 0);
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
