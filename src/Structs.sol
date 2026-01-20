// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Type, MonStateIndexName, StatBoostType, GameMode} from "./Enums.sol";
import {IEngineHook} from "./IEngineHook.sol";
import {IRuleset} from "./IRuleset.sol";
import {IValidator} from "./IValidator.sol";
import {IAbility} from "./abilities/IAbility.sol";
import {IEffect} from "./effects/IEffect.sol";
import {IMatchmaker} from "./matchmaker/IMatchmaker.sol";
import {IMoveSet} from "./moves/IMoveSet.sol";
import {IRandomnessOracle} from "./rng/IRandomnessOracle.sol";
import {ITeamRegistry} from "./teams/ITeamRegistry.sol";

// Used by DefaultMatchmaker
struct ProposedBattle {
    address p0;
    uint96 p0TeamIndex;
    bytes32 p0TeamHash;
    address p1;
    uint96 p1TeamIndex;
    ITeamRegistry teamRegistry;
    IValidator validator;
    IRandomnessOracle rngOracle;
    IRuleset ruleset;
    address moveManager;
    IMatchmaker matchmaker;
    IEngineHook[] engineHooks;
    GameMode gameMode; // Singles or Doubles
}

// Used by Engine to initialize a battle's parameters
struct Battle {
    address p0;
    uint96 p0TeamIndex;
    address p1;
    uint96 p1TeamIndex;
    ITeamRegistry teamRegistry;
    IValidator validator;
    IRandomnessOracle rngOracle;
    IRuleset ruleset;
    address moveManager;
    IMatchmaker matchmaker;
    IEngineHook[] engineHooks;
    GameMode gameMode; // Singles or Doubles
}

// Packed into 1 storage slot (8 + 240 = 248 bits)
// packedMoveIndex: lower 7 bits = moveIndex (0-127), bit 7 = isRealTurn (1 = real, 0 = not set)
struct MoveDecision {
    uint8 packedMoveIndex;
    uint240 extraData;
}

// Stored by the Engine, tracks immutable battle data and battle state
struct BattleData {
    address p1;
    uint64 turnId;
    address p0;
    uint8 winnerIndex; // 2 = uninitialized (no winner), 0 = p0 winner, 1 = p1 winner
    uint8 prevPlayerSwitchForTurnFlag;
    uint8 playerSwitchForTurnFlag;
    // Packed active mon indices:
    // Singles: lower 8 bits = p0 active, upper 8 bits = p1 active
    // Doubles: 4 bits per slot (p0s0, p0s1, p1s0, p1s1)
    uint16 activeMonIndex;
    // Packed: lower 4 bits = per-slot switch flags, bit 4 = game mode (0=singles, 1=doubles)
    uint8 slotSwitchFlagsAndGameMode;
}

// Stored by the Engine for a battle, is overwritten after a battle is over
struct BattleConfig {
    IValidator validator;
    uint96 packedP0EffectsCount; // 6 (PLAYER_EFFECT_BITS) bits for up to 16 mons for p0
    IRandomnessOracle rngOracle;
    uint96 packedP1EffectsCount;
    address moveManager; // Privileged role that can set moves for players outside of execute() call
    uint8 globalEffectsLength;
    uint8 teamSizes; // Packed: lower 4 bits = p0 team size, upper 4 bits = p1 team size
    uint8 engineHooksLength;
    uint16 koBitmaps; // Packed: lower 8 bits = p0 KO bitmap, upper 8 bits = p1 KO bitmap (supports up to 8 mons per team)
    uint48 startTimestamp;
    bytes32 p0Salt;
    bytes32 p1Salt;
    MoveDecision p0Move; // Slot 0 move for p0 (singles: only move, doubles: first mon's move)
    MoveDecision p1Move; // Slot 0 move for p1
    MoveDecision p0Move2; // Slot 1 move for p0 (doubles only)
    MoveDecision p1Move2; // Slot 1 move for p1 (doubles only)
    mapping(uint256 index => Mon) p0Team;
    mapping(uint256 index => Mon) p1Team;
    mapping(uint256 index => MonState) p0States;
    mapping(uint256 index => MonState) p1States;
    mapping(uint256 => EffectInstance) globalEffects;
    mapping(uint256 => EffectInstance) p0Effects;
    mapping(uint256 => EffectInstance) p1Effects;
    mapping(uint256 => IEngineHook) engineHooks;
}

struct EffectInstance {
    IEffect effect;
    bytes32 data;
}

