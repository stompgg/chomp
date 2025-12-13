// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

// Move index uses 7 bits (0-127), with upper bit of uint8 reserved for isRealTurn flag
// Special move indices (not shifted):
// 126 = 2^7 - 2, 125 = 2^7 - 3
uint8 constant NO_OP_MOVE_INDEX = 126;
uint8 constant SWITCH_MOVE_INDEX = 125;

// Regular move indices (0-3) are stored +1 to avoid zero-value ambiguity:
// Stored 0 = "no move set", Stored 1 = move 0, Stored 2 = move 1, etc.
// When storing: if moveIndex < SWITCH_MOVE_INDEX, store moveIndex + 1
// When reading: if storedIndex < SWITCH_MOVE_INDEX, return storedIndex - 1
uint8 constant MOVE_INDEX_OFFSET = 1;

// Bit mask and shift for packed move index (lower 7 bits = moveIndex, bit 7 = isRealTurn)
uint8 constant MOVE_INDEX_MASK = 0x7F;
uint8 constant IS_REAL_TURN_BIT = 0x80;

uint256 constant SWITCH_PRIORITY = 6;
uint32 constant DEFAULT_PRIORITY = 3;
uint32 constant DEFAULT_STAMINA = 5;

uint32 constant CRIT_NUM = 3;
uint32 constant CRIT_DENOM = 2;
uint32 constant DEFAULT_CRIT_RATE = 5;

uint32 constant DEFAULT_VOL = 10;
uint32 constant DEFAULT_ACCURACY = 100;

int32 constant CLEARED_MON_STATE_SENTINEL = type(int32).max - 1;

// Packed MonState with all deltas set to CLEARED_MON_STATE_SENTINEL and bools set to false
// Layout (LSB to MSB): hpDelta, staminaDelta, speedDelta, attackDelta, defenceDelta, specialAttackDelta, specialDefenceDelta, isKnockedOut, shouldSkipTurn
// 7 x 0x7FFFFFFE (int32.max - 1) + 2 x 0x00 (false)
uint256 constant PACKED_CLEARED_MON_STATE = 0x00007FFFFFFE7FFFFFFE7FFFFFFE7FFFFFFE7FFFFFFE7FFFFFFE7FFFFFFE;

uint8 constant PLAYER_EFFECT_BITS = 6;
uint8 constant MAX_EFFECTS_PER_MON = uint8(2 ** PLAYER_EFFECT_BITS) - 1; // 63
uint256 constant EFFECT_SLOTS_PER_MON = 64; // Stride for per-mon effect storage (2^6)
uint256 constant EFFECT_COUNT_MASK = 0x3F; // 6 bits = max count of 63

address constant TOMBSTONE_ADDRESS = address(0xdead);