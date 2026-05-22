// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Type, MonStateIndexName, StatBoostType, MoveClass, ExtraDataType} from "./Enums.sol";
import {IEngineHook} from "./IEngineHook.sol";
import {IRuleset} from "./IRuleset.sol";
import {IValidator} from "./IValidator.sol";
import {IEffect} from "./effects/IEffect.sol";
import {IMatchmaker} from "./matchmaker/IMatchmaker.sol";
import {IRandomnessOracle} from "./rng/IRandomnessOracle.sol";
import {ITeamRegistry} from "./game-layer/ITeamRegistry.sol";

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
}

// Used by CPU.startCustomBattle: bundles phantom team-config writes with battle start.
// p1 (= the CPU calling startCustomBattle) and p1TeamIndex (= uint16(uint160(p0)))
// are derived inside the CPU contract, so they're omitted here. p0TeamHash is
// unused in the phantom flow.
struct CustomBattleProposal {
    address p0;
    uint96 p0TeamIndex;
    uint256[] monIndices;
    uint8[] facetIds;
    ITeamRegistry teamRegistry;
    IValidator validator;
    IRandomnessOracle rngOracle;
    IRuleset ruleset;
    address moveManager;
    IMatchmaker matchmaker;
    IEngineHook[] engineHooks;
}

// Used by SignedMatchmaker
struct BattleOffer {
    Battle battle;
    uint256 pairHashNonce;
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
}

// Packed into 1 storage slot (8 + 16 = 24 bits)
// packedMoveIndex: lower 7 bits = moveIndex (0-127), bit 7 = isRealTurn (1 = real, 0 = not set)
struct MoveDecision {
    uint8 packedMoveIndex;
    uint16 extraData;
}

// Stored by the Engine, tracks immutable battle data and battle state.
// Slot 0 — IMMUTABLE during play (only written at startBattle):
//   p1 (160) + p0TeamIndex (16) + p1TeamIndex (16) = 192 bits used, 64 bits free.
// Slot 1 — every per-turn mutation goes here, so a single SSTORE per turn covers all of them:
//   p0 (160) + winnerIndex (8) + prevPlayerSwitchForTurnFlag (8) + playerSwitchForTurnFlag (8) +
//   activeMonIndex (16) + lastExecuteTimestamp (40) + turnId (16) = 256 bits exactly.
//
// Width trade-offs vs prior layout:
//   - `turnId` shrunk uint64 → uint16. 65,535 turns per battle is far above any realistic
//     game length (typical CHOMP games end in 5-30 turns; OPT_PLAN's worst case is in the
//     hundreds, not thousands).
//   - `lastExecuteTimestamp` shrunk uint48 → uint40. Year 36800 cap, plenty of headroom.
struct BattleData {
    address p1;
    uint16 p0TeamIndex;
    uint16 p1TeamIndex;
    address p0;
    uint8 winnerIndex; // 2 = uninitialized (no winner), 0 = p0 winner, 1 = p1 winner
    uint8 prevPlayerSwitchForTurnFlag;
    uint8 playerSwitchForTurnFlag;
    uint16 activeMonIndex; // Packed: lower 8 bits = player0, upper 8 bits = player1
    uint40 lastExecuteTimestamp; // Written at end of every execute() — packed with turnId in slot 1.
    uint16 turnId;
}

