// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {BattleConfig, BattleData} from "../Structs.sol";

/// @notice Lazy memory frame for the persistent packed battle headers.
/// @dev Word indices 0..1 are BattleData; 2..7 are BattleConfig offsets 0..5; index 8 is
///      BattleConfig offset 18 (`playerEffectStepsByMon`). This prototype deliberately exposes
///      raw words: typed accessors can be generated once the routing experiment fixes the schema.
library PackedHeaderFrameLib {
    uint256 internal constant WORD_COUNT = 9;
    uint256 internal constant BATTLE_STATIC_WORD = 0;
    uint256 internal constant BATTLE_STATE_WORD = 1;

    uint256 private constant ADDRESS_MASK = type(uint160).max;
    uint256 private constant WINNER_SHIFT = 160;
    uint256 private constant SWITCH_FLAG_SHIFT = 168;
    uint256 private constant ACTIVE_MON_SHIFT = 176;
    uint256 private constant TIMESTAMP_SHIFT = 192;
    uint256 private constant TURN_ID_SHIFT = 232;
    uint256 private constant NUM_BUFFERED_SHIFT = 248;

    error HeaderWordOutOfBounds();
    error DirtyHeaderFrame();

    struct Frame {
        uint256 battleBaseSlot;
        uint256 configBaseSlot;
        uint256[WORD_COUNT] words;
        uint16 loadedMask;
        uint16 dirtyMask;
    }

    function init(BattleData storage battle, BattleConfig storage config)
        internal
        pure
        returns (Frame memory frame)
    {
        assembly ("memory-safe") {
            mstore(frame, battle.slot)
            mstore(add(frame, 0x20), config.slot)
        }
    }

    function read(Frame memory frame, uint256 wordIndex) internal view returns (uint256 value) {
        uint16 bit = _wordBit(wordIndex);
        if (frame.loadedMask & bit == 0) {
            value = _sload(_storageSlot(frame, wordIndex));
            frame.words[wordIndex] = value;
            frame.loadedMask |= bit;
        } else {
            value = frame.words[wordIndex];
        }
    }

    /// @notice Replace a complete packed word without paying a load first.
    function write(Frame memory frame, uint256 wordIndex, uint256 value) internal pure {
        uint16 bit = _wordBit(wordIndex);
        frame.words[wordIndex] = value;
        frame.loadedMask |= bit;
        frame.dirtyMask |= bit;
    }

    function p1(Frame memory frame) internal view returns (address) {
        return address(uint160(read(frame, BATTLE_STATIC_WORD)));
    }

    function p0(Frame memory frame) internal view returns (address) {
        return address(uint160(read(frame, BATTLE_STATE_WORD)));
    }

    function winnerIndex(Frame memory frame) internal view returns (uint8) {
        return uint8(read(frame, BATTLE_STATE_WORD) >> WINNER_SHIFT);
    }

    function playerSwitchForTurnFlag(Frame memory frame) internal view returns (uint8) {
        return uint8(read(frame, BATTLE_STATE_WORD) >> SWITCH_FLAG_SHIFT);
    }

    function activeMonIndex(Frame memory frame) internal view returns (uint16) {
        return uint16(read(frame, BATTLE_STATE_WORD) >> ACTIVE_MON_SHIFT);
    }

    function lastExecuteTimestamp(Frame memory frame) internal view returns (uint40) {
        return uint40(read(frame, BATTLE_STATE_WORD) >> TIMESTAMP_SHIFT);
    }

    function turnId(Frame memory frame) internal view returns (uint16) {
        return uint16(read(frame, BATTLE_STATE_WORD) >> TURN_ID_SHIFT);
    }

    function numBuffered(Frame memory frame) internal view returns (uint8) {
        return uint8(read(frame, BATTLE_STATE_WORD) >> NUM_BUFFERED_SHIFT);
    }

    function setWinnerIndex(Frame memory frame, uint8 value) internal view {
        _replaceBattleStateBits(frame, uint256(value), type(uint8).max, WINNER_SHIFT);
    }

    function setActiveMonIndex(Frame memory frame, uint16 value) internal view {
        _replaceBattleStateBits(frame, uint256(value), type(uint16).max, ACTIVE_MON_SHIFT);
    }

    /// @notice Apply the normal non-game-over end-of-turn BattleData transition in one word.
    function advanceTurn(Frame memory frame, uint8 switchFlag, uint40 timestamp) internal view {
        uint256 word = read(frame, BATTLE_STATE_WORD);
        uint16 nextTurnId = uint16(word >> TURN_ID_SHIFT) + 1;
        uint256 clearMask = ~(
            (uint256(type(uint8).max) << SWITCH_FLAG_SHIFT)
                | (uint256(type(uint40).max) << TIMESTAMP_SHIFT)
                | (uint256(type(uint16).max) << TURN_ID_SHIFT)
        );
        word = (word & clearMask) | (uint256(switchFlag) << SWITCH_FLAG_SHIFT)
            | (uint256(timestamp) << TIMESTAMP_SHIFT) | (uint256(nextTurnId) << TURN_ID_SHIFT);
        write(frame, BATTLE_STATE_WORD, word);
    }

    function flush(Frame memory frame) internal {
        uint16 dirty = frame.dirtyMask;
        while (dirty != 0) {
            uint256 wordIndex = _leastSignificantBitIndex(dirty);
            _sstore(_storageSlot(frame, wordIndex), frame.words[wordIndex]);
            dirty &= dirty - 1;
        }
        frame.dirtyMask = 0;
    }

    /// @notice Invalidate after a legacy mechanic returns. Dirty words must be flushed first.
    function invalidate(Frame memory frame) internal pure {
        if (frame.dirtyMask != 0) revert DirtyHeaderFrame();
        frame.loadedMask = 0;
    }

    function flushAndInvalidate(Frame memory frame) internal {
        flush(frame);
        frame.loadedMask = 0;
    }

    function _replaceBattleStateBits(Frame memory frame, uint256 value, uint256 valueMask, uint256 shift)
        private
        view
    {
        uint256 word = read(frame, BATTLE_STATE_WORD);
        uint256 shiftedMask = valueMask << shift;
        write(frame, BATTLE_STATE_WORD, (word & ~shiftedMask) | ((value & valueMask) << shift));
    }

    function _storageSlot(Frame memory frame, uint256 wordIndex) private pure returns (uint256 slot) {
        if (wordIndex < 2) return frame.battleBaseSlot + wordIndex;
        if (wordIndex < 8) return frame.configBaseSlot + wordIndex - 2;
        if (wordIndex == 8) return frame.configBaseSlot + 18;
        revert HeaderWordOutOfBounds();
    }

    function _wordBit(uint256 wordIndex) private pure returns (uint16 bit) {
        if (wordIndex >= WORD_COUNT) revert HeaderWordOutOfBounds();
        bit = uint16(1 << wordIndex);
    }

    function _leastSignificantBitIndex(uint16 value) private pure returns (uint256 index) {
        while (value & 1 == 0) {
            value >>= 1;
            index++;
        }
    }

    function _sload(uint256 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    function _sstore(uint256 slot, uint256 value) private {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }
}