// View struct for getBattle - contains array instead of mapping for memory return
struct BattleConfigView {
    IValidator validator;
    IRandomnessOracle rngOracle;
    address moveManager;
    uint24 globalEffectsLength;
    uint96 packedP0EffectsCount; // 6 bits per mon (up to 16 mons)
    uint96 packedP1EffectsCount;
    uint8 teamSizes;
    bytes32 p0Salt;
    bytes32 p1Salt;
    MoveDecision p0Move;
    MoveDecision p1Move;
    MoveDecision p0Move2; // Doubles only
    MoveDecision p1Move2; // Doubles only
    EffectInstance[] globalEffects;
    EffectInstance[][] p0Effects; // Returns effects per mon in team
    EffectInstance[][] p1Effects;
    Mon[][] teams;
    MonState[][] monStates;
}

// Stored by the Engine for a battle, tracks mutable battle data
struct BattleState {
    uint8 winnerIndex; // 2 = uninitialized (no winner), 0 = p0 winner, 1 = p1 winner
    uint8 prevPlayerSwitchForTurnFlag;
    uint8 playerSwitchForTurnFlag;
    // Packed active mon indices (see BattleData for layout)
    uint16 activeMonIndex;
    // Packed: lower 4 bits = per-slot switch flags, bit 4 = game mode (0=singles, 1=doubles)
    uint8 slotSwitchFlagsAndGameMode;
    uint64 turnId;
}

struct MonStats {
    uint32 hp;
    uint32 stamina;
    uint32 speed;
    uint32 attack;
    uint32 defense;
    uint32 specialAttack;
    uint32 specialDefense;
    Type type1;
    Type type2;
}

struct Mon {
    MonStats stats;
    IAbility ability;
    IMoveSet[] moves;
}

struct MonState {
    int32 hpDelta;
    int32 staminaDelta;
    int32 speedDelta;
    int32 attackDelta;
    int32 defenceDelta;
    int32 specialAttackDelta;
    int32 specialDefenceDelta;
    bool isKnockedOut; // Is either 0 or 1
    bool shouldSkipTurn; // Used for effects to skip turn, or when moves become invalid (outside of user control)
}

// Used for Commit manager
struct PlayerDecisionData {
    uint16 numMovesRevealed;
    uint16 lastCommitmentTurnId;
    uint96 lastMoveTimestamp;
    bytes32 moveHash;
}

struct RevealedMove {
    uint8 moveIndex;
    uint240 extraData;
    bytes32 salt;
}

// Used for Doubles commit manager - reveals both slot moves at once
struct RevealedMovesPair {
    uint8 moveIndex0; // Slot 0 move index
    uint240 extraData0; // Slot 0 extra data (includes target)
    uint8 moveIndex1; // Slot 1 move index
    uint240 extraData1; // Slot 1 extra data (includes target)
    bytes32 salt; // Single salt for both moves
}

// Used for StatBoosts
struct StatBoostToApply {
    MonStateIndexName stat;
    uint8 boostPercent;
    StatBoostType boostType;
}

struct StatBoostUpdate {
    MonStateIndexName stat;
    uint32 oldStat;
    uint32 newStat;
}

// Batch context for external callers (e.g. DefaultValidator) to avoid multiple SLOADs
struct BattleContext {
    uint96 startTimestamp;
    address p0;
    address p1;
    uint8 winnerIndex; // 2 = uninitialized (no winner), 0 = p0 winner, 1 = p1 winner
    uint64 turnId;
    uint8 playerSwitchForTurnFlag;
    uint8 prevPlayerSwitchForTurnFlag;
    uint8 p0ActiveMonIndex0; // Slot 0 active mon for p0
    uint8 p1ActiveMonIndex0; // Slot 0 active mon for p1
    uint8 p0ActiveMonIndex1; // Slot 1 active mon for p0 (doubles only)
    uint8 p1ActiveMonIndex1; // Slot 1 active mon for p1 (doubles only)
    uint8 slotSwitchFlags; // Per-slot switch flags (doubles)
    GameMode gameMode;
    address validator;
    address moveManager;
}

// Lightweight context for commit manager (fewer SLOADs than BattleContext)
struct CommitContext {
    uint48 startTimestamp;
    address p0;
    address p1;
    uint8 winnerIndex;
    uint64 turnId;
    uint8 playerSwitchForTurnFlag;
    uint8 slotSwitchFlags; // Per-slot switch flags (doubles)
    GameMode gameMode;
    address validator;
}

// Batch context for damage calculation to reduce external calls (7 -> 1)
struct DamageCalcContext {
    uint8 attackerMonIndex;
    uint8 defenderMonIndex;
    // Attacker stats (base + delta for physical and special)
    uint32 attackerAttack;
    int32 attackerAttackDelta;
    uint32 attackerSpAtk;
    int32 attackerSpAtkDelta;
    // Defender stats (base + delta for physical and special)
    uint32 defenderDef;
    int32 defenderDefDelta;
    uint32 defenderSpDef;
    int32 defenderSpDefDelta;
    // Defender types for type effectiveness
    Type defenderType1;
    Type defenderType2;
}