// Stored by the Engine for a battle, is overwritten after a battle is over
struct BattleConfig {
    IValidator validator;
    uint96 packedP0EffectsCount; // 6 (PLAYER_EFFECT_BITS) bits for up to 16 mons for p0
    IRandomnessOracle rngOracle;
    uint96 packedP1EffectsCount;
    // Slot 2 — 256 bits exactly:
    address moveManager; // 160 — privileged role that can set moves for players outside of execute() call
    uint8 globalEffectsLength; //   8
    uint8 teamSizes; //   8 — Packed: lower 4 bits = p0 team size, upper 4 bits = p1 team size
    uint8 engineHooksLength; //   8
    uint16 koBitmaps; //  16 — Packed: lower 8 bits = p0 KO bitmap, upper 8 bits = p1 KO bitmap
    uint40 startTimestamp; //  40 — battle start time; overflows in year ~36825 (shrunk from uint48 for slot-2 packing)
    bool hasInlineStaminaRegen; //   8
    uint8 globalKVCount; //   8 — live entry count in the current battle's globalKV key buffer
    uint104 p0Salt;
    uint104 p1Salt;
    MoveDecision p0Move;
    MoveDecision p1Move;
    // Stored at startBattle so Engine.getBattle can passthrough to level/exp/facet getters.
    ITeamRegistry teamRegistry;
    mapping(uint256 index => Mon) p0Team;
    mapping(uint256 index => Mon) p1Team;
    mapping(uint256 index => MonState) p0States;
    mapping(uint256 index => MonState) p1States;
    mapping(uint256 => EffectInstance) globalEffects;
    mapping(uint256 => EffectInstance) p0Effects;
    mapping(uint256 => EffectInstance) p1Effects;
    mapping(uint256 => EngineHookInstance) engineHooks;
}

struct EffectInstance {
    IEffect effect;       // 160 bits
    uint16 stepsBitmap;   // 16 bits - packs with effect in slot 0 (bit i = runs at EffectStep(i))
    // 80 bits unused in slot 0
    bytes32 data;         // 256 bits in slot 1
}

struct EngineHookInstance {
    IEngineHook hook;     // 160 bits (packed with stepsBitmap in slot 0)
    uint16 stepsBitmap;   // 16 bits - packs with hook in slot 0 (bit i = runs at EngineHookStep(i))
    // 80 bits unused in slot 0
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
    uint40 startTimestamp; // Needed client-side for the getGlobalKV freshness gate
    uint104 p0Salt;
    uint104 p1Salt;
    uint16 p0TeamIndex;
    uint16 p1TeamIndex;
    MoveDecision p0Move;
    MoveDecision p1Move;
    EffectInstance[] globalEffects;
    EffectInstance[][] p0Effects; // Returns effects per mon in team
    EffectInstance[][] p1Effects;
    Mon[][] teams;
    MonState[][] monStates;
    GlobalKVEntry[] globalKVEntries; // Live globalKV entries for the current battle
    TeamLevelInfo p0Levels;
    TeamLevelInfo p1Levels;
}

// Three parallel arrays of length MONS_PER_TEAM, indexed identically.
struct TeamLevelInfo {
    uint256[] monIds;
    uint256[] exp;
    uint256[] levels;
}

// Per-mon stat adjustment from an active Facet. Engine applies deltas after the validator
// runs against base stats.
struct StatDelta {
    int16 hp;
    int16 atk;
    int16 spAtk;
    int16 def;
    int16 spDef;
    int16 speed;
}

// Returned in BattleConfigView.globalKVEntries; value is packed [timestamp << 192 | value].
struct GlobalKVEntry {
    uint64 key;
    bytes32 value;
}

// Stored by the Engine for a battle, tracks mutable battle data
struct BattleState {
    uint8 winnerIndex; // 2 = uninitialized (no winner), 0 = p0 winner, 1 = p1 winner
    uint8 prevPlayerSwitchForTurnFlag;
    uint8 playerSwitchForTurnFlag;
    uint16 activeMonIndex; // Packed: lower 8 bits = player0, upper 8 bits = player1
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
    uint256 ability; // Lower 160 bits = address for external abilities, or packed inline data if upper bits set
    uint256[] moves; // Lower 160 bits = address for external moves, or packed inline data if upper bits set
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
    uint16 extraData;
    uint104 salt;
}

