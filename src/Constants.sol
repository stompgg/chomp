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

// Sentinel effect address used for inlined stat-boost entries. Boost sources are stored in the
// normal per-mon effect mappings under this address; the Engine recognizes it and runs the
// inlined stat-boost switch-out logic instead of making an external IEffect call (mirrors the
// address(0) StaminaRegen inline path). It is never a real deployed contract.
address constant STAT_BOOST_ADDRESS = address(0x57B); // "STB" - stat boost
// Steps bitmap stored on inlined stat-boost effect entries: ALWAYS_APPLIES | OnMonSwitchOut (bit 5).
// Matches the legacy StatBoosts.getStepsBitmap() (0x8020) so view/round-trip behavior is unchanged.
uint16 constant STAT_BOOST_STEPS = 0x8020;

// Sentinel ruleset address: when passed as battle.ruleset, the Engine adds
// inline StaminaRegen as a global effect without calling an external contract.
address constant INLINE_STAMINA_REGEN_RULESET = address(0x57A);  // "STA"mina

// Bit 15 of stepsBitmap: when set, Engine skips the external shouldApply() call
uint16 constant ALWAYS_APPLIES_BIT = 0x8000;

uint256 constant MAX_BATTLE_DURATION = 1 hours;

bytes32 constant MOVE_MISS_EVENT_TYPE = sha256(abi.encode("MoveMiss"));
bytes32 constant MOVE_CRIT_EVENT_TYPE = sha256(abi.encode("MoveCrit"));
bytes32 constant MOVE_TYPE_IMMUNITY_EVENT_TYPE = sha256(abi.encode("MoveTypeImmunity"));
bytes32 constant NONE_EVENT_TYPE = bytes32(0);

// Game configuration — shared between deploy scripts and transpiled frontend.
// These are passed as constructor args to Engine and DefaultValidator at deploy time.
// Prefixed with GAME_ to avoid shadowing Engine's immutable fields of the same name.
uint256 constant GAME_MONS_PER_TEAM = 4;
uint256 constant GAME_MOVES_PER_MON = 4;
uint256 constant GAME_TIMEOUT_DURATION = 30; // seconds

// Gacha point economy — mirrored in the transpiled frontend so copy/breakdowns
// can key off these values.
uint256 constant GACHA_ROLL_COST = 16;
uint256 constant GACHA_POINTS_PER_WIN = 2;
uint256 constant GACHA_POINTS_PER_LOSS = 1;
// One-shot bonus on a player's first ever battle. Matches ROLL_COST so a brand new
// player can always afford one paid roll after their first game (guaranteeing a 5th mon
// on top of the 4 from the starter + initial rolls).
uint256 constant GACHA_FIRST_GAME_EVER_BONUS = 16;

// Per-mon exp
uint256 constant EXP_PER_SURVIVING_MON = 2;
uint256 constant EXP_PER_KOD_MON = 1;

// Flat exp multiplier applied to every game's per-mon exp. Replaces the old
// game-type bonuses (hard-CPU difficulty was client-mutable and PvP/CPU no longer differ).
uint256 constant GAME_EXP_MULT = 2;

// First-game-of-the-day flat bonus that ratchets with a daily-login streak.
// Added to base reward *before* multipliers so it rides the game + quest mults.
// Streak resets to 1 once the gap since the last bonus exceeds STREAK_GRACE_WINDOW.
uint256 constant STREAK_FLAT_BONUS_MAX = 5;
uint256 constant STREAK_GRACE_WINDOW = 36 hours;

// Quest rewards — single multiplier applied to both gacha pts and exp.
uint256 constant QUEST_REWARD_MULT = 2;
uint256 constant MAX_PREDICATES_PER_QUEST = 6;
