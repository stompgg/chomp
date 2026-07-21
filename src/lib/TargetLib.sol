// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";

/// @notice Slot/target helpers shared by the Engine, moves, and effects.
/// Absolute slot id = side * 2 + slotIndex (0 = side0/slot0, 1 = side0/slot1,
/// 2 = side1/slot0, 3 = side1/slot1). `activesPacked` carries one 8-bit lane per
/// absolute slot holding that slot's active roster index (EMPTY_ACTIVE_LANE = no mon).
library TargetLib {
    uint256 internal constant HOOK_MOVE_LANES_SHIFT = 32;
    uint256 internal constant HOOK_ACTED_MASK_SHIFT = 128;

    function sideOf(uint256 absSlot) internal pure returns (uint256) {
        return absSlot >> 1;
    }

    function slotIndexOf(uint256 absSlot) internal pure returns (uint256) {
        return absSlot & 1;
    }

    function toAbsSlot(uint256 side, uint256 slotIndex) internal pure returns (uint256) {
        return (side << 1) | slotIndex;
    }

    function activeAt(uint256 activesPacked, uint256 absSlot) internal pure returns (uint256) {
        return (activesPacked >> (absSlot << 3)) & 0xFF;
    }

    function withLane(uint256 activesPacked, uint256 absSlot, uint256 monIndex) internal pure returns (uint256) {
        uint256 shift = absSlot << 3;
        return (activesPacked & ~(uint256(0xFF) << shift)) | (monIndex << shift);
    }

    /// @dev A side's slot-0 active — the singles-semantics read ("the side's active mon").
    function sideActive(uint256 activesPacked, uint256 side) internal pure returns (uint256) {
        return (activesPacked >> (side << 4)) & 0xFF;
    }

    /// @dev Build the singles actives word: lane 0 = p0 active, lane 2 = p1 active, slot-1 lanes empty.
    function singlesActives(uint256 p0ActiveMonIndex, uint256 p1ActiveMonIndex) internal pure returns (uint256) {
        return SINGLES_EMPTY_LANES | p0ActiveMonIndex | (p1ActiveMonIndex << 16);
    }

    /// @dev The implied singles target: the opposing side's slot-0 bit.
    function impliedSinglesTargetBits(uint256 attackerSide) internal pure returns (uint256) {
        return 1 << ((1 - attackerSide) << 1);
    }

    /// @dev The slot on `side` currently holding `monIndex`, or NO_SLOT if it is benched. Singles
    ///      always resolves to the side's slot 0.
    function slotOfMon(uint256 activesPacked, uint256 side, uint256 monIndex) internal pure returns (uint256) {
        uint256 s0 = side << 1;
        if (activeAt(activesPacked, s0) == monIndex) {
            return s0;
        }
        if (activeAt(activesPacked, s0 | 1) == monIndex) {
            return s0 | 1;
        }
        return NO_SLOT;
    }

    /// @notice Fresh 24-bit current-move lane embedded by Engine immediately before an
    ///         AfterMove callback: [extraData:16 | packedMoveIndex:8]. Other hook steps leave
    ///         these context lanes unset. The low 32 active-mon lanes remain ABI-compatible.
    function hookMoveWordAt(uint256 hookContext, uint256 absSlot) internal pure returns (uint256) {
        return (hookContext >> (HOOK_MOVE_LANES_SHIFT + absSlot * 24)) & 0xFFFFFF;
    }

    function hookSlotActed(uint256 hookContext, uint256 absSlot) internal pure returns (bool) {
        return ((hookContext >> (HOOK_ACTED_MASK_SHIFT + absSlot)) & 1) != 0;
    }

    /// @dev Kit-audit ruling for untargeted "the opposing active" effects (switch-in chips,
    ///      KO-triggered debuffs...): the mirror of `ownSlot` on the opposing side, falling back
    ///      to its partner when the mirror lane is empty; NO_SLOT when the opposing side is vacant.
    ///      Occupancy only — a KO'd occupant is still returned (damage/boosts on it no-op).
    function mirrorOpposingSlot(uint256 activesPacked, uint256 ownSlot) internal pure returns (uint256) {
        if (ownSlot == NO_SLOT) {
            return NO_SLOT; // benched owner: propagate rather than alias slot 6
        }
        uint256 mirror = ownSlot ^ 2;
        if (activeAt(activesPacked, mirror) != EMPTY_ACTIVE_LANE) {
            return mirror;
        }
        uint256 partner = mirror ^ 1;
        if (activeAt(activesPacked, partner) != EMPTY_ACTIVE_LANE) {
            return partner;
        }
        return NO_SLOT;
    }

    /// @dev Lowest set slot bit in targetBits (0-3); NO_SLOT if none. Single-target moves resolve
    ///      "the defender" through this.
    function lowestSlot(uint256 targetBits) internal pure returns (uint256) {
        if (targetBits & 1 != 0) {
            return 0;
        }
        if (targetBits & 2 != 0) {
            return 1;
        }
        if (targetBits & 4 != 0) {
            return 2;
        }
        if (targetBits & 8 != 0) {
            return 3;
        }
        return NO_SLOT;
    }
}