// Per-turn submission accepted by `SignedCommitManager.submitTurnMoves`. The on-chain buffer
// stores the packed (p0, p1) projection of this struct in a single 256-bit slot; (committer,
// revealer) → (p0, p1) mapping happens at submission time based on `turnId % 2`.
struct TurnSubmission {
    uint64 turnId;
    // Committer preimage. The committer (msg.sender at submission time) reveals the preimage
    // directly; their commitment is implicit in the act of submitting (only the committer
    // knows their secret preimage). No separate committer signature is needed because the
    // manager enforces `msg.sender == committer` at submission time.
    uint8 committerMoveIndex;
    uint16 committerExtraData;
    uint104 committerSalt;
    // Revealer preimage + signature. Revealer signs `DualSignedReveal` (committer hash +
    // revealer move data) off-chain; committer carries the sig into their submission.
    uint8 revealerMoveIndex;
    uint16 revealerExtraData;
    uint104 revealerSalt;
    bytes revealerSig;
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
    uint8 p0ActiveMonIndex;
    uint8 p1ActiveMonIndex;
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

// Batch context for move validation to reduce external calls (5+ -> 1)
struct ValidationContext {
    uint64 turnId;
    uint8 playerSwitchForTurnFlag;
    // Per-player data
    uint8 p0ActiveMonIndex;
    uint8 p1ActiveMonIndex;
    bool p0ActiveMonKnockedOut;
    bool p1ActiveMonKnockedOut;
    // Stamina info for move validation (for active mons)
    uint32 p0ActiveMonBaseStamina;
    int32 p0ActiveMonStaminaDelta;
    uint32 p1ActiveMonBaseStamina;
    int32 p1ActiveMonStaminaDelta;
}

// Bundled move metadata returned by IMoveSet.getMeta. Batches the five separate
// getters (moveType / moveClass / priority / stamina / basePower) + extraDataType into
// one staticcall. MoveSlotLib.decodeMeta handles both inline moves (pure bit ops) and
// external moves (one getMeta call) uniformly.
struct MoveMeta {
    Type moveType;
    MoveClass moveClass;
    ExtraDataType extraDataType;
    uint32 priority;
    uint32 stamina;
    uint32 basePower; // 0 for moves that don't deal damage
}

// Batch context for CPU move selection. The CPU is always p1 in this codebase,
// so `cpuActiveMon*` fields mirror p1's active mon state. Returned by Engine.getCPUContext.
//
// MoveMeta is intentionally NOT included here — only BetterCPU needs decoded metadata, and
// even BetterCPU doesn't need it on turn 0 / flag==0 paths. Putting it in the shared
// context would impose a ~10k always-paid allocation cost on every CPU turn for data
// that's only consumed on the flag==2 hot path. BetterCPU calls MoveSlotLib.decodeMeta
// itself once per turn on the paths that actually need it.
struct CPUContext {
    bytes32 battleKey;
    address p0;
    address p1;
    address validator;
    uint8 winnerIndex; // 2 = no winner
    uint8 playerSwitchForTurnFlag;
    uint64 turnId;
    uint8 p0ActiveMonIndex;
    uint8 p1ActiveMonIndex;
    uint8 p0TeamSize;
    uint8 p1TeamSize;
    uint8 p0KOBitmap;
    uint8 p1KOBitmap;
    uint32 cpuActiveMonBaseStamina;
    int32 cpuActiveMonStaminaDelta;
    bool cpuActiveMonKnockedOut;
    uint256[4] cpuActiveMonMoveSlots;
}

// Batched context for the registry's onBattleEnd hook — replaces the older split of
// getPlayersForBattle + getWinner + getKOBitmap×2.
struct BattleEndContext {
    address p0;
    address p1;
    address winner;          // address(0) = draw
    uint16 p0TeamIndex;
    uint16 p1TeamIndex;
    uint8 p0KOBitmap;
    uint8 p1KOBitmap;
    uint8 p0ActiveMonIndex;
    uint8 p1ActiveMonIndex;
    uint64 turnId;
}