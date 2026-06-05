// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Constants.sol";

import "./Enums.sol";
import "./Structs.sol";
import "./moves/IMoveSet.sol";

import {IEngine} from "./IEngine.sol";
import {IAbility} from "./abilities/IAbility.sol";
import {SignedCommitLib} from "./commit-manager/SignedCommitLib.sol";
import {ECDSA} from "./lib/ECDSA.sol";
import {EIP712} from "./lib/EIP712.sol";
import {MappingAllocator} from "./lib/MappingAllocator.sol";
import {StatBoostLib} from "./lib/StatBoostLib.sol";
import {StaminaRegenLogic} from "./lib/StaminaRegenLogic.sol";
import {ValidatorLogic} from "./lib/ValidatorLogic.sol";
import {IMatchmaker} from "./matchmaker/IMatchmaker.sol";
import {AttackCalculator} from "./moves/AttackCalculator.sol";
import {TypeCalcLib} from "./types/TypeCalcLib.sol";

contract Engine is IEngine, MappingAllocator, EIP712 {
    // Default validator config (immutable, for inline validation when validator is address(0))
    uint256 public immutable DEFAULT_MONS_PER_TEAM;
    uint256 public immutable DEFAULT_MOVES_PER_MON;

    bytes32 public transient battleKeyForWrite; // intended to be used during call stack by other contracts
    bytes32 private transient storageKeyForWrite; // cached storage key to avoid repeated lookups
    // Bitmap tracking which effect lists were modified (for caching effect counts)
    // Bit 0: global effects, Bits 1-8: P0 mons 0-7, Bits 9-16: P1 mons 0-7
    uint256 private transient effectsDirtyBitmap;
    mapping(bytes32 => uint256) public pairHashNonces; // imposes a global ordering across all matches
    mapping(address player => mapping(address maker => bool)) public isMatchmakerFor; // tracks approvals for matchmakers

    mapping(bytes32 => BattleData) private battleData; // These contain immutable data and battle state
    mapping(bytes32 => BattleConfig) private battleConfig; // These exist only throughout the lifecycle of a battle, we reuse these storage slots for subsequent battles
    mapping(bytes32 storageKey => mapping(uint64 => bytes32)) private globalKV; // Value layout: [64 bits timestamp | 192 bits value]
    // Packed key buffer: each slot holds four uint64 keys (lane 0 = bits [0..63], lane 1 = [64..127], etc.).
    // Paired with BattleConfig.globalKVCount to isolate the current battle's live entries from any leftover
    // lanes written by prior battles that shared this storageKey.
    mapping(bytes32 storageKey => mapping(uint256 slotIdx => uint256 packedKeys)) private globalKVKeySlots;
    // Built-in dual-signed buffer: per-turn packed (p0,p1) move projection, keyed by the recycled
    // storageKey (warm nz->nz SSTOREs across battles). Layout per slot matches the executeBatchedTurns
    // entry: [p0Move 8 | p0Extra 16 | p0Salt 104 | p1Move 8 | p1Extra 16 | p1Salt 104]. The live count
    // is BattleData.numBuffered; entries are only ever read in [turnId, turnId+numBuffered).
    mapping(bytes32 storageKey => mapping(uint64 turnId => uint256 packed)) private moveBuffer;
    uint256 public transient tempRNG; // Used to provide RNG during execute() tx
    uint256 private transient koOccurredFlag; // Set when a KO occurs, checked by _handleEffects/_handleMove
    int32 private transient tempPreDamage; // Running damage during PreDamage hook pipeline; mutated via setPreDamage
    // Current-turn move + salt data exposed to external effects (ZapStatus, SleepStatus, StaminaRegen, etc.).
    // Packed per player into ONE transient slot: [salt: bits 0-103 | encoded move: bits 104-127].
    // The encoded move is always nonzero when populated (it carries IS_REAL_TURN_BIT) and salt is only
    // ever written paired with it, so `packed != 0` is exactly the "transient is populated this call"
    // signal — and the salt read collapses from two transient loads to one.
    uint256 private transient _turnP0Packed;
    uint256 private transient _turnP1Packed;

    // Errors
    error NoWriteAllowed();
    error WrongCaller();
    error StatRequiresStatBoost();
    error MatchmakerNotAuthorized();
    error MatchmakerError();
    error MovesNotSet();
    error InvalidBattleConfig();
    error GameAlreadyOver();
    error GameStartsAndEndsSameBlock();
    error BattleNotStarted();
    error NotTwoPlayerTurn();
    error NotSinglePlayerTurn();
    // Built-in dual-signed buffer flow (BUILTIN_DUAL_SIGNED_MANAGER battles)
    error NotBuiltInManager();
    error NotCommitter();
    error InvalidSignature();
    error EmptyBuffer();

    // Events
    event BattleStart(bytes32 indexed battleKey, address p0, address p1);
    // packedMoves layout (per-lane sentinel: lane bytes all zero == player did not submit):
    //   bits   0-  7  p0 monIndex        (uint8)
    //   bits   8- 15  p0 packedMoveIndex (uint8, 0 = not submitted)
    //   bits  16- 31  p0 extraData       (uint16)
    //   bits  32- 39  p1 monIndex        (uint8)
    //   bits  40- 47  p1 packedMoveIndex (uint8, 0 = not submitted)
    //   bits  48- 63  p1 extraData       (uint16)
    // packedSalts layout:
    //   bits   0-103  p0 salt (uint104)
    //   bits 104-207  p1 salt (uint104)
    event MonMoves(bytes32 indexed battleKey, uint256 packedMoves, uint256 packedSalts);
    event EngineExecute(bytes32 indexed battleKey);
    event BattleComplete(bytes32 indexed battleKey, address winner);
    // CPU one-tx completion (executeBatchedTurns only): winner + every executed turn, for off-chain
    // replay. Replaces the plain BattleComplete on the CPU path (which emits no per-turn events, so this
    // carries the full move list). The built-in PvP drain does NOT use this — it announces moves via
    // MovesSubmitted at submit time and emits only a normal BattleComplete at game over. `payload` is a
    // single packed blob:
    //   bytes  0- 19 : winner address (20 bytes)
    //   bytes 20-  N : 19 bytes per executed turn, big-endian, the low 152 bits of each
    //                  engine turn-entry: [p0Move 8 | p0Extra 16 | p0Salt 104 | p1Move 8 | p1Extra 16]
    // The p1 (CPU) salt is dropped — always 0 on the batched (CPU) path. Moves are RAW indices
    // (consumer applies MOVE_INDEX_OFFSET, matching the MonMoves convention).
    event BattleCompleteWithBatchTurns(bytes32 indexed battleKey, bytes payload);
    // Emitted by the built-in dual-signed buffer flow when a turn is staged (submitTurnMoves) or
    // submitted-and-executed (submitTurnMovesAndExecute). Both players' moves are known at submit, so
    // the full per-turn move data is published here in real time and the drain emits NO per-turn events.
    // `packed` IS the buffer word — one compressed data word carrying both players' move index + extra
    // data + salt (turnId is the submission order, derivable from the event sequence):
    //   bits   0-  7 : p0 move index (raw — consumer applies MOVE_INDEX_OFFSET, matching MonMoves)
    //   bits   8- 23 : p0 extraData (uint16)
    //   bits  24-127 : p0 salt (uint104)
    //   bits 128-135 : p1 move index (raw)
    //   bits 136-151 : p1 extraData (uint16)
    //   bits 152-255 : p1 salt (uint104)
    event MovesSubmitted(bytes32 indexed battleKey, bytes32 packed);

    /// @notice Constructor to set default validator config for inline validation
    /// @dev When a battle's validator is address(0), Engine uses inline validation logic with these params
    /// @param _DEFAULT_MONS_PER_TEAM Default mons per team for inline validation
    /// @param _DEFAULT_MOVES_PER_MON Default moves per mon for inline validation
    constructor(uint256 _DEFAULT_MONS_PER_TEAM, uint256 _DEFAULT_MOVES_PER_MON) {
        DEFAULT_MONS_PER_TEAM = _DEFAULT_MONS_PER_TEAM;
        DEFAULT_MOVES_PER_MON = _DEFAULT_MOVES_PER_MON;
    }

    /// @inheritdoc EIP712
    /// @dev Domain for the built-in dual-signed buffer flow. NOTE: this differs from
    ///      SignedCommitManager's domain, so signatures for the built-in flow must target the Engine
    ///      address (off-chain signers in belch/munch re-target here).
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "ChompEngine";
        version = "1";
    }

    function updateMatchmakers(address[] memory makersToAdd, address[] memory makersToRemove) external {
        for (uint256 i; i < makersToAdd.length;) {
            isMatchmakerFor[msg.sender][makersToAdd[i]] = true;
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < makersToRemove.length;) {
            isMatchmakerFor[msg.sender][makersToRemove[i]] = false;
            unchecked {
                ++i;
            }
        }
    }

    function startBattle(Battle memory battle) external {
        // Ensure that the matchmaker is authorized for both players
        IMatchmaker matchmaker = IMatchmaker(battle.matchmaker);
        if (!isMatchmakerFor[battle.p0][address(matchmaker)] || !isMatchmakerFor[battle.p1][address(matchmaker)]) {
            revert MatchmakerNotAuthorized();
        }

        // Compute battle key and update the nonce
        (bytes32 battleKey, bytes32 pairHash) = computeBattleKey(battle.p0, battle.p1);
        pairHashNonces[pairHash] += 1;

        // Ensure that the matchmaker validates the match for both players
        if (!matchmaker.validateMatch(battleKey, battle.p0, battle.p1)) {
            revert MatchmakerError();
        }

        // Get the storage key for the battle config (reusable)
        bytes32 battleConfigKey = _initializeStorageKey(battleKey);
        BattleConfig storage config = battleConfig[battleConfigKey];

        // Get previous team sizes to clear old mon states
        uint256 prevP0Size = config.teamSizes & 0x0F;
        uint256 prevP1Size = config.teamSizes >> 4;

        // Clear previous battle's mon states by setting non-zero values to sentinel
        // MonState packs into a single 256-bit slot (7 x int32 + 2 x bool = 240 bits)
        // We use assembly to read/write the entire slot in one operation
        for (uint256 j = 0; j < prevP0Size;) {
            MonState storage monState = config.p0States[j];
            assembly {
                let slot := monState.slot
                if sload(slot) {
                    sstore(slot, PACKED_CLEARED_MON_STATE)
                }
            }
            unchecked {
                ++j;
            }
        }
        for (uint256 j = 0; j < prevP1Size;) {
            MonState storage monState = config.p1States[j];
            assembly {
                let slot := monState.slot
                if sload(slot) {
                    sstore(slot, PACKED_CLEARED_MON_STATE)
                }
            }
            unchecked {
                ++j;
            }
        }

        // Store the battle config (update fields individually to preserve effects mapping slots)
        if (address(config.validator) != address(battle.validator)) {
            config.validator = battle.validator;
        }
        if (address(config.rngOracle) != address(battle.rngOracle)) {
            config.rngOracle = battle.rngOracle;
        }
        if (config.moveManager != battle.moveManager) {
            config.moveManager = battle.moveManager;
        }
        if (address(config.teamRegistry) != address(battle.teamRegistry)) {
            config.teamRegistry = battle.teamRegistry;
        }
        // Reset effects lengths and KO bitmaps to 0 for the new battle
        config.packedP0EffectsCount = 0;
        config.packedP1EffectsCount = 0;
        config.koBitmaps = 0;
        config.globalKVCount = 0;
        config.playerEffectStepsUnion = 0;

        // teamIndices narrowed from Battle.uint96; phantom-team writes truncate to match.
        battleData[battleKey] = BattleData({
            p0: battle.p0,
            p1: battle.p1,
            p0TeamIndex: uint16(battle.p0TeamIndex),
            p1TeamIndex: uint16(battle.p1TeamIndex),
            winnerIndex: 2, // Initialize to 2 (uninitialized/no winner)
            playerSwitchForTurnFlag: 2, // Set flag to be 2 which means both players act
            activeMonIndex: 0, // Defaults to 0 (both players start with mon index 0)
            turnId: 0,
            lastExecuteTimestamp: 0, // Fresh battleKey per battle, starts at 0
            numBuffered: 0 // Built-in dual-signed buffer starts empty (auto-resets each battle here)
        });

        // Set the team for p0 and p1 in the reusable config storage
        (Mon[] memory p0Team, Mon[] memory p1Team) =
            battle.teamRegistry.getTeams(battle.p0, battle.p0TeamIndex, battle.p1, battle.p1TeamIndex);

        // Store actual team sizes (packed: lower 4 bits = p0, upper 4 bits = p1)
        uint256 p0Len = p0Team.length;
        uint256 p1Len = p1Team.length;
        config.teamSizes = uint8(p0Len) | (uint8(p1Len) << 4);

        // Store teams in mappings
        for (uint256 j = 0; j < p0Len;) {
            config.p0Team[j] = p0Team[j];
            unchecked {
                ++j;
            }
        }
        for (uint256 j = 0; j < p1Len;) {
            config.p1Team[j] = p1Team[j];
            unchecked {
                ++j;
            }
        }

        // Set the global effects and data to start the game if any
        if (address(battle.ruleset) == INLINE_STAMINA_REGEN_RULESET) {
            config.hasInlineStaminaRegen = true;
            config.globalEffectsLength = 0;
        } else if (address(battle.ruleset) != address(0)) {
            (IEffect[] memory effects, bytes32[] memory data) = battle.ruleset.getInitialGlobalEffects();
            uint256 numEffects = effects.length;
            if (numEffects > 0) {
                for (uint256 i = 0; i < numEffects;) {
                    config.globalEffects[i].effect = effects[i];
                    if (address(effects[i]) == address(0)) {
                        config.globalEffects[i].stepsBitmap = 0x8084;
                    } else {
                        config.globalEffects[i].stepsBitmap = effects[i].getStepsBitmap();
                    }
                    config.globalEffects[i].data = data[i];
                    unchecked {
                        ++i;
                    }
                }
                config.globalEffectsLength = uint8(effects.length);
            }
        } else {
            config.globalEffectsLength = 0;
        }

        // Set the engine hooks to start the game if any
        uint256 numHooks = battle.engineHooks.length;
        if (numHooks > 0) {
            for (uint256 i; i < numHooks;) {
                IEngineHook hook = battle.engineHooks[i];
                config.engineHooks[i].hook = hook;
                config.engineHooks[i].stepsBitmap = hook.getStepsBitmap();
                unchecked {
                    ++i;
                }
            }
            config.engineHooksLength = uint8(numHooks);
        } else {
            config.engineHooksLength = 0;
        }

        // Set start timestamp
        config.startTimestamp = uint40(block.timestamp);

        // Build teams array for validation
        Mon[][] memory teams = new Mon[][](2);
        teams[0] = p0Team;
        teams[1] = p1Team;

        // Validate the battle config (skip if using inline validation)
        if (address(battle.validator) != address(0)) {
            if (!battle.validator
                    .validateGameStart(
                        battle.p0, battle.p1, teams, battle.teamRegistry, battle.p0TeamIndex, battle.p1TeamIndex
                    )) {
                revert InvalidBattleConfig();
            }
        }
        // NOTE: in case where we do inline validation, we currently skip the game start validation logic
        // (we'll fix this in a later version)

        for (uint256 i = 0; i < numHooks;) {
            if ((config.engineHooks[i].stepsBitmap & (1 << uint8(EngineHookStep.OnBattleStart))) != 0) {
                config.engineHooks[i].hook.onBattleStart(battleKey);
            }
            unchecked {
                ++i;
            }
        }

        emit BattleStart(battleKey, battle.p0, battle.p1);
    }

    // THE IMPORTANT FUNCTION
    function execute(bytes32 battleKey) external returns (address winner) {
        // Cache storage key in transient storage for the duration of the call
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;

        BattleConfig storage config = battleConfig[storageKey];

        // Check that at least one move has been set (isRealTurn is stored in bit 7 of packedMoveIndex)
        if (
            (config.p0Move.packedMoveIndex & IS_REAL_TURN_BIT) == 0
                && (config.p1Move.packedMoveIndex & IS_REAL_TURN_BIT) == 0
        ) {
            revert MovesNotSet();
        }

        // EngineExecute is a per-tx "a turn executed" ping (legacy = one turn per tx). The batched
        // drain runs many turns in one tx, so it emits MonMoves per turn but not this — hence it lives
        // here at the entrypoint, not inside the per-turn _executeInternal body.
        winner = _executeInternal(battleKey, storageKey, true, true);
        emit EngineExecute(battleKey);
    }

    /// @notice Combined setMove + setMove + execute for gas optimization
    /// @dev Only callable by moveManager. Sets both moves and executes in one call.
    /// Writes move/salt data to transient storage instead of the per-battle storage slots.
    /// _executeInternal reads from transient when populated and skips the mirror, and
    /// `setMove` during execute also targets transient.
    function executeWithMoves(
        bytes32 battleKey,
        uint8 p0MoveIndex,
        uint104 p0Salt,
        uint16 p0ExtraData,
        uint8 p1MoveIndex,
        uint104 p1Salt,
        uint16 p1ExtraData
    ) external returns (address winner) {
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;

        BattleConfig storage config = battleConfig[storageKey];

        if (msg.sender != config.moveManager) {
            revert WrongCaller();
        }

        // Populate transient directly. _executeInternal sees non-zero _turnP0Packed and skips the
        // mirror-from-storage step. No SSTORE happens; transient auto-clears at tx end in prod.
        uint8 p0StoredMoveIndex = p0MoveIndex < SWITCH_MOVE_INDEX ? p0MoveIndex + MOVE_INDEX_OFFSET : p0MoveIndex;
        uint8 p1StoredMoveIndex = p1MoveIndex < SWITCH_MOVE_INDEX ? p1MoveIndex + MOVE_INDEX_OFFSET : p1MoveIndex;
        _turnP0Packed =
            _packTurn((uint256(p0StoredMoveIndex) | uint256(IS_REAL_TURN_BIT)) | (uint256(p0ExtraData) << 8), p0Salt);
        _turnP1Packed =
            _packTurn((uint256(p1StoredMoveIndex) | uint256(IS_REAL_TURN_BIT)) | (uint256(p1ExtraData) << 8), p1Salt);

        winner = _executeInternal(battleKey, storageKey, true, true);
        emit EngineExecute(battleKey);
    }

    /// @notice Combined single-player setMove + execute for forced switch turns
    /// @dev Only callable by moveManager. The acting player is inferred from battle.playerSwitchForTurnFlag.
    function executeWithSingleMove(bytes32 battleKey, uint8 moveIndex, uint104 salt, uint16 extraData)
        external
        returns (address winner)
    {
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;

        BattleConfig storage config = battleConfig[storageKey];

        if (msg.sender != config.moveManager) {
            revert WrongCaller();
        }

        BattleData storage battle = battleData[battleKey];
        uint256 playerIndex = battle.playerSwitchForTurnFlag;
        if (playerIndex > 1) {
            revert NotSinglePlayerTurn();
        }

        uint8 storedMoveIndex = moveIndex < SWITCH_MOVE_INDEX ? moveIndex + MOVE_INDEX_OFFSET : moveIndex;
        uint256 encoded = (uint256(storedMoveIndex) | uint256(IS_REAL_TURN_BIT)) | (uint256(extraData) << 8);
        if (playerIndex == 0) {
            _turnP0Packed = _packTurn(encoded, salt);
        } else {
            _turnP1Packed = _packTurn(encoded, salt);
        }

        winner = _executeInternal(battleKey, storageKey, true, true);
        emit EngineExecute(battleKey);
    }

    function executeBatchedTurns(bytes32 battleKey, uint256[] calldata entries)
        external
        returns (uint64 executed, address winner)
    {
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;
        BattleConfig storage config = battleConfig[storageKey];
        if (msg.sender != config.moveManager) {
            revert WrongCaller();
        }

        for (uint256 i = 0; i < entries.length; i++) {
            uint256 entry = entries[i];
            uint8 p0Move = uint8(entry);
            uint16 p0Extra = uint16(entry >> 8);
            uint104 p0Salt = uint104(entry >> 24);
            uint8 p1Move = uint8(entry >> 128);
            uint16 p1Extra = uint16(entry >> 136);
            uint104 p1Salt = uint104(entry >> 152);

            // Live flag read (direct storage, warm after the first sub-turn).
            uint8 flag = battleData[battleKey].playerSwitchForTurnFlag;
            if (flag == 2) {
                uint8 p0Stored = p0Move < SWITCH_MOVE_INDEX ? p0Move + MOVE_INDEX_OFFSET : p0Move;
                uint8 p1Stored = p1Move < SWITCH_MOVE_INDEX ? p1Move + MOVE_INDEX_OFFSET : p1Move;
                _turnP0Packed = _packTurn((uint256(p0Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p0Extra) << 8), p0Salt);
                _turnP1Packed = _packTurn((uint256(p1Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p1Extra) << 8), p1Salt);
            } else if (flag == 0) {
                uint8 p0Stored = p0Move < SWITCH_MOVE_INDEX ? p0Move + MOVE_INDEX_OFFSET : p0Move;
                _turnP0Packed = _packTurn((uint256(p0Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p0Extra) << 8), p0Salt);
            } else {
                uint8 p1Stored = p1Move < SWITCH_MOVE_INDEX ? p1Move + MOVE_INDEX_OFFSET : p1Move;
                _turnP1Packed = _packTurn((uint256(p1Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p1Extra) << 8), p1Salt);
            }

            winner = _executeInternal(battleKey, storageKey, false, false);
            executed++;
            if (winner != address(0)) {
                break;
            }

            // Reset per-turn transients so the next sub-turn starts like a fresh legacy tx. Kept inline
            // here (rather than calling _resetBatchedTurnTransients, which _drainBuffer uses) for the
            // same inliner reason this whole loop body is inlined — see the _executeBatchedEntry note.
            _turnP0Packed = 0;
            _turnP1Packed = 0;
            tempRNG = 0;
            koOccurredFlag = 0;
            tempPreDamage = 0;
            effectsDirtyBitmap = 0;
        }
        // The batched flow emits NO per-turn events (each sub-turn passes emitEvents=false to
        // _executeInternal: no EngineExecute, no MonMoves, and BattleComplete is suppressed in
        // _handleGameOver). Instead, when the game concluded this batch, emit ONE
        // BattleCompleteWithBatchTurns carrying the winner + every executed turn so off-chain
        // indexers get the full replay from a single Engine log (no per-CPU-address subscription).
        // Each turn is the low 152 bits of its entry — the p1 (CPU) salt is always 0 here, so it's
        // dropped — packed big-endian as 19 bytes via bytes19(bytes32(entry << 104)).
        if (winner != address(0)) {
            emit BattleCompleteWithBatchTurns(battleKey, _packBatchPayload(entries, executed, winner));
        }
    }

    /// @dev Packs the BattleCompleteWithBatchTurns payload: [winner 20B | 19B/turn ...]. Each turn is
    ///      the low 152 bits of its entry (p1/CPU salt is always 0 on the batched path, so dropped) —
    ///      `entry << 104` lands those 152 bits in the leading 19 bytes of the stored word. Single
    ///      pre-sized buffer (O(n); encodePacked-accumulate would reallocate+copy each turn -> O(n^2)).
    ///      Allocated with +13 slack so the final 32-byte mstore can never write past the buffer, then
    ///      the real length is set — keeps the block memory-safe.
    function _packBatchPayload(uint256[] calldata entries, uint256 numTurns, address winner)
        private
        pure
        returns (bytes memory payload)
    {
        uint256 len = 20 + numTurns * 19;
        payload = new bytes(len + 13);
        assembly ("memory-safe") {
            let ptr := add(payload, 32)
            mstore(ptr, shl(96, winner)) // winner address in the leading 20 bytes
            ptr := add(ptr, 20)
            let src := entries.offset
            for { let i := 0 } lt(i, numTurns) { i := add(i, 1) } {
                mstore(ptr, shl(104, calldataload(add(src, mul(i, 0x20)))))
                ptr := add(ptr, 19)
            }
            mstore(payload, len) // drop the 13 slack bytes from the visible length
        }
    }

    /// @dev Executes one buffered turn for the built-in PvP drain: flag-dispatch the packed entry into the
    ///      current-turn transients (the non-acting half on a single-player turn is ignored), then
    ///      _executeInternal with (emitMonMoves=false, emitBattleComplete=true). The drain emits NO
    ///      per-turn events — each move was already announced by MovesSubmitted at submit time — only a
    ///      normal BattleComplete at game over. (No per-tx EngineExecute either: the whole drain is one tx;
    ///      EngineExecute is emitted once per legacy execute() tx at the entrypoint.) Single call site
    ///      (_drainBuffer) so the optimizer inlines it. NOTE: executeBatchedTurns (the CPU one-tx path)
    ///      keeps its own inlined copy of this loop body with (false, false) on purpose — CPU has one
    ///      actor, so a single BattleCompleteWithBatchTurns is the right log there, and extracting a
    ///      2-call-site helper stopped the inliner and added ~1M gas across a real replay.
    function _executeBatchedEntry(bytes32 battleKey, bytes32 storageKey, uint256 entry)
        internal
        returns (address winner)
    {
        uint8 p0Move = uint8(entry);
        uint16 p0Extra = uint16(entry >> 8);
        uint104 p0Salt = uint104(entry >> 24);
        uint8 p1Move = uint8(entry >> 128);
        uint16 p1Extra = uint16(entry >> 136);
        uint104 p1Salt = uint104(entry >> 152);

        // Live flag read (direct storage, warm after the first sub-turn).
        uint8 flag = battleData[battleKey].playerSwitchForTurnFlag;
        if (flag == 2) {
            uint8 p0Stored = p0Move < SWITCH_MOVE_INDEX ? p0Move + MOVE_INDEX_OFFSET : p0Move;
            uint8 p1Stored = p1Move < SWITCH_MOVE_INDEX ? p1Move + MOVE_INDEX_OFFSET : p1Move;
            _turnP0Packed = _packTurn((uint256(p0Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p0Extra) << 8), p0Salt);
            _turnP1Packed = _packTurn((uint256(p1Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p1Extra) << 8), p1Salt);
        } else if (flag == 0) {
            uint8 p0Stored = p0Move < SWITCH_MOVE_INDEX ? p0Move + MOVE_INDEX_OFFSET : p0Move;
            _turnP0Packed = _packTurn((uint256(p0Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p0Extra) << 8), p0Salt);
        } else {
            uint8 p1Stored = p1Move < SWITCH_MOVE_INDEX ? p1Move + MOVE_INDEX_OFFSET : p1Move;
            _turnP1Packed = _packTurn((uint256(p1Stored) | uint256(IS_REAL_TURN_BIT)) | (uint256(p1Extra) << 8), p1Salt);
        }

        return _executeInternal(battleKey, storageKey, false, true);
    }

    /// @dev Reset per-turn transients between batched sub-turns so the next starts like a fresh tx.
    function _resetBatchedTurnTransients() internal {
        _turnP0Packed = 0;
        _turnP1Packed = 0;
        tempRNG = 0;
        koOccurredFlag = 0;
        tempPreDamage = 0;
        effectsDirtyBitmap = 0;
    }

    // ---------------------------------------------------------------------
    // Built-in dual-signed buffer flow (BUILTIN_DUAL_SIGNED_MANAGER battles)
    // ---------------------------------------------------------------------

    /// @notice Stage one per-turn dual-signed submission into the Engine's buffer (no execution).
    /// @dev SINGLE-SIG: the committer is msg.sender (no committer signature); the revealer's EIP-712
    ///      signature pins the committer's move hash, so the committer can't change their move and
    ///      can't be impersonated. Requires the battle to use the built-in flow (moveManager sentinel).
    function submitTurnMoves(bytes32 battleKey, uint256 packedMoves, bytes32 r, bytes32 vs) external {
        (bytes32 storageKey, uint256 packed, uint64 turnId, BattleData storage data) =
            _validateAndPackTurn(battleKey, packedMoves, r, vs);
        // Persist for a later drain (this turn executes in a separate tx).
        moveBuffer[storageKey][turnId] = packed;
        data.numBuffered = data.numBuffered + 1;
        // Announce the move now (the drain emits no per-turn events) — one compressed log carrying both
        // players' move indices + extra data + salts.
        emit MovesSubmitted(battleKey, bytes32(packed));
    }

    /// @notice Stage a submission and execute it (plus any earlier buffered turns) in the same tx.
    /// @dev The submitted entry executes in THIS tx, so it never needs to persist: validate it, drain
    ///      any previously-buffered turns from storage, then execute this entry straight from memory —
    ///      skipping the SSTORE + immediate SLOAD round-trip the buffer-then-drain path would pay for it.
    ///      For a 1-turn batch (no prior buffer) this touches `moveBuffer`/`numBuffered` zero times.
    function submitTurnMovesAndExecute(bytes32 battleKey, uint256 packedMoves, bytes32 r, bytes32 vs) external {
        (bytes32 storageKey, uint256 packed,,) = _validateAndPackTurn(battleKey, packedMoves, r, vs);
        // Announce this turn's moves (the drain emits no per-turn events), then drain + execute. Prior
        // buffered turns were already announced at their own submitTurnMoves.
        emit MovesSubmitted(battleKey, bytes32(packed));
        _drainBufferThenExecute(battleKey, storageKey, packed);
    }

    /// @notice Drain every currently buffered turn in one tx. Permissionless — entries were already
    ///         signature-validated at submit.
    function executeBuffered(bytes32 battleKey) external {
        _drainBuffer(battleKey, _getStorageKey(battleKey));
    }

    /// @dev Validate a dual-signed submission (built-in manager, game live, committer == msg.sender,
    ///      revealer EIP-2098 compact signature) and project it onto the packed (p0|p1) buffer-word
    ///      layout. VIEW — no state writes: the caller decides whether to buffer it (SSTORE) or execute
    ///      it now. Returns the resolved `data` pointer so the caller doesn't re-resolve the mapping.
    function _validateAndPackTurn(bytes32 battleKey, uint256 packedMoves, bytes32 r, bytes32 vs)
        internal
        view
        returns (bytes32 storageKey, uint256 packed, uint64 turnId, BattleData storage data)
    {
        storageKey = _getStorageKey(battleKey);
        if (battleConfig[storageKey].moveManager != BUILTIN_DUAL_SIGNED_MANAGER) {
            revert NotBuiltInManager();
        }
        data = battleData[battleKey];
        if (data.winnerIndex != 2) {
            revert GameAlreadyOver();
        }

        // turnId is NOT submitted — it's the next undrained turn (buffering doesn't execute, so the live
        // turnId is the executed count). The revealer's signature binds this exact id, so a stale or
        // out-of-order submission simply fails recovery below (no separate WrongTurnId check needed).
        turnId = data.turnId + data.numBuffered;

        (address committer, address revealer) = turnId % 2 == 0 ? (data.p0, data.p1) : (data.p1, data.p0);
        if (msg.sender != committer) {
            revert NotCommitter();
        }

        // Decode the committer/revealer halves from the single packed word.
        bytes32 committerMoveHash =
            keccak256(abi.encodePacked(uint8(packedMoves), uint104(packedMoves >> 24), uint16(packedMoves >> 8)));
        {
            SignedCommitLib.DualSignedReveal memory reveal = SignedCommitLib.DualSignedReveal({
                battleKey: battleKey,
                turnId: turnId,
                committerMoveHash: committerMoveHash,
                revealerMoveIndex: uint8(packedMoves >> 128),
                revealerSalt: uint104(packedMoves >> 152),
                revealerExtraData: uint16(packedMoves >> 136)
            });
            bytes32 digest = _hashTypedData(SignedCommitLib.hashDualSignedReveal(reveal));
            if (ECDSA.recover(digest, r, vs) != revealer) {
                revert InvalidSignature();
            }
        }

        // Project (committer, revealer) -> (p0, p1) for the buffer word. packedMoves already holds
        // committer in the low 128 bits, revealer in the high 128 — which IS the buffer (p0|p1) layout on
        // even turns (committer == p0). On odd turns (committer == p1) just swap the two halves.
        packed = turnId % 2 == 0 ? packedMoves : (packedMoves >> 128) | (packedMoves << 128);
    }

    function _drainBuffer(bytes32 battleKey, bytes32 storageKey)
        internal
        returns (uint64 executed, address winner)
    {
        BattleData storage data = battleData[battleKey];
        uint64 startTurn = data.turnId;
        uint256 numBuffered = data.numBuffered;
        if (numBuffered == 0) {
            revert EmptyBuffer();
        }

        storageKeyForWrite = storageKey;
        for (uint256 i = 0; i < numBuffered; i++) {
            // Execute directly off the buffer slot. Sub-turns emit no per-turn events (moves were
            // announced via MovesSubmitted at submit), so there's no end-of-drain batch payload to
            // assemble. BattleComplete is emitted by _handleGameOver on the winning turn.
            winner = _executeBatchedEntry(battleKey, storageKey, moveBuffer[storageKey][startTurn + uint64(i)]);
            executed++;
            if (winner != address(0)) {
                break;
            }
            _resetBatchedTurnTransients();
        }
        // Buffer consumed; turnId was advanced per executed turn by _executeInternal.
        data.numBuffered = 0;
    }

    /// @dev Drain any previously-buffered turns (from storage, in order) then execute `currentEntry`
    ///      straight from memory — it's the just-submitted turn that runs in this tx, so it never hits
    ///      storage (no SSTORE on submit, no SLOAD here). If the game ends while draining the prior
    ///      buffer, the current entry is NOT executed (the battle is already over).
    function _drainBufferThenExecute(bytes32 battleKey, bytes32 storageKey, uint256 currentEntry) internal {
        BattleData storage data = battleData[battleKey];
        uint64 startTurn = data.turnId;
        uint256 numBuffered = data.numBuffered;
        storageKeyForWrite = storageKey;

        for (uint256 i = 0; i < numBuffered; i++) {
            if (_executeBatchedEntry(battleKey, storageKey, moveBuffer[storageKey][startTurn + uint64(i)]) != address(0))
            {
                data.numBuffered = 0; // game ended mid-buffer; the current entry does not execute
                return;
            }
            _resetBatchedTurnTransients();
        }
        // Execute the just-submitted entry from memory — no buffer round-trip.
        _executeBatchedEntry(battleKey, storageKey, currentEntry);
        // Only touch numBuffered if there was a prior buffer to clear (1-turn batch leaves it at 0).
        if (numBuffered != 0) {
            data.numBuffered = 0;
        }
    }

    /// @notice One-call buffer reload: the executed-turn count plus every staged-but-undrained buffer
    ///         entry, in turn order — a client resuming mid-battle reads the whole pending buffer in one
    ///         eth_call (`numExecuted`, then `packedTurns`; `packedTurns.length` is the buffered count,
    ///         and `numExecuted + packedTurns.length` is the next turnId to submit). Each word is the
    ///         packed (p0|p1) buffer entry — identical layout to MovesSubmitted's `packed`
    ///         ([p0Move 8 | p0Extra 16 | p0Salt 104 | p1Move 8 | p1Extra 16 | p1Salt 104]) — so the
    ///         consumer reuses one unpack for both.
    function getBufferedTurns(bytes32 battleKey)
        external
        view
        returns (uint64 numExecuted, uint256[] memory packedTurns)
    {
        BattleData storage data = battleData[battleKey];
        numExecuted = data.turnId;
        uint256 n = data.numBuffered;
        bytes32 storageKey = _resolveStorageKey(battleKey);
        packedTurns = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            packedTurns[i] = moveBuffer[storageKey][numExecuted + uint64(i)];
        }
    }

    /// @notice Public resolver for a battle's slot-reused storageKey (the per-battle config slot index).
    ///         Used by tooling/tests to verify slot reuse across battles.
    function getStorageKey(bytes32 battleKey) external view returns (bytes32) {
        return _getStorageKey(battleKey);
    }

    /// @dev Decodes a transient-encoded move (layout: [extraData:16 | packedMoveIndex:8]) into a
    /// MoveDecision. Encoded == 0 means "no current turn move" since packedMoveIndex always has
    /// IS_REAL_TURN_BIT set for a real move.
    function _decodeMove(uint256 encoded) private pure returns (MoveDecision memory m) {
        m.packedMoveIndex = uint8(encoded & 0xFF);
        m.extraData = uint16(encoded >> 8);
    }

    /// @dev Packs a current-turn (encoded move, salt) pair into one transient word:
    /// [salt: bits 0-103 | encoded move: bits 104-127]. Companion to the unpacks in
    /// _getCurrentTurnMove / _getCurrentTurnSalt.
    function _packTurn(uint256 encoded, uint104 salt) private pure returns (uint256) {
        return uint256(salt) | (encoded << 104);
    }

    /// @dev Returns the current turn's MoveDecision for `playerIndex`. During an active
    /// execute, reads from transient storage (populated at the start of _executeInternal).
    function _getCurrentTurnMove(BattleConfig storage config, uint256 playerIndex)
        internal
        view
        returns (MoveDecision memory)
    {
        uint256 encoded = (playerIndex == 0 ? _turnP0Packed : _turnP1Packed) >> 104;
        if (encoded != 0) {
            return _decodeMove(encoded);
        }
        return playerIndex == 0 ? config.p0Move : config.p1Move;
    }

    /// @dev Salt companion to `_getCurrentTurnMove`. One transient load covers both the
    /// "populated?" check and the salt extraction.
    function _getCurrentTurnSalt(BattleConfig storage config, uint256 playerIndex) internal view returns (uint104) {
        uint256 packed = playerIndex == 0 ? _turnP0Packed : _turnP1Packed;
        if (packed != 0) {
            return uint104(packed);
        }
        return playerIndex == 0 ? config.p0Salt : config.p1Salt;
    }

    /// @notice Internal execution logic shared by execute() and executeWithMoves()
    /// @dev Two independent event controls. `emitMonMoves`: per-turn MonMoves at the top (legacy
    ///      per-turn execute only — the batched/buffer paths announce moves elsewhere). `emitBattleComplete`:
    ///      the normal BattleComplete on game over (legacy + the PvP buffer drain; the CPU one-tx path
    ///      passes false and emits BattleCompleteWithBatchTurns instead). Combinations in use:
    ///      legacy (true,true), CPU one-tx (false,false), PvP drain (false,true).
    /// @return winner address(0) if the battle is still in progress, otherwise the winning player's address.
    function _executeInternal(bytes32 battleKey, bytes32 storageKey, bool emitMonMoves, bool emitBattleComplete)
        internal
        returns (address winner)
    {
        // Load storage vars
        BattleData storage battle = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        // Check for game over
        if (battle.winnerIndex != 2) {
            revert GameAlreadyOver();
        }

        // `cameFromDirectMoveInput` detects whether transient was pre-populated by executeWithMoves
        // or executeWithSingleMove
        // (non-zero at entry) vs. a plain execute() call (transient is zero, helpers fall back to storage).
        bool cameFromDirectMoveInput = _turnP0Packed != 0 || _turnP1Packed != 0;

        // Set up turn / player vars
        uint256 turnId = battle.turnId;
        uint256 playerSwitchForTurnFlag = 2;
        uint256 priorityPlayerIndex;

        // Set the battle key for the stack frame
        // (gets cleared at the end of the transaction)
        battleKeyForWrite = battleKey;

        uint256 numHooks = config.engineHooksLength;
        for (uint256 i = 0; i < numHooks;) {
            if ((config.engineHooks[i].stepsBitmap & (1 << uint8(EngineHookStep.OnRoundStart))) != 0) {
                config.engineHooks[i].hook.onRoundStart(battleKey);
            }
            unchecked {
                ++i;
            }
        }

        // Emit MonMoves upfront with both players' moves + salts packed into one event.
        // This guarantees clients always receive each player's move + salt, regardless
        // of any early returns (mid-turn KO, shouldSkipTurn, stamina/validator failure)
        // inside _handleMove. Per-lane packedMoveIndex == 0 means that player did not
        // submit (e.g. non-acting side on a switch-only follow-up turn); if both lanes
        // are zero the emit is skipped entirely.
        // Only the legacy per-turn execute path emits MonMoves here. The CPU one-tx path and the PvP
        // buffer drain both pass emitMonMoves=false: CPU carries the replay in BattleCompleteWithBatchTurns,
        // and the PvP path already announced each move via MovesSubmitted at submit time — so re-emitting
        // per-turn MonMoves in the drain would be pure overhead (~1.6k gas/turn).
        MoveDecision memory p0TurnMove = _getCurrentTurnMove(config, 0);
        MoveDecision memory p1TurnMove = _getCurrentTurnMove(config, 1);
        if (emitMonMoves) {
            _emitMonMoves(battleKey, config, battle, p0TurnMove, p1TurnMove);
        }

        // If only a single player has a move to submit, then we don't trigger any effects
        // (Basically this only handles switching mons for now)
        if (battle.playerSwitchForTurnFlag == 0 || battle.playerSwitchForTurnFlag == 1) {
            // Get the player index that needs to switch for this turn
            uint256 playerIndex = battle.playerSwitchForTurnFlag;

            // Run the move (trust that the validator only lets valid single player moves happen as a switch action)
            // Running the move will set the winner flag if valid
            playerSwitchForTurnFlag = _handleMove(battleKey, config, battle, playerIndex, playerSwitchForTurnFlag);
        }
        // Otherwise, we need to run priority calculations and update the game state for both players
        /*
            Flow of battle:
            - Grab moves and calculate pseudo RNG
            - Determine priority player
            - Run round start global effects
            - Run round start targeted effects for p0 and p1
            - Execute priority player's move
            - Check for game over/KO (for switch flag)
                - If game over, just return
            - If KO, skip non priority player's move
            - Execute non priority player's move
            - Check for game over/KO (for switch flag)
                - If game over, just return
            - Run global end of turn effects
            - Check for game over/KO (for switch flag)
                - If game over, just return
            - If not KOed, run the priority player's targeted effects
            - Check for game over/KO (for switch flag)
                - If game over, just return
            - If not KOed, run the non priority player's targeted effects
            - Check for game over/KO (for switch flag)
                - If game over, just return
            - Progress turn index
            - Set player switch for turn flag
        */
        else {
            // Update the temporary RNG to the newest value
            // Inline RNG computation when oracle is address(0) to avoid external call
            uint256 rng;
            uint104 p0TurnSalt = _getCurrentTurnSalt(config, 0);
            uint104 p1TurnSalt = _getCurrentTurnSalt(config, 1);
            if (address(config.rngOracle) == address(0)) {
                rng = uint256(keccak256(abi.encode(p0TurnSalt, p1TurnSalt)));
            } else {
                rng = config.rngOracle.getRNG(bytes32(uint256(p0TurnSalt)), bytes32(uint256(p1TurnSalt)));
            }
            tempRNG = rng;

            // Cache `hasInlineStaminaRegen` once instead of re-reading config slot 2 three times below.
            bool inlineStaminaRegen = config.hasInlineStaminaRegen;

            // Calculate the priority and non-priority player indices. Use the internal helper
            // with already-resolved config/battle/moves to skip redundant storage re-resolution.
            priorityPlayerIndex = _computePriorityPlayerIndex(config, battle, battleKey, rng, p0TurnMove, p1TurnMove);
            uint256 otherPlayerIndex = 1 - priorityPlayerIndex;

            // Run beginning of round effects. Skip the global-list call when there are no global
            // effects (the inline-regen prod default keeps globalEffectsLength == 0), and skip the
            // per-player calls when no effect anywhere listens at RoundStart (union bit clear) — both
            // avoid the _handleEffects call + its winnerIndex/koOccurredFlag bookkeeping when there is
            // provably nothing to run. Ordering (global, priority, other) is preserved.
            if (config.globalEffectsLength != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    battleKey,
                    config,
                    battle,
                    rng,
                    2,
                    2,
                    EffectStep.RoundStart,
                    EffectRunCondition.SkipIfGameOver,
                    playerSwitchForTurnFlag
                );
            }
            if ((config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.RoundStart))) != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    battleKey,
                    config,
                    battle,
                    rng,
                    priorityPlayerIndex,
                    priorityPlayerIndex,
                    EffectStep.RoundStart,
                    EffectRunCondition.SkipIfGameOverOrMonKO,
                    playerSwitchForTurnFlag
                );
                playerSwitchForTurnFlag = _handleEffects(
                    battleKey,
                    config,
                    battle,
                    rng,
                    otherPlayerIndex,
                    otherPlayerIndex,
                    EffectStep.RoundStart,
                    EffectRunCondition.SkipIfGameOverOrMonKO,
                    playerSwitchForTurnFlag
                );
            }

            // Run priority player's move (NOTE: moves won't run if either mon is KOed)
            playerSwitchForTurnFlag =
                _handleMove(battleKey, config, battle, priorityPlayerIndex, playerSwitchForTurnFlag);

            // If priority mons is not KO'ed, then run the priority player's mon's afterMove hook(s).
            // Union re-read here (not cached from RoundStart): the move just executed may have added an
            // effect that listens at AfterMove.
            if ((config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.AfterMove))) != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    battleKey,
                    config,
                    battle,
                    rng,
                    priorityPlayerIndex,
                    priorityPlayerIndex,
                    EffectStep.AfterMove,
                    EffectRunCondition.SkipIfGameOverOrMonKO,
                    playerSwitchForTurnFlag
                );
            }

            // Always run the global effect's afterMove hook(s)
            if (config.globalEffectsLength != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    battleKey,
                    config,
                    battle,
                    rng,
                    2,
                    priorityPlayerIndex,
                    EffectStep.AfterMove,
                    EffectRunCondition.SkipIfGameOver,
                    playerSwitchForTurnFlag
                );
            }

            // Stamina regen decision is encapsulated in _inlineStaminaRegen, which reads the move FRESH
            // — required because effects (SleepStatus) can rewrite the move to a resting NO_OP mid-turn.
            if (inlineStaminaRegen) {
                _inlineStaminaRegen(
                    config,
                    EffectStep.AfterMove,
                    priorityPlayerIndex,
                    _unpackActiveMonIndex(battle.activeMonIndex, priorityPlayerIndex),
                    0,
                    0
                );
            }

            // Run the non priority player's move
            playerSwitchForTurnFlag = _handleMove(battleKey, config, battle, otherPlayerIndex, playerSwitchForTurnFlag);

            // For turn 0 only: wait for both mons to be sent in, then handle the ability activateOnSwitch
            // Happens immediately after both mons are sent in, before any other effects
            if (turnId == 0) {
                uint256 priorityMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, priorityPlayerIndex);
                _activateAbility(
                    config,
                    battleKey,
                    _getTeamMon(config, priorityPlayerIndex, priorityMonIndex).ability,
                    priorityPlayerIndex,
                    priorityMonIndex
                );
                uint256 otherMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, otherPlayerIndex);
                _activateAbility(
                    config,
                    battleKey,
                    _getTeamMon(config, otherPlayerIndex, otherMonIndex).ability,
                    otherPlayerIndex,
                    otherMonIndex
                );
            }

            // If non priority mon is not KOed, then run the non priority player's mon's afterMove hook(s).
            // Union re-read: the non-priority move just executed may have added an AfterMove listener.
            if ((config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.AfterMove))) != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    battleKey,
                    config,
                    battle,
                    rng,
                    otherPlayerIndex,
                    otherPlayerIndex,
                    EffectStep.AfterMove,
                    EffectRunCondition.SkipIfGameOverOrMonKO,
                    playerSwitchForTurnFlag
                );
            }

            // Always run the global effect's afterMove hook(s)
            if (config.globalEffectsLength != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    battleKey,
                    config,
                    battle,
                    rng,
                    2,
                    otherPlayerIndex,
                    EffectStep.AfterMove,
                    EffectRunCondition.SkipIfGameOver,
                    playerSwitchForTurnFlag
                );
            }

            if (inlineStaminaRegen) {
                _inlineStaminaRegen(
                    config,
                    EffectStep.AfterMove,
                    otherPlayerIndex,
                    _unpackActiveMonIndex(battle.activeMonIndex, otherPlayerIndex),
                    0,
                    0
                );
            }

            // Round-end effects. Same guard shape as RoundStart: skip the global call with no global
            // effects, and skip both per-player calls when nothing listens at RoundEnd (union re-read,
            // since the two moves this turn may have applied a RoundEnd status). Ordering preserved.
            if (config.globalEffectsLength != 0) {
                playerSwitchForTurnFlag = _handleEffects(
                    battleKey,
                    config,
                    battle,
                    rng,
                    2,
                    2,
                    EffectStep.RoundEnd,
                    EffectRunCondition.SkipIfGameOver,
                    playerSwitchForTurnFlag
                );
            }

            if ((config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.RoundEnd))) != 0) {
                // If priority mon is not KOed, run roundEnd effects for the priority mon
                playerSwitchForTurnFlag = _handleEffects(
                    battleKey,
                    config,
                    battle,
                    rng,
                    priorityPlayerIndex,
                    priorityPlayerIndex,
                    EffectStep.RoundEnd,
                    EffectRunCondition.SkipIfGameOverOrMonKO,
                    playerSwitchForTurnFlag
                );

                // If non priority mon is not KOed, run roundEnd effects for the non priority mon
                playerSwitchForTurnFlag = _handleEffects(
                    battleKey,
                    config,
                    battle,
                    rng,
                    otherPlayerIndex,
                    otherPlayerIndex,
                    EffectStep.RoundEnd,
                    EffectRunCondition.SkipIfGameOverOrMonKO,
                    playerSwitchForTurnFlag
                );
            }

            if (inlineStaminaRegen) {
                uint256 p0Mon = _unpackActiveMonIndex(battle.activeMonIndex, 0);
                uint256 p1Mon = _unpackActiveMonIndex(battle.activeMonIndex, 1);
                _inlineStaminaRegen(config, EffectStep.RoundEnd, 0, 0, p0Mon, p1Mon);
            }
        }

        // Run the round end hooks
        for (uint256 i = 0; i < numHooks;) {
            if ((config.engineHooks[i].stepsBitmap & (1 << uint8(EngineHookStep.OnRoundEnd))) != 0) {
                config.engineHooks[i].hook.onRoundEnd(battleKey);
            }
            unchecked {
                ++i;
            }
        }

        // If a winner has been set, handle the game over
        if (battle.winnerIndex != 2) {
            winner = (battle.winnerIndex == 0) ? battle.p0 : battle.p1;
            // CPU one-tx path (emitBattleComplete=false) suppresses BattleComplete here —
            // executeBatchedTurns emits BattleCompleteWithBatchTurns after the loop with the full turn
            // list. Legacy + the PvP buffer drain (emitBattleComplete=true) emit the normal BattleComplete.
            _handleGameOver(battleKey, winner, emitBattleComplete);
            return winner;
        }

        // End of turn cleanup:
        // - Progress turn index
        // - Set the player switch for turn flag on battle data
        // - Clear move flags for next turn (clear isRealTurn bit by setting packedMoveIndex to 0)
        // - Update lastExecuteTimestamp for timeout tracking
        battle.turnId += 1;
        battle.playerSwitchForTurnFlag = uint8(playerSwitchForTurnFlag);
        // Clear storage move slots only when they were actually written via setMove (execute() path).
        // executeWithMoves never writes, so the slots stay zero and a clear here would burn ~4.4k on
        // a cold-access SSTORE 0→0.
        if (!cameFromDirectMoveInput) {
            config.p0Move.packedMoveIndex = 0;
            config.p1Move.packedMoveIndex = 0;
        }
        battle.lastExecuteTimestamp = uint40(block.timestamp);
    }

    /// @notice Clears transient storage that otherwise persists across multiple execute()/executeWithMoves()
    /// calls within the same transaction. Intended for foundry test harnesses that dispatch multiple turns
    /// in one test function (the EVM's per-tx transient-clear doesn't fire between `vm.prank`-delimited
    /// calls). Zero-cost in production since every call is its own tx and transient auto-clears at tx end.
    /// @dev Also clears `battleKeyForWrite` / `storageKeyForWrite` so view getters that fall back to the
    /// persistent `battleKeyToStorageKey` mapping (e.g. `getBattle` for ended battles) behave the same in
    /// tests as on a fresh-tx production call. Any subsequent `execute()` re-sets both at entry, and the
    /// in-`execute` readers (StatBoosts, etc.) run after that — so this is safe to call between turns.
    /// Note: this loses `setMove`'s `isForCurrentBattle` cache hit (Engine.sol:1454) on the next setMove,
    /// adding one warm SLOAD per call. Production never calls this so the regression is test-only.
    function resetCallContext() external {
        _turnP0Packed = 0;
        _turnP1Packed = 0;
        battleKeyForWrite = bytes32(0);
        storageKeyForWrite = bytes32(0);
        // Per-turn transients that `executeBatchedTurns` resets between sub-turns; cleared here too
        // so each call starts like a fresh tx (these auto-clear at tx end in prod).
        tempRNG = 0;
        koOccurredFlag = 0;
        tempPreDamage = 0;
        effectsDirtyBitmap = 0;
    }

    /// @notice Forcibly end a stalled battle once it has run past MAX_BATTLE_DURATION.
    /// @dev Permissionless. Per-turn inactivity detection has been removed, so this max-duration
    ///      cleanup is the sole on-chain stall-resolution path (a future external resolver can
    ///      declare timeout winners via the validator's `validateTimeout` surface). Called before
    ///      the window elapses it is a silent no-op.
    function end(bytes32 battleKey) external {
        BattleData storage data = battleData[battleKey];
        if (data.winnerIndex != 2) {
            revert GameAlreadyOver();
        }
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;
        if (block.timestamp - battleConfig[storageKey].startTimestamp > MAX_BATTLE_DURATION) {
            // Award p0, matching the BattleComplete(p0) event _handleGameOver emits. Setting
            // winnerIndex is required: _handleGameOver itself never writes it, so without this the
            // battle would stay winnerIndex==2 (commit manager would never see it as complete).
            data.winnerIndex = 0;
            _handleGameOver(battleKey, data.p0, true);
        }
    }

    /// @param emitBattleComplete When false (batched path), the plain BattleComplete emit is
    ///        suppressed — `executeBatchedTurns` emits BattleCompleteWithBatchTurns instead so the
    ///        winner + full turn list arrive in one log. Hooks (GachaEvent) + key-free still run.
    function _handleGameOver(bytes32 battleKey, address winner, bool emitBattleComplete) internal {
        bytes32 storageKey = storageKeyForWrite;
        BattleConfig storage config = battleConfig[storageKey];

        if (block.timestamp == config.startTimestamp) {
            revert GameStartsAndEndsSameBlock();
        }

        for (uint256 i = 0; i < config.engineHooksLength;) {
            if ((config.engineHooks[i].stepsBitmap & (1 << uint8(EngineHookStep.OnBattleEnd))) != 0) {
                config.engineHooks[i].hook.onBattleEnd(battleKey);
            }
            unchecked {
                ++i;
            }
        }

        // Free the key used for battle configs so other battles can use it
        _freeStorageKey(battleKey, storageKey);
        if (emitBattleComplete) emit BattleComplete(battleKey, winner);
    }

    /**
     * - Write functions for MonState, Effects, and GlobalKV
     */
    function _updateMonStateInternal(
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex,
        int32 valueToAdd
    ) internal {
        bytes32 battleKey = battleKeyForWrite;
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        MonState storage monState = _getMonState(config, playerIndex, monIndex);
        if (stateVarIndex == MonStateIndexName.Hp) {
            monState.hpDelta =
                (monState.hpDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.hpDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.Stamina) {
            monState.staminaDelta =
                (monState.staminaDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.staminaDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.Speed) {
            monState.speedDelta =
                (monState.speedDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.speedDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.Attack) {
            monState.attackDelta =
                (monState.attackDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.attackDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.Defense) {
            monState.defenceDelta =
                (monState.defenceDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.defenceDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.SpecialAttack) {
            monState.specialAttackDelta = (monState.specialAttackDelta == CLEARED_MON_STATE_SENTINEL)
                ? valueToAdd
                : monState.specialAttackDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.SpecialDefense) {
            monState.specialDefenceDelta = (monState.specialDefenceDelta == CLEARED_MON_STATE_SENTINEL)
                ? valueToAdd
                : monState.specialDefenceDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.IsKnockedOut) {
            bool newKOState = (valueToAdd % 2) == 1;
            bool wasKOed = monState.isKnockedOut;
            monState.isKnockedOut = newKOState;
            // Update KO bitmap if state changed
            if (newKOState && !wasKOed) {
                _setMonKO(config, playerIndex, monIndex);
                koOccurredFlag = 1;
                // Lock in winner immediately if this KO ends the game
                _checkAndSetWinnerIfGameOver(config, playerIndex);
            } else if (!newKOState && wasKOed) {
                _clearMonKO(config, playerIndex, monIndex);
            }
        } else if (stateVarIndex == MonStateIndexName.ShouldSkipTurn) {
            monState.shouldSkipTurn = (valueToAdd % 2) == 1;
        }

        // Trigger OnUpdateMonState lifecycle hook only if some player effect actually listens at it
        // (battle-wide union) AND this mon has effects. OnUpdateMonState has a single listener in the
        // whole game (Dreamcatcher), so the union bit is unset in almost every battle — skipping the
        // abi.encode(4-tuple) + _runEffects shell entirely. Stat-boost delta writes hit this path a lot.
        uint256 updateMonStateCount = playerIndex == 0
            ? _getMonEffectCount(config.packedP0EffectsCount, monIndex)
            : _getMonEffectCount(config.packedP1EffectsCount, monIndex);
        if (updateMonStateCount > 0
            && (config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.OnUpdateMonState))) != 0) {
            _runEffects(
                battleKey,
                tempRNG,
                playerIndex,
                playerIndex,
                EffectStep.OnUpdateMonState,
                abi.encode(playerIndex, monIndex, stateVarIndex, valueToAdd),
                type(uint256).max
            );
        }
    }

    function updateMonState(uint256 playerIndex, uint256 monIndex, MonStateIndexName stateVarIndex, int32 valueToAdd)
        external
    {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        // Speed(2)..SpecialDefense(6) are the stat-boost-owned deltas — reject direct writes so they
        // can only change through add/removeStatBoost (the internal stat-boost path bypasses this by
        // calling _updateMonStateInternal directly). Hp/Stamina/IsKnockedOut/ShouldSkipTurn stay open.
        uint256 idx = uint256(stateVarIndex);
        if (idx >= uint256(MonStateIndexName.Speed) && idx <= uint256(MonStateIndexName.SpecialDefense)) {
            revert StatRequiresStatBoost();
        }
        _updateMonStateInternal(playerIndex, monIndex, stateVarIndex, valueToAdd);
    }

    function _isEffectRegistered(BattleConfig storage config, uint256 playerIndex, uint256 monIndex, address effectAddr)
        internal
        view
        returns (bool)
    {
        uint256 effectCount;
        if (playerIndex == 0) {
            effectCount = _getMonEffectCount(config.packedP0EffectsCount, monIndex);
            for (uint256 i; i < effectCount; i++) {
                uint256 slotIndex = _getEffectSlotIndex(monIndex, i);
                if (address(config.p0Effects[slotIndex].effect) == effectAddr) return true;
            }
        } else {
            effectCount = _getMonEffectCount(config.packedP1EffectsCount, monIndex);
            for (uint256 i; i < effectCount; i++) {
                uint256 slotIndex = _getEffectSlotIndex(monIndex, i);
                if (address(config.p1Effects[slotIndex].effect) == effectAddr) return true;
            }
        }
        return false;
    }

    function _inlineAbilityActivation(
        BattleConfig storage config,
        uint256 rawAbilitySlot,
        uint256 playerIndex,
        uint256 monIndex
    ) internal {
        uint8 abilityTypeId = uint8(rawAbilitySlot >> 248);
        address effectAddr = address(uint160(rawAbilitySlot));

        if (abilityTypeId == 1) {
            // Singleton self-register, mon-local:
            // Idempotency check + addEffect(playerIndex, monIndex, effectAddr, bytes32(0))
            if (!_isEffectRegistered(config, playerIndex, monIndex, effectAddr)) {
                _addEffectInternal(playerIndex, monIndex, IEffect(effectAddr), bytes32(0));
            }
        }
    }

    function _activateAbility(
        BattleConfig storage config,
        bytes32 battleKey,
        uint256 rawAbility,
        uint256 playerIndex,
        uint256 monIndex
    ) internal {
        if (rawAbility == 0) return;
        if (rawAbility >> 160 != 0) {
            _inlineAbilityActivation(config, rawAbility, playerIndex, monIndex);
        } else {
            IAbility(address(uint160(rawAbility)))
                .activateOnSwitch(IEngine(address(this)), battleKey, playerIndex, monIndex);
        }
    }

    function _addEffectInternal(uint256 targetIndex, uint256 monIndex, IEffect effect, bytes32 extraData) internal {
        bytes32 battleKey = battleKeyForWrite;
        // Fetch steps bitmap once (reused for storage and ALWAYS_APPLIES check)
        uint16 stepsBitmap = effect.getStepsBitmap();

        // Skip external shouldApply() call if ALWAYS_APPLIES_BIT is set
        bool applies;
        if ((stepsBitmap & ALWAYS_APPLIES_BIT) != 0) {
            applies = true;
        } else {
            applies = effect.shouldApply(IEngine(address(this)), battleKey, extraData, targetIndex, monIndex);
        }

        if (applies) {
            bytes32 extraDataToUse = extraData;
            bool removeAfterRun = false;

            // Check if we have to run an onApply state update (use bitmap instead of external call)
            if ((stepsBitmap & (1 << uint8(EffectStep.OnApply))) != 0) {
                // Get active mon indices for both players
                BattleData storage battle = battleData[battleKey];
                uint256 p0ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
                uint256 p1ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);
                // If so, we run the effect first, and get updated extraData if necessary
                (extraDataToUse, removeAfterRun) = effect.onApply(
                    IEngine(address(this)),
                    battleKey,
                    tempRNG,
                    extraData,
                    targetIndex,
                    monIndex,
                    p0ActiveMonIndex,
                    p1ActiveMonIndex
                );
            }
            if (!removeAfterRun) {
                // Add to the appropriate effects mapping based on targetIndex
                BattleConfig storage config = battleConfig[storageKeyForWrite];

                // INVARIANT: every path that adds a player effect MUST fold its steps bitmap into
                // playerEffectStepsUnion here. The step-skip guards in _executeInternal / _handleSwitch
                // treat a clear union bit as "no player effect listens at this step" and skip the whole
                // _runEffects shell, so a missed update would silently drop live effects. This is the
                // canonical chokepoint (addEffect -> _addEffectInternal); the ONLY other player-effect
                // writer is _addStatBoostEffectSlot, which mirrors this with `|= STAT_BOOST_STEPS`.
                // Global effects (targetIndex == 2) are gated by globalEffectsLength instead, not the union.
                if (targetIndex != 2) {
                    config.playerEffectStepsUnion |= stepsBitmap;
                }

                if (targetIndex == 2) {
                    // Global effects use simple sequential indexing
                    uint256 effectIndex = config.globalEffectsLength;
                    EffectInstance storage effectSlot = config.globalEffects[effectIndex];
                    effectSlot.effect = effect;
                    effectSlot.stepsBitmap = stepsBitmap;
                    effectSlot.data = extraDataToUse;
                    config.globalEffectsLength = uint8(effectIndex + 1);
                    // Set dirty bit 0 for global effects
                    effectsDirtyBitmap |= 1;
                } else if (targetIndex == 0) {
                    // Player effects use per-mon indexing: slot = MAX_EFFECTS_PER_MON * monIndex + count[monIndex]
                    uint256 monEffectCount = _getMonEffectCount(config.packedP0EffectsCount, monIndex);
                    uint256 slotIndex = _getEffectSlotIndex(monIndex, monEffectCount);
                    EffectInstance storage effectSlot = config.p0Effects[slotIndex];
                    effectSlot.effect = effect;
                    effectSlot.stepsBitmap = stepsBitmap;
                    effectSlot.data = extraDataToUse;
                    config.packedP0EffectsCount =
                        _setMonEffectCount(config.packedP0EffectsCount, monIndex, monEffectCount + 1);
                    // Set dirty bit (1 + monIndex) for P0 effects
                    effectsDirtyBitmap |= (1 << (1 + monIndex));
                } else {
                    uint256 monEffectCount = _getMonEffectCount(config.packedP1EffectsCount, monIndex);
                    uint256 slotIndex = _getEffectSlotIndex(monIndex, monEffectCount);
                    EffectInstance storage effectSlot = config.p1Effects[slotIndex];
                    effectSlot.effect = effect;
                    effectSlot.stepsBitmap = stepsBitmap;
                    effectSlot.data = extraDataToUse;
                    config.packedP1EffectsCount =
                        _setMonEffectCount(config.packedP1EffectsCount, monIndex, monEffectCount + 1);
                    // Set dirty bit (9 + monIndex) for P1 effects
                    effectsDirtyBitmap |= (1 << (9 + monIndex));
                }
            }
        }
    }

    function addEffect(uint256 targetIndex, uint256 monIndex, IEffect effect, bytes32 extraData) external {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        _addEffectInternal(targetIndex, monIndex, effect, extraData);
    }

    function editEffect(uint256 targetIndex, uint256 effectIndex, bytes32 newExtraData) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }

        // Access the appropriate effects mapping based on targetIndex
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        EffectInstance storage effectInstance;
        if (targetIndex == 2) {
            effectInstance = config.globalEffects[effectIndex];
        } else if (targetIndex == 0) {
            effectInstance = config.p0Effects[effectIndex];
        } else {
            effectInstance = config.p1Effects[effectIndex];
        }

        effectInstance.data = newExtraData;
    }

    function removeEffect(uint256 targetIndex, uint256 monIndex, uint256 indexToRemove) public {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }
        _removeEffectAtSlot(battleConfig[storageKeyForWrite], battleKey, targetIndex, monIndex, indexToRemove);
    }

    function _removeEffectAtSlot(
        BattleConfig storage config,
        bytes32 battleKey,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 slotIndex
    ) private {
        EffectInstance storage eff;
        if (targetIndex == 2) {
            eff = config.globalEffects[slotIndex];
        } else if (targetIndex == 0) {
            eff = config.p0Effects[slotIndex];
        } else {
            eff = config.p1Effects[slotIndex];
        }

        IEffect effect = eff.effect;
        if (address(effect) == TOMBSTONE_ADDRESS) return;

        if ((eff.stepsBitmap & (1 << uint8(EffectStep.OnRemove))) != 0) {
            BattleData storage battle = battleData[battleKey];
            uint256 p0Active = _unpackActiveMonIndex(battle.activeMonIndex, 0);
            uint256 p1Active = _unpackActiveMonIndex(battle.activeMonIndex, 1);
            effect.onRemove(IEngine(address(this)), battleKey, eff.data, targetIndex, monIndex, p0Active, p1Active);
        }

        eff.effect = IEffect(TOMBSTONE_ADDRESS);
    }

    // ---------------------------------------------------------------------------------------------
    // Inlined stat boosts
    //
    // Formerly the standalone `StatBoosts` effect contract. Boost sources are stored in the normal
    // per-mon effect mappings under the STAT_BOOST_ADDRESS sentinel (stepsBitmap = STAT_BOOST_STEPS),
    // and the aggregated multiplier snapshot lives in globalKV — both already recycled across battles
    // by the MappingAllocator-managed storageKey, so no new storage is introduced. Callers (moves,
    // abilities, shared effects) invoke these directly during execute, so the boost-source key is
    // still derived from msg.sender exactly as it was when StatBoosts saw the caller. The math lives
    // in StatBoostLib; here we only touch storage and fire the OnUpdateMonState pipeline via
    // _updateMonStateInternal (matching the legacy updateMonState path).
    // ---------------------------------------------------------------------------------------------

    /// @notice Apply a stat-boost source keyed by msg.sender (no salt). Merges into an existing
    ///         same-source/same-permanence entry if present.
    function addStatBoost(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostToApply[] calldata statBoostsToApply,
        StatBoostFlag boostFlag
    ) external {
        if (battleKeyForWrite == bytes32(0)) revert NoWriteAllowed();
        uint168 key = StatBoostLib.generateKeyNoSalt(targetIndex, monIndex, msg.sender);
        _addStatBoostWithKey(targetIndex, monIndex, statBoostsToApply, boostFlag == StatBoostFlag.Perm, key);
    }

    /// @notice Apply a stat-boost source keyed by (msg.sender, salt string) so one caller can hold
    ///         multiple independent boost instances on the same mon.
    function addKeyedStatBoost(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostToApply[] calldata statBoostsToApply,
        StatBoostFlag boostFlag,
        string calldata keyToUse
    ) external {
        if (battleKeyForWrite == bytes32(0)) revert NoWriteAllowed();
        uint168 key = StatBoostLib.generateKey(targetIndex, monIndex, msg.sender, keyToUse);
        _addStatBoostWithKey(targetIndex, monIndex, statBoostsToApply, boostFlag == StatBoostFlag.Perm, key);
    }

    /// @notice Remove the msg.sender-keyed stat-boost source of the given permanence (if any) and
    ///         recompute the mon's boosted stats.
    function removeStatBoost(uint256 targetIndex, uint256 monIndex, StatBoostFlag boostFlag) external {
        if (battleKeyForWrite == bytes32(0)) revert NoWriteAllowed();
        uint168 key = StatBoostLib.generateKeyNoSalt(targetIndex, monIndex, msg.sender);
        _removeStatBoostWithKey(targetIndex, monIndex, key, boostFlag == StatBoostFlag.Perm);
    }

    /// @notice Remove a (msg.sender, salt)-keyed stat-boost source.
    function removeKeyedStatBoost(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostFlag boostFlag,
        string calldata keyToUse
    ) external {
        if (battleKeyForWrite == bytes32(0)) revert NoWriteAllowed();
        uint168 key = StatBoostLib.generateKey(targetIndex, monIndex, msg.sender, keyToUse);
        _removeStatBoostWithKey(targetIndex, monIndex, key, boostFlag == StatBoostFlag.Perm);
    }

    /// @notice Remove every stat-boost source on a mon and reset its stats to base values.
    function clearAllStatBoosts(uint256 targetIndex, uint256 monIndex) external {
        if (battleKeyForWrite == bytes32(0)) revert NoWriteAllowed();
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        uint96 packedCounts = targetIndex == 0 ? config.packedP0EffectsCount : config.packedP1EffectsCount;
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;
        uint256 monEffectCount = _getMonEffectCount(packedCounts, monIndex);
        uint256 baseSlot = _getEffectSlotIndex(monIndex, 0);

        uint256 removeCount;
        for (uint256 i; i < monEffectCount; ++i) {
            EffectInstance storage eff = effects[baseSlot + i];
            if (address(eff.effect) == STAT_BOOST_ADDRESS) {
                eff.effect = IEffect(TOMBSTONE_ADDRESS);
                unchecked { ++removeCount; }
            }
        }
        if (removeCount == 0) return;

        // Reset to base by applying with empty aggregation.
        uint32[5] memory baseStats = _getStatBoostBaseStats(config, targetIndex, monIndex);
        uint32[5] memory numBoostsPerStat;
        uint256[5] memory accumulatedNumeratorPerStat;
        _applyStatBoosts(config, targetIndex, monIndex, baseStats, numBoostsPerStat, accumulatedNumeratorPerStat);
    }

    function _getStatBoostBaseStats(BattleConfig storage config, uint256 targetIndex, uint256 monIndex)
        private
        view
        returns (uint32[5] memory stats)
    {
        MonStats storage monStats = _getTeamMon(config, targetIndex, monIndex).stats;
        stats[0] = monStats.attack;
        stats[1] = monStats.defense;
        stats[2] = monStats.specialAttack;
        stats[3] = monStats.specialDefense;
        stats[4] = monStats.speed;
    }

    function _addStatBoostWithKey(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostToApply[] calldata statBoostsToApply,
        bool isPerm,
        uint168 key
    ) private {
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        uint32[5] memory baseStats = _getStatBoostBaseStats(config, targetIndex, monIndex);

        uint96 packedCounts = targetIndex == 0 ? config.packedP0EffectsCount : config.packedP1EffectsCount;
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;
        uint256 monEffectCount = _getMonEffectCount(packedCounts, monIndex);
        uint256 baseSlot = _getEffectSlotIndex(monIndex, 0);

        bool found;
        uint256 foundSlot;
        bytes32 existingData;
        uint32[5] memory numBoostsPerStat;
        uint256[5] memory accumulatedNumeratorPerStat;

        // Single pass: find the matching key AND aggregate every OTHER boost source on the mon.
        for (uint256 i; i < monEffectCount; ++i) {
            uint256 slotIndex = baseSlot + i;
            EffectInstance storage eff = effects[slotIndex];
            if (address(eff.effect) != STAT_BOOST_ADDRESS) continue;
            bytes32 data = eff.data;
            (bool effIsPerm, uint168 existingKey, uint8[5] memory bp, uint8[5] memory bc, bool[5] memory im) =
                StatBoostLib.unpackBoostData(data);
            if (existingKey == key && effIsPerm == isPerm) {
                found = true;
                foundSlot = slotIndex;
                existingData = data;
                continue; // excluded from aggregation; merged version is added below
            }
            StatBoostLib.accumulateBoosts(baseStats, bp, bc, im, numBoostsPerStat, accumulatedNumeratorPerStat);
        }

        // Compute the new/merged source and add its contribution.
        bytes32 newData;
        {
            uint8[5] memory finalPercents;
            uint8[5] memory finalCounts;
            bool[5] memory finalIsMul;
            if (found) {
                (, , uint8[5] memory ep, uint8[5] memory ec, bool[5] memory em) =
                    StatBoostLib.unpackBoostData(existingData);
                (finalPercents, finalCounts, finalIsMul) =
                    StatBoostLib.mergeExistingAndNewBoosts(ep, ec, em, statBoostsToApply);
                newData = StatBoostLib.packBoostDataWithArrays(key, isPerm, finalPercents, finalCounts, finalIsMul);
            } else {
                newData = StatBoostLib.packBoostData(key, isPerm, statBoostsToApply);
                (, , finalPercents, finalCounts, finalIsMul) = StatBoostLib.unpackBoostData(newData);
            }
            StatBoostLib.accumulateBoosts(
                baseStats, finalPercents, finalCounts, finalIsMul, numBoostsPerStat, accumulatedNumeratorPerStat
            );
        }

        // Persist the source entry.
        if (found) {
            effects[foundSlot].data = newData;
        } else {
            _addStatBoostEffectSlot(config, targetIndex, monIndex, packedCounts, effects, monEffectCount, newData);
        }

        _applyStatBoosts(config, targetIndex, monIndex, baseStats, numBoostsPerStat, accumulatedNumeratorPerStat);
    }

    function _removeStatBoostWithKey(uint256 targetIndex, uint256 monIndex, uint168 key, bool isPerm) private {
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        uint32[5] memory baseStats = _getStatBoostBaseStats(config, targetIndex, monIndex);

        uint96 packedCounts = targetIndex == 0 ? config.packedP0EffectsCount : config.packedP1EffectsCount;
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;
        uint256 monEffectCount = _getMonEffectCount(packedCounts, monIndex);
        uint256 baseSlot = _getEffectSlotIndex(monIndex, 0);

        bool found;
        uint256 foundSlot;
        uint32[5] memory numBoostsPerStat;
        uint256[5] memory accumulatedNumeratorPerStat;

        for (uint256 i; i < monEffectCount; ++i) {
            uint256 slotIndex = baseSlot + i;
            EffectInstance storage eff = effects[slotIndex];
            if (address(eff.effect) != STAT_BOOST_ADDRESS) continue;
            (bool effIsPerm, uint168 existingKey, uint8[5] memory bp, uint8[5] memory bc, bool[5] memory im) =
                StatBoostLib.unpackBoostData(eff.data);
            if (existingKey == key && effIsPerm == isPerm) {
                found = true;
                foundSlot = slotIndex;
                continue; // removed: excluded from aggregation
            }
            StatBoostLib.accumulateBoosts(baseStats, bp, bc, im, numBoostsPerStat, accumulatedNumeratorPerStat);
        }

        if (!found) return;
        effects[foundSlot].effect = IEffect(TOMBSTONE_ADDRESS);
        _applyStatBoosts(config, targetIndex, monIndex, baseStats, numBoostsPerStat, accumulatedNumeratorPerStat);
    }

    /// @dev Write a fresh stat-boost source into the next free per-mon effect slot. Mirrors the
    ///      player-effect storage block in _addEffectInternal (count bump + dirty bit) but writes
    ///      the sentinel address and fixed steps bitmap directly — no external IEffect calls.
    function _addStatBoostEffectSlot(
        BattleConfig storage config,
        uint256 targetIndex,
        uint256 monIndex,
        uint96 packedCounts,
        mapping(uint256 => EffectInstance) storage effects,
        uint256 monEffectCount,
        bytes32 data
    ) private {
        uint256 slotIndex = _getEffectSlotIndex(monIndex, monEffectCount);
        EffectInstance storage effectSlot = effects[slotIndex];
        effectSlot.effect = IEffect(STAT_BOOST_ADDRESS);
        effectSlot.stepsBitmap = STAT_BOOST_STEPS;
        effectSlot.data = data;
        // Upholds the playerEffectStepsUnion invariant documented in _addEffectInternal: this is the
        // one player-effect add-path that bypasses _addEffectInternal, so it must fold its steps in too.
        // Without this the union under-reports OnMonSwitchOut and _handleSwitch would skip dropping
        // temp boosts on switch-out.
        config.playerEffectStepsUnion |= STAT_BOOST_STEPS;
        uint96 newCounts = _setMonEffectCount(packedCounts, monIndex, monEffectCount + 1);
        if (targetIndex == 0) {
            config.packedP0EffectsCount = newCounts;
            effectsDirtyBitmap |= (1 << (1 + monIndex));
        } else {
            config.packedP1EffectsCount = newCounts;
            effectsDirtyBitmap |= (1 << (9 + monIndex));
        }
    }

    /// @dev Re-apply a mon's aggregated stat boosts by telescoping its monState deltas. The
    ///      stat-boost system is the sole writer of the 5 stat-delta fields, so the current delta
    ///      *is* the previous boost contribution (cleared == sentinel == 0): old boosted stat =
    ///      base + currentDelta. We compute the new boosted stat and feed the difference through
    ///      _updateMonStateInternal, which fires OnUpdateMonState for listeners exactly as before.
    ///      No globalKV snapshot is kept — being inside the Engine we read the delta back directly.
    function _applyStatBoosts(
        BattleConfig storage config,
        uint256 targetIndex,
        uint256 monIndex,
        uint32[5] memory baseStats,
        uint32[5] memory numBoostsPerStat,
        uint256[5] memory accumulatedNumeratorPerStat
    ) private {
        uint32[5] memory newBoostedStats =
            StatBoostLib.finalizeBoostedStats(baseStats, numBoostsPerStat, accumulatedNumeratorPerStat);
        MonState storage st = _getMonState(config, targetIndex, monIndex);

        for (uint256 i; i < 5; ++i) {
            // old boosted = base + current stat-boost delta (sentinel reads as 0 / "no boost")
            int32 valueToAdd = int32(newBoostedStats[i]) - int32(baseStats[i]) - _statBoostCurrentDelta(st, i);
            if (valueToAdd != 0) {
                _updateMonStateInternal(targetIndex, monIndex, StatBoostLib.statBoostIndexToMonStateIndex(i), valueToAdd);
            }
        }
    }

    /// @dev Current stat-boost delta for boost-index i (0:atk,1:def,2:spatk,3:spdef,4:speed),
    ///      treating the cleared sentinel as 0.
    function _statBoostCurrentDelta(MonState storage st, uint256 i) private view returns (int32) {
        int32 d;
        if (i == 0) d = st.attackDelta;
        else if (i == 1) d = st.defenceDelta;
        else if (i == 2) d = st.specialAttackDelta;
        else if (i == 3) d = st.specialDefenceDelta;
        else d = st.speedDelta;
        return d == CLEARED_MON_STATE_SENTINEL ? int32(0) : d;
    }

    /// @dev Switch-out handling for stat-boost entries: in a single pass drop EVERY temp source on
    ///      the mon (they all expire on switch-out) and re-aggregate the surviving permanent sources,
    ///      applying the result once. _runEffects only routes here when it hits a temp entry; that
    ///      first hit does all the work and tombstones its siblings, so the remaining temp slots are
    ///      skipped by the loop's tombstone guard (collapses the legacy per-instance O(n^2) recompute).
    function _inlineStatBoostSwitchOut(BattleConfig storage config, uint256 targetIndex, uint256 monIndex) private {
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;
        uint96 packedCounts = targetIndex == 0 ? config.packedP0EffectsCount : config.packedP1EffectsCount;
        uint256 monEffectCount = _getMonEffectCount(packedCounts, monIndex);
        uint256 baseSlot = _getEffectSlotIndex(monIndex, 0);
        uint32[5] memory baseStats = _getStatBoostBaseStats(config, targetIndex, monIndex);
        uint32[5] memory numBoostsPerStat;
        uint256[5] memory accumulatedNumeratorPerStat;

        for (uint256 i; i < monEffectCount; ++i) {
            EffectInstance storage eff = effects[baseSlot + i];
            if (address(eff.effect) != STAT_BOOST_ADDRESS) continue;
            (bool effIsPerm, , uint8[5] memory bp, uint8[5] memory bc, bool[5] memory im) =
                StatBoostLib.unpackBoostData(eff.data);
            if (!effIsPerm) {
                eff.effect = IEffect(TOMBSTONE_ADDRESS); // temp sources all expire on switch-out
                continue;
            }
            StatBoostLib.accumulateBoosts(baseStats, bp, bc, im, numBoostsPerStat, accumulatedNumeratorPerStat);
        }

        _applyStatBoosts(config, targetIndex, monIndex, baseStats, numBoostsPerStat, accumulatedNumeratorPerStat);
    }

    function setGlobalKV(uint64 key, uint192 value) external {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        _setGlobalKV(key, value);
    }

    /// @dev Internal globalKV writer (assumes caller has gated on battleKeyForWrite). Shared by the
    ///      external setGlobalKV and the inlined stat-boost snapshot path.
    function _setGlobalKV(uint64 key, uint192 value) private {
        bytes32 storageKey = storageKeyForWrite;
        BattleConfig storage config = battleConfig[storageKey];
        uint40 timestamp = config.startTimestamp;

        // "Never written in THIS battle" ⇔ stored timestamp ≠ current battle's timestamp.
        // Covers both first-ever write (packed == 0) and first-write after storageKey reuse.
        uint64 existingTs = uint64(uint256(globalKV[storageKey][key]) >> 192);
        if (existingTs != uint64(timestamp)) {
            uint256 idx = config.globalKVCount;
            uint256 slotIdx = idx >> 2;
            uint256 shift = (idx & 3) * 64;
            uint256 slot = globalKVKeySlots[storageKey][slotIdx];
            // Clear the lane, then write the new key into it.
            slot = (slot & ~(uint256(type(uint64).max) << shift)) | (uint256(key) << shift);
            globalKVKeySlots[storageKey][slotIdx] = slot;
            unchecked {
                config.globalKVCount = uint8(idx + 1);
            }
        }

        // Pack timestamp (upper 64 bits) with value (lower 192 bits)
        globalKV[storageKey][key] = bytes32((uint256(timestamp) << 192) | uint256(value));
    }

    /// @notice Check if the KO'd player's team is fully wiped and lock in the winner immediately
    /// @dev Called after each KO to ensure winner is determined by order of KOs, not bitmap check order
    function _checkAndSetWinnerIfGameOver(BattleConfig storage config, uint256 koPlayerIndex) internal {
        BattleData storage battle = battleData[battleKeyForWrite];

        // If winner already set, don't overwrite
        if (battle.winnerIndex != 2) {
            return;
        }

        // Check if KO'd player's team is fully wiped
        uint256 koBitmap = _getKOBitmap(config, koPlayerIndex);
        uint256 teamSize = (koPlayerIndex == 0) ? (config.teamSizes & 0x0F) : (config.teamSizes >> 4);
        uint256 fullMask = (1 << teamSize) - 1;

        if (koBitmap == fullMask) {
            // This player's team is fully wiped, other player wins
            battle.winnerIndex = uint8((koPlayerIndex + 1) % 2);
        }
    }

    function _dealDamageInternal(
        BattleConfig storage config,
        uint256 playerIndex,
        uint256 monIndex,
        int32 damage,
        uint256 source
    ) internal {
        // If game is already over, skip all damage
        BattleData storage battle = battleData[battleKeyForWrite];
        if (battle.winnerIndex != 2) {
            return;
        }

        MonState storage monState = _getMonState(config, playerIndex, monIndex);

        if (monState.isKnockedOut) {
            return;
        }

        // PreDamage pipeline: victim-side mon-local effects can mutate the in-flight damage by
        // calling engine.setPreDamage(). Reuses the standard _runEffects loop; running damage is
        // threaded through the transient `tempPreDamage` slot so the iteration logic doesn't change.
        uint256 monEffectCount = playerIndex == 0
            ? _getMonEffectCount(config.packedP0EffectsCount, monIndex)
            : _getMonEffectCount(config.packedP1EffectsCount, monIndex);
        // PreDamage has a single listener game-wide (Adaptor), so the union bit is unset in almost
        // every battle — skip the pipeline (and the tempPreDamage round-trip) entirely.
        if (monEffectCount > 0
            && (config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.PreDamage))) != 0) {
            tempPreDamage = damage;
            _runEffects(
                battleKeyForWrite, tempRNG, playerIndex, playerIndex, EffectStep.PreDamage, abi.encode(source), type(uint256).max
            );
            damage = tempPreDamage;
            tempPreDamage = 0;
        }
        if (damage <= 0) {
            return;
        }

        // If sentinel, replace with -damage; otherwise subtract damage
        monState.hpDelta = (monState.hpDelta == CLEARED_MON_STATE_SENTINEL) ? -damage : monState.hpDelta - damage;

        // Set KO flag if the total hpDelta is greater than the original mon HP
        uint32 baseHp = _getTeamMon(config, playerIndex, monIndex).stats.hp;
        if (monState.hpDelta + int32(baseHp) <= 0) {
            monState.isKnockedOut = true;
            _setMonKO(config, playerIndex, monIndex);
            koOccurredFlag = 1;

            // Lock in winner immediately if this KO ends the game
            _checkAndSetWinnerIfGameOver(config, playerIndex);
        }
        // Only run the AfterDamage hook pipeline if some player effect listens at it AND this mon
        // has effects.
        if (monEffectCount > 0
            && (config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.AfterDamage))) != 0) {
            _runEffects(
                battleKeyForWrite,
                tempRNG,
                playerIndex,
                playerIndex,
                EffectStep.AfterDamage,
                abi.encode(damage, source),
                type(uint256).max
            );
        }
    }

    function dealDamage(uint256 playerIndex, uint256 monIndex, int32 damage) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        _dealDamageInternal(config, playerIndex, monIndex, damage, uint256(uint160(msg.sender)));
    }

    function getPreDamage() external view returns (int32) {
        return tempPreDamage;
    }

    function setPreDamage(int32 value) external {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        tempPreDamage = value;
    }

    function _dispatchStandardAttackInternal(
        BattleConfig storage config,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderPlayerIndex,
        uint256 defenderMonIndex,
        uint32 basePower,
        uint32 accuracy,
        uint32 volatility,
        Type moveType,
        MoveClass moveClass,
        uint256 critRate,
        uint8 effectAccuracy,
        IEffect effect,
        uint256 rng,
        uint256 source
    ) internal returns (int32 damage, bytes32 eventType) {
        // Per-attacker rng mix: mirror mons using the same move against each other must roll differently.
        // See AttackCalculator.mixRngForAttacker for rationale; matches StandardAttack._move's external path.
        uint256 rngToUse = AttackCalculator.mixRngForAttacker(rng, attackerPlayerIndex);

        if (basePower > 0) {
            // Accuracy check (only for damaging moves; status moves have no accuracy gate, matching the external path)
            if (accuracy < 100 && (rngToUse % 100) >= accuracy) {
                return (0, MOVE_MISS_EVENT_TYPE);
            }

            // Build DamageCalcContext from internal storage (no external callback)
            DamageCalcContext memory ctx = _getDamageCalcContextInternal(
                config, attackerPlayerIndex, attackerMonIndex, defenderPlayerIndex, defenderMonIndex
            );

            // Type effectiveness via TypeCalcLib (internal pure, no external call). Reuse the defender
            // types already loaded into ctx instead of re-resolving the defender Mon from storage.
            uint32 scaledBasePower = TypeCalcLib.getTypeEffectiveness(moveType, ctx.defenderType1, basePower);
            if (ctx.defenderType2 != Type.None) {
                scaledBasePower = TypeCalcLib.getTypeEffectiveness(moveType, ctx.defenderType2, scaledBasePower);
            }

            // Shared damage formula (same function the external path uses)
            (damage, eventType) =
                AttackCalculator._calculateDamageCore(ctx, scaledBasePower, moveClass, volatility, rngToUse, critRate);

            if (damage > 0 && scaledBasePower > 0) {
                _dealDamageInternal(config, defenderPlayerIndex, defenderMonIndex, damage, source);
            }
        }

        // Effect gate: status move always eligible; damaging move only if it dealt damage.
        // Uses a rerolled rng so effect trigger is uncorrelated with the accuracy/crit/volatility rolls.
        if (address(effect) != address(0) && AttackCalculator.shouldApplyEffect(rng, basePower, damage, effectAccuracy))
        {
            _addEffectInternal(defenderPlayerIndex, defenderMonIndex, effect, "");
        }
    }

    function _inlineStandardAttack(
        BattleConfig storage config,
        uint256 rawMoveSlot,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderPlayerIndex,
        uint256 defenderMonIndex,
        uint256 rng
    ) internal {
        uint32 basePower = uint32((rawMoveSlot >> 248) & 0xFF);
        uint8 moveClassRaw = uint8((rawMoveSlot >> 246) & 0x3);
        uint8 moveTypeRaw = uint8((rawMoveSlot >> 240) & 0xF);
        uint8 effectAccuracy = uint8((rawMoveSlot >> 228) & 0xFF);
        address effectAddr = address(uint160(rawMoveSlot));

        _dispatchStandardAttackInternal(
            config,
            attackerPlayerIndex,
            attackerMonIndex,
            defenderPlayerIndex,
            defenderMonIndex,
            basePower,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            Type(moveTypeRaw),
            MoveClass(moveClassRaw),
            DEFAULT_CRIT_RATE,
            effectAccuracy,
            IEffect(effectAddr),
            rng,
            rawMoveSlot
        );
    }

    function dispatchStandardAttack(
        uint256 attackerPlayerIndex,
        uint256 defenderMonIndex,
        uint32 basePower,
        uint32 accuracy,
        uint32 volatility,
        Type moveType,
        MoveClass moveClass,
        uint256 critRate,
        uint8 effectAccuracy,
        IEffect effect,
        uint256 rng
    ) external returns (int32 damage, bytes32 eventType) {
        if (battleKeyForWrite == bytes32(0)) {
            revert NoWriteAllowed();
        }
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        BattleData storage battle = battleData[battleKeyForWrite];
        uint256 defenderPlayerIndex = 1 - attackerPlayerIndex;
        uint256 attackerMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, attackerPlayerIndex);

        return _dispatchStandardAttackInternal(
            config,
            attackerPlayerIndex,
            attackerMonIndex,
            defenderPlayerIndex,
            defenderMonIndex,
            basePower,
            accuracy,
            volatility,
            moveType,
            moveClass,
            critRate,
            effectAccuracy,
            effect,
            rng,
            uint256(uint160(msg.sender))
        );
    }

    function switchActiveMon(uint256 playerIndex, uint256 monToSwitchIndex) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }

        BattleConfig storage config = battleConfig[storageKeyForWrite];
        BattleData storage battle = battleData[battleKey];
        uint256 activeMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, playerIndex);

        // Use the validator to check if the switch is valid
        bool isValid;
        if (address(config.validator) == address(0)) {
            // Use inline validation (no external call)
            bool isTargetKnockedOut = _getMonState(config, playerIndex, monToSwitchIndex).isKnockedOut;
            isValid = ValidatorLogic.validateSwitch(
                battle.turnId, activeMonIndex, monToSwitchIndex, isTargetKnockedOut, DEFAULT_MONS_PER_TEAM
            );
        } else {
            // Use external validator
            isValid = config.validator.validateSwitch(battleKey, playerIndex, monToSwitchIndex);
        }
        if (isValid) {
            // Only call the internal switch function if the switch is valid
            _handleSwitch(battleKey, config, battle, playerIndex, monToSwitchIndex, activeMonIndex);

            // Check for game over and/or KOs
            (uint256 playerSwitchForTurnFlag, bool isGameOver) = _checkForGameOverOrKO(config, battle, playerIndex);
            if (isGameOver) return;

            // Set the player switch for turn flag
            battle.playerSwitchForTurnFlag = uint8(playerSwitchForTurnFlag);

            // TODO:
            // Also upstreaming more updates from `_handleSwitch` and change it to also add `_handleEffects`
        }
        // If the switch is invalid, we simply do nothing and continue execution
    }

    /// @notice Internal helper to set a player's move
    /// @dev Shared by setMove() and executeWithMoves() to avoid duplication
    function _setMoveInternal(
        BattleConfig storage config,
        uint256 playerIndex,
        uint8 moveIndex,
        uint104 salt,
        uint16 extraData
    ) internal {
        // Pack moveIndex with isRealTurn bit and apply +1 offset for regular moves
        // Regular moves (< SWITCH_MOVE_INDEX) are stored as moveIndex + 1 to avoid zero ambiguity
        uint8 storedMoveIndex = moveIndex < SWITCH_MOVE_INDEX ? moveIndex + MOVE_INDEX_OFFSET : moveIndex;
        MoveDecision memory newMove =
            MoveDecision({packedMoveIndex: storedMoveIndex | IS_REAL_TURN_BIT, extraData: extraData});

        if (playerIndex == 0) {
            config.p0Move = newMove;
            config.p0Salt = salt;
        } else {
            config.p1Move = newMove;
            config.p1Salt = salt;
        }
    }

    function setMove(bytes32 battleKey, uint256 playerIndex, uint8 moveIndex, uint104 salt, uint16 extraData)
        external
    {
        bool isInsideExecute = _turnP0Packed != 0 || _turnP1Packed != 0;

        bool isForCurrentBattle = battleKeyForWrite == battleKey;
        bytes32 storageKey = isForCurrentBattle ? storageKeyForWrite : _getStorageKey(battleKey);

        // Cache storage pointer to avoid repeated mapping lookups
        BattleConfig storage config = battleConfig[storageKey];

        if (msg.sender != address(config.moveManager) && !isForCurrentBattle) {
            revert NoWriteAllowed();
        }

        if (isInsideExecute) {
            // Mid-execute setMove (e.g. SleepStatus overwriting the victim's move with NO_OP).
            // Only update transient - it's the source of truth for all readers during execute, and the
            // data doesn't need to persist past end of tx.
            uint8 storedMoveIndex = moveIndex < SWITCH_MOVE_INDEX ? moveIndex + MOVE_INDEX_OFFSET : moveIndex;
            uint256 encoded = (uint256(storedMoveIndex) | uint256(IS_REAL_TURN_BIT)) | (uint256(extraData) << 8);
            if (playerIndex == 0) {
                _turnP0Packed = _packTurn(encoded, salt);
            } else {
                _turnP1Packed = _packTurn(encoded, salt);
            }
        } else {
            // Out-of-execute setMove (commit manager revealing across txs) - must persist to storage
            // because transient auto-clears between txs and execute() will mirror storage on entry.
            _setMoveInternal(config, playerIndex, moveIndex, salt, extraData);
        }
    }

    function computeBattleKey(address p0, address p1) public view returns (bytes32 battleKey, bytes32 pairHash) {
        pairHash = keccak256(abi.encode(p0, p1));
        if (uint256(uint160(p0)) > uint256(uint160(p1))) {
            pairHash = keccak256(abi.encode(p1, p0));
        }
        uint256 pairHashNonce = pairHashNonces[pairHash];
        battleKey = keccak256(abi.encode(pairHash, pairHashNonce));
    }

    /// @notice Check for game over and determine which player(s) need to switch next turn
    /// @dev Game-over detection is now handled immediately at KO time by _checkAndSetWinnerIfGameOver.
    ///      This function only checks if winner was already set, then handles switch flags for KO'd mons.
    function _checkForGameOverOrKO(BattleConfig storage config, BattleData storage battle, uint256 priorityPlayerIndex)
        internal
        view
        returns (uint256 playerSwitchForTurnFlag, bool isGameOver)
    {
        // Winner is set immediately in _dealDamageInternal when a KO results in game over
        if (battle.winnerIndex != 2) {
            return (playerSwitchForTurnFlag, true);
        }

        // Not a game over - check for KOs and set the player switch for turn flag
        playerSwitchForTurnFlag = 2;

        uint256 p0KOBitmap = _getKOBitmap(config, 0);
        uint256 p1KOBitmap = _getKOBitmap(config, 1);

        // Global effect context (priorityPlayerIndex == 2): check both players explicitly
        if (priorityPlayerIndex >= 2) {
            uint256 p0ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
            uint256 p1ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);
            bool isP0KO = (p0KOBitmap & (1 << p0ActiveMonIndex)) != 0;
            bool isP1KO = (p1KOBitmap & (1 << p1ActiveMonIndex)) != 0;
            if (isP0KO && !isP1KO) playerSwitchForTurnFlag = 0;
            else if (!isP0KO && isP1KO) playerSwitchForTurnFlag = 1;
            return (playerSwitchForTurnFlag, false);
        }

        uint256 otherPlayerIndex = (priorityPlayerIndex + 1) % 2;
        uint256 priorityActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, priorityPlayerIndex);
        uint256 otherActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, otherPlayerIndex);
        uint256 priorityKOBitmap = priorityPlayerIndex == 0 ? p0KOBitmap : p1KOBitmap;
        uint256 otherKOBitmap = priorityPlayerIndex == 0 ? p1KOBitmap : p0KOBitmap;
        bool isPriorityPlayerActiveMonKnockedOut = (priorityKOBitmap & (1 << priorityActiveMonIndex)) != 0;
        bool isNonPriorityPlayerActiveMonKnockedOut = (otherKOBitmap & (1 << otherActiveMonIndex)) != 0;

        // If the priority player mon is KO'ed (and the other player isn't), next turn is just for that player to switch
        if (isPriorityPlayerActiveMonKnockedOut && !isNonPriorityPlayerActiveMonKnockedOut) {
            playerSwitchForTurnFlag = priorityPlayerIndex;
        }

        // If the non-priority player mon is KO'ed (and the other player isn't), next turn is just for that player to switch
        if (!isPriorityPlayerActiveMonKnockedOut && isNonPriorityPlayerActiveMonKnockedOut) {
            playerSwitchForTurnFlag = otherPlayerIndex;
        }
    }

    /// @dev `config`/`battle`/`currentActiveMonIndex` are threaded in from the caller (both call sites
    ///      already resolved them, and `battle.activeMonIndex` can't change between then and the switch
    ///      this function performs) so we don't re-resolve the mapping pointers or re-read the index here.
    function _handleSwitch(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint256 playerIndex,
        uint256 monToSwitchIndex,
        uint256 currentActiveMonIndex
    ) internal {
        // NOTE: We will check for game over after the switch in the engine for two player turns, so we don't do it here
        // But this also means that the current flow of OnMonSwitchOut effects -> OnMonSwitchIn effects -> ability activateOnSwitch
        // will all resolve before checking for KOs or winners
        // (could break this up even more, but that's for a later version / PR)

        MonState storage currentMonState = _getMonState(config, playerIndex, currentActiveMonIndex);

        // If the current mon is not KO'ed
        // Go through each effect to see if it should be cleared after a switch,
        // If so, remove the effect and the extra data.
        // Guard each _runEffects so we don't pay its setup (storage re-resolution + count load) when
        // there's provably nothing to run: the switching mon has no effects (count == 0) or no effect
        // anywhere listens at this step (union bit clear — stat boosts now fold their OnMonSwitchOut
        // step into the union via _addStatBoostEffectSlot), and the global list is empty.
        if (!currentMonState.isKnockedOut) {
            uint256 outCount = playerIndex == 0
                ? _getMonEffectCount(config.packedP0EffectsCount, currentActiveMonIndex)
                : _getMonEffectCount(config.packedP1EffectsCount, currentActiveMonIndex);
            if (outCount > 0 && (config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.OnMonSwitchOut))) != 0) {
                _runEffects(battleKey, tempRNG, playerIndex, playerIndex, EffectStep.OnMonSwitchOut, "", outCount);
            }

            // Then run the global on mon switch out hook as well
            if (config.globalEffectsLength > 0) {
                _runEffects(battleKey, tempRNG, 2, playerIndex, EffectStep.OnMonSwitchOut, "", type(uint256).max);
            }
        }

        // Update to new active mon (we assume validateSwitch already resolved and gives us a valid target)
        battle.activeMonIndex = _setActiveMonIndex(battle.activeMonIndex, playerIndex, monToSwitchIndex);

        // Run onMonSwitchIn hook for local effects (the new active mon is monToSwitchIndex)
        uint256 inCount = playerIndex == 0
            ? _getMonEffectCount(config.packedP0EffectsCount, monToSwitchIndex)
            : _getMonEffectCount(config.packedP1EffectsCount, monToSwitchIndex);
        if (inCount > 0 && (config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.OnMonSwitchIn))) != 0) {
            _runEffects(battleKey, tempRNG, playerIndex, playerIndex, EffectStep.OnMonSwitchIn, "", inCount);
        }

        // Run onMonSwitchIn hook for global effects
        if (config.globalEffectsLength > 0) {
            _runEffects(battleKey, tempRNG, 2, playerIndex, EffectStep.OnMonSwitchIn, "", type(uint256).max);
        }

        // Run ability for the newly switched in mon as long as it's not KO'ed and as long as it's not turn 0, (execute() has a special case to run activateOnSwitch after both moves are handled)
        if (battle.turnId != 0 && !_getMonState(config, playerIndex, monToSwitchIndex).isKnockedOut) {
            _activateAbility(
                config,
                battleKey,
                _getTeamMon(config, playerIndex, monToSwitchIndex).ability,
                playerIndex,
                monToSwitchIndex
            );
        }
    }

    /// @dev Reads the current-turn move FRESH via _getCurrentTurnMove (rather than reusing the
    ///      _executeInternal top-of-turn p0TurnMove/p1TurnMove snapshot): effects like SleepStatus call
    ///      engine.setMove(...NO_OP...) to overwrite a victim's move mid-turn, so the move can change
    ///      after the snapshot and must be re-read here.
    function _handleMove(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint256 playerIndex,
        uint256 prevPlayerSwitchForTurnFlag
    ) internal returns (uint256 playerSwitchForTurnFlag) {
        MoveDecision memory move = _getCurrentTurnMove(config, playerIndex);
        int32 staminaCost;
        playerSwitchForTurnFlag = prevPlayerSwitchForTurnFlag;

        // Unpack moveIndex from packedMoveIndex (lower 7 bits, with +1 offset for regular moves)
        uint8 storedMoveIndex = move.packedMoveIndex & MOVE_INDEX_MASK;
        uint8 moveIndex = storedMoveIndex >= SWITCH_MOVE_INDEX ? storedMoveIndex : storedMoveIndex - MOVE_INDEX_OFFSET;

        // Handle shouldSkipTurn flag first and toggle it off if set
        uint256 activeMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, playerIndex);
        MonState storage currentMonState = _getMonState(config, playerIndex, activeMonIndex);
        if (currentMonState.shouldSkipTurn) {
            currentMonState.shouldSkipTurn = false;
            return playerSwitchForTurnFlag;
        }

        // If we've already determined next turn only one player has to move,
        // this implies the other player has to switch, so we can just short circuit here
        if (prevPlayerSwitchForTurnFlag == 0 || prevPlayerSwitchForTurnFlag == 1) {
            return playerSwitchForTurnFlag;
        }

        // Coerce to a switch when one is required: turn 0 (initial send-in) or active mon KO'd.
        // If the submitted move is not a switch, force a switch to mon index 0 so the battle can
        // progress instead of reverting. If mon 0 is itself invalid (KO'd), the switch-target
        // check below silently no-ops and timeout handles the stuck player.
        if ((battle.turnId == 0 || currentMonState.isKnockedOut) && moveIndex != SWITCH_MOVE_INDEX) {
            moveIndex = SWITCH_MOVE_INDEX;
            move.extraData = uint16(0);
        }

        // Handle a switch, no-op, or regular move.
        // Note: MonMoves emission moved to the top of execute() so clients always learn
        // each player's submitted move + salt, regardless of any early return below.
        if (moveIndex == SWITCH_MOVE_INDEX) {
            // Validate switch target before mutating state. Each gate silently no-ops — an invalid
            // switch leaves the player stuck (same state machine as if they missed the timeout window).
            uint256 monToSwitchIndex = uint256(move.extraData);
            uint256 teamSize = (playerIndex == 0) ? (config.teamSizes & 0x0F) : (config.teamSizes >> 4);
            if (monToSwitchIndex >= teamSize) {
                return playerSwitchForTurnFlag;
            }
            if (_getMonState(config, playerIndex, monToSwitchIndex).isKnockedOut) {
                return playerSwitchForTurnFlag;
            }
            // Disallow switching to the same mon except on turn 0 (initial send-in allows both players to pick mon 0).
            if (battle.turnId != 0 && monToSwitchIndex == activeMonIndex) {
                return playerSwitchForTurnFlag;
            }
            _handleSwitch(battleKey, config, battle, playerIndex, monToSwitchIndex, activeMonIndex);
        } else if (moveIndex == NO_OP_MOVE_INDEX) {
            // No-op: do nothing (e.g. just recover stamina)
        } else {
            // Bounds-check the move index before the array access, since `moves` is a dynamic array
            // and an OOB access would revert the whole execute(), not the single move.
            Mon storage activeMon = _getTeamMon(config, playerIndex, activeMonIndex);
            if (moveIndex >= activeMon.moves.length) {
                return playerSwitchForTurnFlag;
            }
            // Read raw 256-bit slot for this move
            uint256 rawMoveSlot = activeMon.moves[moveIndex];

            if (rawMoveSlot >> 160 != 0) {
                // === INLINE PATH ===
                // Stamina from packed params
                uint8 staminaVal = uint8((rawMoveSlot >> 236) & 0xF);
                staminaCost = int32(uint32(staminaVal));

                // Validate stamina
                uint32 baseStamina = activeMon.stats.stamina;
                int32 staminaDelta = currentMonState.staminaDelta;
                int32 currentStamina = (staminaDelta == CLEARED_MON_STATE_SENTINEL)
                    ? int32(baseStamina)
                    : int32(baseStamina) + staminaDelta;
                if (currentStamina < staminaCost) {
                    return playerSwitchForTurnFlag;
                }

                // Deduct stamina and execute (MonMoves already emitted upfront in execute())
                _deductStamina(currentMonState, staminaCost);

                uint256 defenderMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1 - playerIndex);
                _inlineStandardAttack(
                    config, rawMoveSlot, playerIndex, activeMonIndex, 1 - playerIndex, defenderMonIndex, tempRNG
                );
            } else {
                // === EXTERNAL PATH ===
                IEngine self = IEngine(address(this));
                IMoveSet moveSet = IMoveSet(address(uint160(rawMoveSlot)));

                // Call validateSpecificMoveSelection again to ensure it is still valid to execute
                bool isValid;
                bool inlineValidation = address(config.validator) == address(0);
                if (inlineValidation) {
                    uint32 baseStamina = activeMon.stats.stamina;
                    int32 staminaDelta = currentMonState.staminaDelta;
                    int256 effectiveDelta =
                        staminaDelta == CLEARED_MON_STATE_SENTINEL ? int256(0) : int256(staminaDelta);
                    uint256 currentStamina = uint256(int256(uint256(baseStamina)) + effectiveDelta);
                    uint32 moveStamina = moveSet.stamina(self, battleKey, playerIndex, activeMonIndex);
                    isValid = moveStamina <= currentStamina;
                    staminaCost = int32(moveStamina);
                } else {
                    isValid = config.validator.validateSpecificMoveSelection(
                        battleKey, moveIndex, playerIndex, move.extraData
                    );
                }
                if (!isValid) {
                    return playerSwitchForTurnFlag;
                }

                // Deduct stamina and execute (MonMoves already emitted upfront in execute())
                if (!inlineValidation) {
                    staminaCost = int32(moveSet.stamina(self, battleKey, playerIndex, activeMonIndex));
                }
                _deductStamina(currentMonState, staminaCost);

                uint256 defenderMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1 - playerIndex);
                moveSet.move(self, battleKey, playerIndex, activeMonIndex, defenderMonIndex, move.extraData, tempRNG);
            }
        }

        // Only check for Game Over / KO if a KO occurred during the move
        if (koOccurredFlag != 0) {
            koOccurredFlag = 0;
            (playerSwitchForTurnFlag,) = _checkForGameOverOrKO(config, battle, playerIndex);
        }
        return playerSwitchForTurnFlag;
    }

    /**
     * effect index: the target index to filter effects for (0/1/2)
     * player index: the player to pass into the effects args
     */
    function _runEffects(
        bytes32 battleKey,
        uint256 rng,
        uint256 effectIndex,
        uint256 playerIndex,
        EffectStep round,
        bytes memory extraEffectsData,
        uint256 effectsCountHint
    ) internal {
        BattleData storage battle = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKeyForWrite];

        // Get active mon indices for both players (passed to all effect hooks)
        uint256 p0ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
        uint256 p1ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);

        uint256 monIndex = (playerIndex == 2) ? 0 : _unpackActiveMonIndex(battle.activeMonIndex, playerIndex);

        // Pre-compute loop metadata once (baseSlot, dirtyBit)
        // Bit 0: global, Bits 1-8: P0 mons 0-7, Bits 9-16: P1 mons 0-7
        uint256 baseSlot;
        uint256 dirtyBit;
        if (effectIndex == 2) {
            dirtyBit = 1;
        } else if (effectIndex == 0) {
            baseSlot = _getEffectSlotIndex(monIndex, 0);
            dirtyBit = 1 << (1 + monIndex);
        } else {
            baseSlot = _getEffectSlotIndex(monIndex, 0);
            dirtyBit = 1 << (9 + monIndex);
        }

        // Callers whose resolved count is for THIS list (the active mon, or the global list) thread it
        // in to skip the initial read; everyone else passes the sentinel and we resolve it here. Note:
        // callers like updateMonState/dealDamage hold a count for a possibly-benched mon, so they MUST
        // pass the sentinel — the count below is always for `monIndex` (this player's active mon).
        uint256 effectsCount = effectsCountHint;
        if (effectsCount == type(uint256).max) {
            effectsCount = _loadEffectsCount(config, effectIndex, monIndex);
        }

        // Iterate directly over storage, skipping tombstones
        uint256 i = 0;
        while (i < effectsCount) {
            // Read effect directly from storage (mapping ref can't be pre-resolved across branches)
            EffectInstance storage eff;
            uint256 slotIndex = (effectIndex == 2) ? i : baseSlot + i;
            if (effectIndex == 2) {
                eff = config.globalEffects[slotIndex];
            } else if (effectIndex == 0) {
                eff = config.p0Effects[slotIndex];
            } else {
                eff = config.p1Effects[slotIndex];
            }

            // Skip tombstoned effects
            if (address(eff.effect) != TOMBSTONE_ADDRESS) {
                _runSingleEffect(
                    config,
                    rng,
                    effectIndex,
                    playerIndex,
                    monIndex,
                    round,
                    extraEffectsData,
                    eff.effect,
                    eff.stepsBitmap,
                    eff.data,
                    uint96(slotIndex),
                    p0ActiveMonIndex,
                    p1ActiveMonIndex
                );

                // Re-read count if a new effect was added during this iteration
                if (effectsDirtyBitmap & dirtyBit != 0) {
                    effectsCount = _loadEffectsCount(config, effectIndex, monIndex);
                    effectsDirtyBitmap &= ~dirtyBit;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    function _runSingleEffect(
        BattleConfig storage config,
        uint256 rng,
        uint256 effectIndex,
        uint256 playerIndex,
        uint256 monIndex,
        EffectStep round,
        bytes memory extraEffectsData,
        IEffect effect,
        uint16 stepsBitmap,
        bytes32 data,
        uint96 slotIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) private {
        // Use stored bitmap instead of external call to shouldRunAtStep()
        if ((stepsBitmap & (1 << uint8(round))) == 0) {
            return;
        }

        // Inline execution for address(0) effects (StaminaRegen)
        if (address(effect) == address(0)) {
            _inlineStaminaRegen(config, round, playerIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);
            return;
        }

        // Inline execution for stat-boost sentinel entries. Only OnMonSwitchOut is in their steps
        // bitmap; a temp boost is dropped on switch-out and the mon's stats recomputed from the
        // remaining permanent sources (mirrors the legacy StatBoosts.onMonSwitchOut path).
        if (address(effect) == STAT_BOOST_ADDRESS) {
            if (!StatBoostLib.isPerm(data)) {
                _inlineStatBoostSwitchOut(config, effectIndex, monIndex);
            }
            return;
        }

        // Run the effect and get result
        (bytes32 updatedExtraData, bool removeAfterRun) = _executeEffectHook(
            battleKeyForWrite,
            effect,
            rng,
            data,
            playerIndex,
            monIndex,
            round,
            extraEffectsData,
            p0ActiveMonIndex,
            p1ActiveMonIndex
        );

        // If we need to remove or update the effect
        if (removeAfterRun || updatedExtraData != data) {
            _updateOrRemoveEffect(
                config, effectIndex, monIndex, effect, data, slotIndex, updatedExtraData, removeAfterRun
            );
        }
    }

    function _executeEffectHook(
        bytes32 battleKey,
        IEffect effect,
        uint256 rng,
        bytes32 data,
        uint256 playerIndex,
        uint256 monIndex,
        EffectStep round,
        bytes memory extraEffectsData,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) private returns (bytes32 updatedExtraData, bool removeAfterRun) {
        IEngine self = IEngine(address(this));
        if (round == EffectStep.RoundStart) {
            return
                effect.onRoundStart(
                    self, battleKey, rng, data, playerIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex
                );
        } else if (round == EffectStep.RoundEnd) {
            return
                effect.onRoundEnd(self, battleKey, rng, data, playerIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);
        } else if (round == EffectStep.OnMonSwitchIn) {
            return
                effect.onMonSwitchIn(
                    self, battleKey, rng, data, playerIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex
                );
        } else if (round == EffectStep.OnMonSwitchOut) {
            return effect.onMonSwitchOut(
                self, battleKey, rng, data, playerIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex
            );
        } else if (round == EffectStep.AfterDamage) {
            (int32 damage, uint256 source) = abi.decode(extraEffectsData, (int32, uint256));
            return effect.onAfterDamage(
                self,
                battleKey,
                rng,
                data,
                playerIndex,
                monIndex,
                p0ActiveMonIndex,
                p1ActiveMonIndex,
                damage,
                source
            );
        } else if (round == EffectStep.PreDamage) {
            uint256 source = abi.decode(extraEffectsData, (uint256));
            return effect.onPreDamage(
                self,
                battleKey,
                rng,
                data,
                playerIndex,
                monIndex,
                p0ActiveMonIndex,
                p1ActiveMonIndex,
                source
            );
        } else if (round == EffectStep.AfterMove) {
            return
                effect.onAfterMove(
                    self, battleKey, rng, data, playerIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex
                );
        } else if (round == EffectStep.OnUpdateMonState) {
            (uint256 statePlayerIndex, uint256 stateMonIndex, MonStateIndexName stateVarIndex, int32 valueToAdd) =
                abi.decode(extraEffectsData, (uint256, uint256, MonStateIndexName, int32));
            return effect.onUpdateMonState(
                self,
                battleKey,
                rng,
                data,
                statePlayerIndex,
                stateMonIndex,
                p0ActiveMonIndex,
                p1ActiveMonIndex,
                stateVarIndex,
                valueToAdd
            );
        }
    }

    function _updateOrRemoveEffect(
        BattleConfig storage config,
        uint256 effectIndex,
        uint256 monIndex,
        IEffect, // effect - unused with tombstone approach
        bytes32, // originalData - unused with tombstone approach
        uint96 slotIndex,
        bytes32 updatedExtraData,
        bool removeAfterRun
    ) private {
        // With tombstones, indices are stable - use slot index directly for all effect types
        if (removeAfterRun) {
            removeEffect(effectIndex, monIndex, uint256(slotIndex));
        } else {
            // Update the data at the slot
            if (effectIndex == 2) {
                config.globalEffects[slotIndex].data = updatedExtraData;
            } else if (effectIndex == 0) {
                config.p0Effects[slotIndex].data = updatedExtraData;
            } else {
                config.p1Effects[slotIndex].data = updatedExtraData;
            }
        }
    }

    function _handleEffects(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint256 rng,
        uint256 effectIndex,
        uint256 playerIndex,
        EffectStep round,
        EffectRunCondition condition,
        uint256 prevPlayerSwitchForTurnFlag
    ) private returns (uint256 playerSwitchForTurnFlag) {
        // Check for Game Over and return early if so
        playerSwitchForTurnFlag = prevPlayerSwitchForTurnFlag;
        if (battle.winnerIndex != 2) {
            return playerSwitchForTurnFlag;
        }

        // Short-circuit if no effects exist for this target (skip both effects and KO check).
        // The count we resolve here is for the active mon (or the global list), which is exactly
        // the list _runEffects iterates — so we thread it in to skip _runEffects' own initial read.
        uint256 effectsCount;
        if (effectIndex == 2) {
            effectsCount = config.globalEffectsLength;
        } else {
            uint256 monIndex = _unpackActiveMonIndex(battle.activeMonIndex, playerIndex);

            // Check if mon is KOed (reuse monIndex we already computed)
            if (condition == EffectRunCondition.SkipIfGameOverOrMonKO) {
                if (_getMonState(config, playerIndex, monIndex).isKnockedOut) {
                    return playerSwitchForTurnFlag;
                }
            }

            // Check effect count for this mon
            effectsCount = (effectIndex == 0)
                ? _getMonEffectCount(config.packedP0EffectsCount, monIndex)
                : _getMonEffectCount(config.packedP1EffectsCount, monIndex);
        }

        if (effectsCount > 0) {
            // Run the effects (thread the resolved count so _runEffects skips its own initial read)
            _runEffects(battleKey, rng, effectIndex, playerIndex, round, "", effectsCount);
        }

        // Only check for Game Over / KO if a KO actually occurred since last check
        if (koOccurredFlag != 0) {
            koOccurredFlag = 0;
            (playerSwitchForTurnFlag,) = _checkForGameOverOrKO(config, battle, playerIndex);
        }
        return playerSwitchForTurnFlag;
    }

    function computePriorityPlayerIndex(bytes32 battleKey, uint256 rng) public view returns (uint256) {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        BattleData storage battle = battleData[battleKey];
        return _computePriorityPlayerIndex(
            config, battle, battleKey, rng, _getCurrentTurnMove(config, 0), _getCurrentTurnMove(config, 1)
        );
    }

    /// @dev Internal priority computation that accepts already-resolved storage pointers and
    ///      already-decoded current-turn moves. _executeInternal calls this to avoid re-resolving
    ///      the storage key, re-materializing storage refs, and re-reading both moves from
    ///      transient/storage via _getCurrentTurnMove.
    function _computePriorityPlayerIndex(
        BattleConfig storage config,
        BattleData storage battle,
        bytes32 battleKey,
        uint256 rng,
        MoveDecision memory p0TurnMove,
        MoveDecision memory p1TurnMove
    ) private view returns (uint256) {
        uint8 p0StoredIndex = p0TurnMove.packedMoveIndex & MOVE_INDEX_MASK;
        uint8 p1StoredIndex = p1TurnMove.packedMoveIndex & MOVE_INDEX_MASK;
        uint8 p0MoveIndex = p0StoredIndex >= SWITCH_MOVE_INDEX ? p0StoredIndex : p0StoredIndex - MOVE_INDEX_OFFSET;
        uint8 p1MoveIndex = p1StoredIndex >= SWITCH_MOVE_INDEX ? p1StoredIndex : p1StoredIndex - MOVE_INDEX_OFFSET;

        uint256 p0ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
        uint256 p1ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);

        uint256 p0Priority = _getMovePriority(config, battleKey, 0, p0MoveIndex, p0ActiveMonIndex);
        uint256 p1Priority = _getMovePriority(config, battleKey, 1, p1MoveIndex, p1ActiveMonIndex);

        // Determine priority based on (in descending order of importance):
        // - the higher priority tier
        // - within same priority, the higher speed
        // - if both are tied, use the rng value
        if (p0Priority > p1Priority) {
            return 0;
        } else if (p0Priority < p1Priority) {
            return 1;
        }
        // Calculate speeds by combining base stats with deltas
        // Note: speedDelta may be sentinel value (CLEARED_MON_STATE_SENTINEL) which should be treated as 0
        int32 p0SpeedDelta = _getMonState(config, 0, p0ActiveMonIndex).speedDelta;
        int32 p1SpeedDelta = _getMonState(config, 1, p1ActiveMonIndex).speedDelta;
        uint32 p0MonSpeed = uint32(
            int32(_getTeamMon(config, 0, p0ActiveMonIndex).stats.speed)
                + (p0SpeedDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : p0SpeedDelta)
        );
        uint32 p1MonSpeed = uint32(
            int32(_getTeamMon(config, 1, p1ActiveMonIndex).stats.speed)
                + (p1SpeedDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : p1SpeedDelta)
        );
        if (p0MonSpeed > p1MonSpeed) {
            return 0;
        } else if (p0MonSpeed < p1MonSpeed) {
            return 1;
        }
        return rng % 2;
    }

    function _getMovePriority(
        BattleConfig storage config,
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 moveIndex,
        uint256 activeMonIndex
    ) private view returns (uint256) {
        if (moveIndex == SWITCH_MOVE_INDEX || moveIndex == NO_OP_MOVE_INDEX) {
            return SWITCH_PRIORITY;
        }
        // Out-of-bounds moveIndex would revert on the `moves[moveIndex]` access; treat as the
        // same priority as a no-op so _handleMove can silently skip it later.
        Mon storage attackerMon = _getTeamMon(config, playerIndex, activeMonIndex);
        if (moveIndex >= attackerMon.moves.length) {
            return SWITCH_PRIORITY;
        }
        uint256 raw = attackerMon.moves[moveIndex];
        if (raw >> 160 != 0) {
            return DEFAULT_PRIORITY + ((raw >> 244) & 0x3);
        }
        return IMoveSet(address(uint160(raw))).priority(IEngine(address(this)), battleKey, playerIndex);
    }

    /// @dev Resolves the storage key for a battle, using the cached transient value during execution
    function _resolveStorageKey(bytes32 battleKey) internal view returns (bytes32) {
        bytes32 cached = storageKeyForWrite;
        return cached != bytes32(0) ? cached : _getStorageKey(battleKey);
    }

    /**
     * - Helper functions for packing/unpacking activeMonIndex
     */
    function _packActiveMonIndices(uint8 player0Index, uint8 player1Index) internal pure returns (uint16) {
        return uint16(player0Index) | (uint16(player1Index) << 8);
    }

    function _unpackActiveMonIndex(uint16 packed, uint256 playerIndex) internal pure returns (uint256) {
        if (playerIndex == 0) {
            return uint256(uint8(packed));
        } else {
            return uint256(uint8(packed >> 8));
        }
    }

    function _setActiveMonIndex(uint16 packed, uint256 playerIndex, uint256 monIndex) internal pure returns (uint16) {
        if (playerIndex == 0) {
            return (packed & 0xFF00) | uint16(uint8(monIndex));
        } else {
            return (packed & 0x00FF) | (uint16(uint8(monIndex)) << 8);
        }
    }

    // Helper functions for per-mon effect count packing
    function _getMonEffectCount(uint96 packedCounts, uint256 monIndex) private pure returns (uint256) {
        return (uint256(packedCounts) >> (monIndex * PLAYER_EFFECT_BITS)) & EFFECT_COUNT_MASK;
    }

    function _setMonEffectCount(uint96 packedCounts, uint256 monIndex, uint256 count) private pure returns (uint96) {
        uint256 shift = monIndex * PLAYER_EFFECT_BITS;
        uint256 cleared = uint256(packedCounts) & ~(EFFECT_COUNT_MASK << shift);
        return uint96(cleared | (count << shift));
    }

    function _getEffectSlotIndex(uint256 monIndex, uint256 effectIndex) private pure returns (uint256) {
        return EFFECT_SLOTS_PER_MON * monIndex + effectIndex;
    }

    // Helper functions for accessing team and monState mappings
    function _getTeamMon(BattleConfig storage config, uint256 playerIndex, uint256 monIndex)
        private
        view
        returns (Mon storage)
    {
        return playerIndex == 0 ? config.p0Team[monIndex] : config.p1Team[monIndex];
    }

    /// @dev Caller passes `config` so each of the 3 call sites per turn doesn't re-resolve
    ///      the `battleConfig[storageKeyForWrite]` mapping separately. The RoundEnd path
    ///      additionally reads `battleData[battleKeyForWrite]`, but that's only one of two
    ///      branches and threading `battle` through `_runSingleEffect` (the other caller)
    ///      added more bytecode/parameter overhead than it saved on external-effect
    ///      benchmarks, so we resolve it locally here.
    function _inlineStaminaRegen(
        BattleConfig storage config,
        EffectStep round,
        uint256 playerIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) private {
        if (round == EffectStep.RoundEnd) {
            if (!StaminaRegenLogic._shouldRegenOnRoundEnd(battleData[battleKeyForWrite].playerSwitchForTurnFlag)) return;
            _inlineRegenStaminaForMon(config, 0, p0ActiveMonIndex);
            _inlineRegenStaminaForMon(config, 1, p1ActiveMonIndex);
        } else if (round == EffectStep.AfterMove) {
            // Fetch packedMoveIndex via helper - resolves to transient during executeWithMoves, storage otherwise.
            uint8 packedMoveIndex = _getCurrentTurnMove(config, playerIndex).packedMoveIndex;
            if (!StaminaRegenLogic._isRestingMove(packedMoveIndex)) return;
            _inlineRegenStaminaForMon(config, playerIndex, monIndex);
        }
    }

    /// @dev Mirrors the storage write that StaminaRegenLogic used to do, then fires
    /// OnUpdateMonState so per-mon listeners (e.g. Dreamcatcher) see the +1 stamina —
    /// matching the external StaminaRegen effect path, which goes through updateMonState.
    function _inlineRegenStaminaForMon(
        BattleConfig storage config,
        uint256 playerIndex,
        uint256 monIndex
    ) private {
        MonState storage monState = playerIndex == 0 ? config.p0States[monIndex] : config.p1States[monIndex];
        if (monState.staminaDelta >= 0) return;
        monState.staminaDelta += 1;
        uint256 effectCount = playerIndex == 0
            ? _getMonEffectCount(config.packedP0EffectsCount, monIndex)
            : _getMonEffectCount(config.packedP1EffectsCount, monIndex);
        if (effectCount > 0
            && (config.playerEffectStepsUnion & uint16(1 << uint8(EffectStep.OnUpdateMonState))) != 0) {
            _runEffects(
                battleKeyForWrite,
                tempRNG,
                playerIndex,
                playerIndex,
                EffectStep.OnUpdateMonState,
                abi.encode(playerIndex, monIndex, MonStateIndexName.Stamina, int32(1)),
                type(uint256).max
            );
        }
    }

    function _getMonState(BattleConfig storage config, uint256 playerIndex, uint256 monIndex)
        private
        view
        returns (MonState storage)
    {
        return playerIndex == 0 ? config.p0States[monIndex] : config.p1States[monIndex];
    }

    function _deductStamina(MonState storage state, int32 cost) private {
        state.staminaDelta = (state.staminaDelta == CLEARED_MON_STATE_SENTINEL) ? -cost : state.staminaDelta - cost;
    }

    function _emitMonMoves(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        MoveDecision memory p0Move,
        MoveDecision memory p1Move
    ) private {
        // Skip the emit entirely if neither player submitted this turn.
        if (p0Move.packedMoveIndex == 0 && p1Move.packedMoveIndex == 0) return;

        uint256 p0MonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
        uint256 p1MonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);

        uint256 packedMoves = uint256(uint8(p0MonIndex)) | (uint256(p0Move.packedMoveIndex) << 8)
            | (uint256(p0Move.extraData) << 16) | (uint256(uint8(p1MonIndex)) << 32)
            | (uint256(p1Move.packedMoveIndex) << 40) | (uint256(p1Move.extraData) << 48);

        uint256 packedSalts =
            uint256(_getCurrentTurnSalt(config, 0)) | (uint256(_getCurrentTurnSalt(config, 1)) << 104);

        emit MonMoves(battleKey, packedMoves, packedSalts);
    }

    // Helper functions for KO bitmap management (packed: lower 8 bits = p0, upper 8 bits = p1)
    function _getKOBitmap(BattleConfig storage config, uint256 playerIndex) private view returns (uint256) {
        return playerIndex == 0 ? (config.koBitmaps & 0xFF) : (config.koBitmaps >> 8);
    }

    function _setMonKO(BattleConfig storage config, uint256 playerIndex, uint256 monIndex) private {
        uint256 bit = 1 << monIndex;
        if (playerIndex == 0) {
            config.koBitmaps = config.koBitmaps | uint16(bit);
        } else {
            config.koBitmaps = config.koBitmaps | uint16(bit << 8);
        }
    }

    function _clearMonKO(BattleConfig storage config, uint256 playerIndex, uint256 monIndex) private {
        uint256 bit = 1 << monIndex;
        if (playerIndex == 0) {
            config.koBitmaps = config.koBitmaps & uint16(~bit);
        } else {
            config.koBitmaps = config.koBitmaps & uint16(~(bit << 8));
        }
    }

    function _loadEffectsCount(BattleConfig storage config, uint256 effectIndex, uint256 monIndex)
        private
        view
        returns (uint256)
    {
        if (effectIndex == 2) return config.globalEffectsLength;
        if (effectIndex == 0) return _getMonEffectCount(config.packedP0EffectsCount, monIndex);
        return _getMonEffectCount(config.packedP1EffectsCount, monIndex);
    }

    /**
     * - Effect filtering helper
     */
    function _getEffectsForTarget(bytes32 storageKey, uint256 targetIndex, uint256 monIndex)
        internal
        view
        returns (EffectInstance[] memory, uint256[] memory)
    {
        BattleConfig storage config = battleConfig[storageKey];

        if (targetIndex == 2) {
            // Global query - allocate max size and populate in single pass
            uint256 globalEffectsLength = config.globalEffectsLength;
            EffectInstance[] memory globalResult = new EffectInstance[](globalEffectsLength);
            uint256[] memory globalIndices = new uint256[](globalEffectsLength);
            uint256 globalIdx = 0;
            for (uint256 i = 0; i < globalEffectsLength;) {
                if (address(config.globalEffects[i].effect) != TOMBSTONE_ADDRESS) {
                    globalResult[globalIdx] = config.globalEffects[i];
                    globalIndices[globalIdx] = i;
                    unchecked {
                        ++globalIdx;
                    }
                }
                unchecked {
                    ++i;
                }
            }
            // Resize arrays to actual count
            assembly ("memory-safe") {
                mstore(globalResult, globalIdx)
                mstore(globalIndices, globalIdx)
            }
            return (globalResult, globalIndices);
        }

        // Player query - allocate max size and populate in single pass
        uint96 packedCounts = targetIndex == 0 ? config.packedP0EffectsCount : config.packedP1EffectsCount;
        uint256 monEffectCount = _getMonEffectCount(packedCounts, monIndex);
        uint256 baseSlot = _getEffectSlotIndex(monIndex, 0);
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;

        EffectInstance[] memory result = new EffectInstance[](monEffectCount);
        uint256[] memory indices = new uint256[](monEffectCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < monEffectCount;) {
            uint256 slotIndex = baseSlot + i;
            if (address(effects[slotIndex].effect) != TOMBSTONE_ADDRESS) {
                result[idx] = effects[slotIndex];
                indices[idx] = slotIndex;
                unchecked {
                    ++idx;
                }
            }
            unchecked {
                ++i;
            }
        }

        // Resize arrays to actual count
        assembly ("memory-safe") {
            mstore(result, idx)
            mstore(indices, idx)
        }
        return (result, indices);
    }

    /**
     * - Getters to simplify read access for other components
     */
    function getBattle(bytes32 battleKey) external view returns (BattleConfigView memory, BattleData memory) {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        BattleData storage data = battleData[battleKey];

        // Build global effects array (single pass, skip tombstones)
        uint256 globalLen = config.globalEffectsLength;
        EffectInstance[] memory globalEffects = new EffectInstance[](globalLen);
        uint256 gIdx = 0;
        for (uint256 i = 0; i < globalLen;) {
            if (address(config.globalEffects[i].effect) != TOMBSTONE_ADDRESS) {
                globalEffects[gIdx] = config.globalEffects[i];
                unchecked {
                    ++gIdx;
                }
            }
            unchecked {
                ++i;
            }
        }
        // Resize array to actual count
        assembly ("memory-safe") {
            mstore(globalEffects, gIdx)
        }

        // Build player effects arrays by iterating through all mons
        uint8 teamSizes = config.teamSizes;
        uint256 p0TeamSize = teamSizes & 0xF;
        uint256 p1TeamSize = (teamSizes >> 4) & 0xF;

        EffectInstance[][] memory p0Effects =
            _buildPlayerEffectsArray(config.p0Effects, config.packedP0EffectsCount, p0TeamSize);
        EffectInstance[][] memory p1Effects =
            _buildPlayerEffectsArray(config.p1Effects, config.packedP1EffectsCount, p1TeamSize);

        // Build teams array from mappings
        Mon[][] memory teams = new Mon[][](2);
        teams[0] = new Mon[](p0TeamSize);
        teams[1] = new Mon[](p1TeamSize);
        for (uint256 i = 0; i < p0TeamSize;) {
            teams[0][i] = config.p0Team[i];
            unchecked {
                ++i;
            }
        }
        for (uint256 i = 0; i < p1TeamSize;) {
            teams[1][i] = config.p1Team[i];
            unchecked {
                ++i;
            }
        }

        // Build monStates array from mappings
        MonState[][] memory monStates = new MonState[][](2);
        monStates[0] = new MonState[](p0TeamSize);
        monStates[1] = new MonState[](p1TeamSize);
        for (uint256 i = 0; i < p0TeamSize;) {
            monStates[0][i] = config.p0States[i];
            unchecked {
                ++i;
            }
        }
        for (uint256 i = 0; i < p1TeamSize;) {
            monStates[1][i] = config.p1States[i];
            unchecked {
                ++i;
            }
        }

        // Build globalKV entries from the packed key buffer, bounded by the per-battle count.
        uint256 kvCount = config.globalKVCount;
        GlobalKVEntry[] memory globalKVEntries = new GlobalKVEntry[](kvCount);
        uint256 slotCount = (kvCount + 3) >> 2;
        for (uint256 s; s < slotCount;) {
            uint256 packedSlot = globalKVKeySlots[storageKey][s];
            uint256 base = s << 2;
            uint256 remaining = kvCount - base > 4 ? 4 : kvCount - base;
            for (uint256 j; j < remaining;) {
                uint64 k = uint64(packedSlot >> (j * 64));
                globalKVEntries[base + j] = GlobalKVEntry({key: k, value: globalKV[storageKey][k]});
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++s;
            }
        }

        // Frontend hydration: passthrough to registry for level/exp on both teams.
        // After _handleGameOver -> _freeStorageKey, the storageKey indirection is
        // dropped and a subsequent getBattle(battleKey) reads an empty config row
        // (since the battle had been using a recycled slot). battleData survives
        // (keyed directly by battleKey), so we still return the final state — we
        // just skip the registry call when teamRegistry has zeroed out.
        (TeamLevelInfo memory p0Levels, TeamLevelInfo memory p1Levels) =
            _getTeamLevels(config.teamRegistry, data.p0, data.p0TeamIndex, data.p1, data.p1TeamIndex);

        BattleConfigView memory configView = BattleConfigView({
            validator: config.validator,
            rngOracle: config.rngOracle,
            moveManager: config.moveManager,
            globalEffectsLength: config.globalEffectsLength,
            packedP0EffectsCount: config.packedP0EffectsCount,
            packedP1EffectsCount: config.packedP1EffectsCount,
            teamSizes: config.teamSizes,
            startTimestamp: config.startTimestamp,
            p0Salt: config.p0Salt,
            p1Salt: config.p1Salt,
            p0TeamIndex: data.p0TeamIndex,
            p1TeamIndex: data.p1TeamIndex,
            p0Move: config.p0Move,
            p1Move: config.p1Move,
            globalEffects: globalEffects,
            p0Effects: p0Effects,
            p1Effects: p1Effects,
            teams: teams,
            monStates: monStates,
            globalKVEntries: globalKVEntries,
            p0Levels: p0Levels,
            p1Levels: p1Levels
        });

        return (configView, data);
    }

    function _buildPlayerEffectsArray(
        mapping(uint256 => EffectInstance) storage effects,
        uint96 packedCounts,
        uint256 teamSize
    ) private view returns (EffectInstance[][] memory) {
        // Allocate outer array for each mon
        EffectInstance[][] memory result = new EffectInstance[][](teamSize);

        for (uint256 m = 0; m < teamSize;) {
            uint256 monCount = _getMonEffectCount(packedCounts, m);
            uint256 baseSlot = _getEffectSlotIndex(m, 0);

            // Allocate max size for this mon's effects
            EffectInstance[] memory monEffects = new EffectInstance[](monCount);
            uint256 idx = 0;
            for (uint256 i = 0; i < monCount;) {
                if (address(effects[baseSlot + i].effect) != TOMBSTONE_ADDRESS) {
                    monEffects[idx] = effects[baseSlot + i];
                    unchecked {
                        ++idx;
                    }
                }
                unchecked {
                    ++i;
                }
            }

            // Resize array to actual count
            assembly ("memory-safe") {
                mstore(monEffects, idx)
            }
            result[m] = monEffects;
            unchecked {
                ++m;
            }
        }

        return result;
    }

    function _getTeamLevels(
        ITeamRegistry registry,
        address p0,
        uint256 p0TeamIndex,
        address p1,
        uint256 p1TeamIndex
    ) internal view returns (TeamLevelInfo memory p0Levels, TeamLevelInfo memory p1Levels) {
        if (address(registry) == address(0)) {
            uint256[] memory empty = new uint256[](0);
            p0Levels = TeamLevelInfo({monIds: empty, exp: empty, levels: empty});
            p1Levels = TeamLevelInfo({monIds: empty, exp: empty, levels: empty});
            return (p0Levels, p1Levels);
        }
        (
            uint256[] memory p0MonIds,
            uint256[] memory p0Exp,
            uint256[] memory p0LevelArr,
            uint256[] memory p1MonIds,
            uint256[] memory p1Exp,
            uint256[] memory p1LevelArr
        ) = registry.getExpAndLevelsForTeams(p0, p0TeamIndex, p1, p1TeamIndex);
        p0Levels = TeamLevelInfo({monIds: p0MonIds, exp: p0Exp, levels: p0LevelArr});
        p1Levels = TeamLevelInfo({monIds: p1MonIds, exp: p1Exp, levels: p1LevelArr});
    }

    /// @notice Validates a player move, handling both inline validation (when validator is address(0)) and external validators
    /// @dev This allows callers like CPU to validate moves without needing to handle the address(0) case themselves
    function validatePlayerMoveForBattle(bytes32 battleKey, uint256 moveIndex, uint256 playerIndex, uint16 extraData)
        external
        returns (bool)
    {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];

        // If external validator exists, delegate to it
        if (address(config.validator) != address(0)) {
            return config.validator.validatePlayerMove(battleKey, moveIndex, playerIndex, extraData);
        }

        // Inline validation when validator is address(0)
        BattleData storage data = battleData[battleKey];
        uint256 activeMonIndex = _unpackActiveMonIndex(data.activeMonIndex, playerIndex);
        MonState storage activeMonState = _getMonState(config, playerIndex, activeMonIndex);

        // Basic validation (bounds, forced switch checks)
        (, bool isNoOp, bool isSwitch, bool isRegularMove, bool basicValid) = ValidatorLogic.validatePlayerMoveBasics(
            moveIndex, data.turnId, activeMonState.isKnockedOut, DEFAULT_MOVES_PER_MON
        );

        if (!basicValid) {
            return false;
        }

        // No-op is always valid if basic validation passed
        if (isNoOp) {
            return true;
        }

        // Switch validation
        if (isSwitch) {
            uint256 monToSwitchIndex = uint256(extraData);
            bool isTargetKnockedOut = _getMonState(config, playerIndex, monToSwitchIndex).isKnockedOut;
            return ValidatorLogic.validateSwitch(
                data.turnId, activeMonIndex, monToSwitchIndex, isTargetKnockedOut, DEFAULT_MONS_PER_TEAM
            );
        }

        // Regular move validation
        if (isRegularMove) {
            Mon storage activeMon = _getTeamMon(config, playerIndex, activeMonIndex);
            uint256 rawMoveSlot = activeMon.moves[moveIndex];
            uint32 baseStamina = activeMon.stats.stamina;
            int32 staminaDelta = activeMonState.staminaDelta;
            return ValidatorLogic.validateSpecificMoveSelection(
                IEngine(address(this)),
                battleKey,
                rawMoveSlot,
                playerIndex,
                activeMonIndex,
                extraData,
                baseStamina,
                staminaDelta
            );
        }

        return true;
    }

    function getMonValueForBattle(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex
    ) external view returns (uint32) {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        Mon storage mon = _getTeamMon(config, playerIndex, monIndex);
        if (stateVarIndex == MonStateIndexName.Hp) {
            return mon.stats.hp;
        } else if (stateVarIndex == MonStateIndexName.Stamina) {
            return mon.stats.stamina;
        } else if (stateVarIndex == MonStateIndexName.Speed) {
            return mon.stats.speed;
        } else if (stateVarIndex == MonStateIndexName.Attack) {
            return mon.stats.attack;
        } else if (stateVarIndex == MonStateIndexName.Defense) {
            return mon.stats.defense;
        } else if (stateVarIndex == MonStateIndexName.SpecialAttack) {
            return mon.stats.specialAttack;
        } else if (stateVarIndex == MonStateIndexName.SpecialDefense) {
            return mon.stats.specialDefense;
        } else if (stateVarIndex == MonStateIndexName.Type1) {
            return uint32(mon.stats.type1);
        } else if (stateVarIndex == MonStateIndexName.Type2) {
            return uint32(mon.stats.type2);
        } else {
            return 0;
        }
    }

    function getTeamSize(bytes32 battleKey, uint256 playerIndex) external view returns (uint256) {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        uint8 teamSizes = battleConfig[storageKey].teamSizes;
        return (playerIndex == 0) ? (teamSizes & 0x0F) : (teamSizes >> 4);
    }

    function getMoveForMonForBattle(bytes32 battleKey, uint256 playerIndex, uint256 monIndex, uint256 moveIndex)
        external
        view
        returns (uint256)
    {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        return _getTeamMon(config, playerIndex, monIndex).moves[moveIndex];
    }

    function getMoveDecisionForBattleState(bytes32 battleKey, uint256 playerIndex)
        external
        view
        returns (MoveDecision memory)
    {
        BattleConfig storage config = battleConfig[_resolveStorageKey(battleKey)];
        return _getCurrentTurnMove(config, playerIndex);
    }

    function getMonStatsForBattle(bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        external
        view
        returns (MonStats memory)
    {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        return _getTeamMon(config, playerIndex, monIndex).stats;
    }

    function getMonStateForBattle(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex
    ) external view returns (int32) {
        BattleConfig storage config = battleConfig[_resolveStorageKey(battleKey)];
        return _readMonStateDelta(config, playerIndex, monIndex, stateVarIndex);
    }

    function _readMonStateDelta(
        BattleConfig storage config,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex
    ) private view returns (int32) {
        MonState storage monState = _getMonState(config, playerIndex, monIndex);
        int32 value;

        if (stateVarIndex == MonStateIndexName.Hp) {
            value = monState.hpDelta;
        } else if (stateVarIndex == MonStateIndexName.Stamina) {
            value = monState.staminaDelta;
        } else if (stateVarIndex == MonStateIndexName.Speed) {
            value = monState.speedDelta;
        } else if (stateVarIndex == MonStateIndexName.Attack) {
            value = monState.attackDelta;
        } else if (stateVarIndex == MonStateIndexName.Defense) {
            value = monState.defenceDelta;
        } else if (stateVarIndex == MonStateIndexName.SpecialAttack) {
            value = monState.specialAttackDelta;
        } else if (stateVarIndex == MonStateIndexName.SpecialDefense) {
            value = monState.specialDefenceDelta;
        } else if (stateVarIndex == MonStateIndexName.IsKnockedOut) {
            return monState.isKnockedOut ? int32(1) : int32(0);
        } else if (stateVarIndex == MonStateIndexName.ShouldSkipTurn) {
            return monState.shouldSkipTurn ? int32(1) : int32(0);
        } else {
            return int32(0);
        }

        // Return 0 if sentinel value is encountered
        return (value == CLEARED_MON_STATE_SENTINEL) ? int32(0) : value;
    }

    function getTurnIdForBattleState(bytes32 battleKey) external view returns (uint256) {
        return battleData[battleKey].turnId;
    }

    function getActiveMonIndexForBattleState(bytes32 battleKey) external view returns (uint256[] memory) {
        uint16 packed = battleData[battleKey].activeMonIndex;
        uint256[] memory result = new uint256[](2);
        result[0] = _unpackActiveMonIndex(packed, 0);
        result[1] = _unpackActiveMonIndex(packed, 1);
        return result;
    }

    function getGlobalKV(bytes32 battleKey, uint64 key) external view returns (uint192) {
        return _getGlobalKVValue(_resolveStorageKey(battleKey), key);
    }

    /// @dev Internal timestamp-gated globalKV reader. Returns 0 for stale values left over from a
    ///      prior battle that reused this storageKey. Shared by getGlobalKV and the inlined
    ///      stat-boost snapshot path.
    function _getGlobalKVValue(bytes32 storageKey, uint64 key) private view returns (uint192) {
        bytes32 packed = globalKV[storageKey][key];
        uint64 storedTimestamp = uint64(uint256(packed) >> 192);
        uint64 currentTimestamp = uint64(battleConfig[storageKey].startTimestamp);
        if (storedTimestamp != currentTimestamp) {
            return 0;
        }
        return uint192(uint256(packed));
    }

    function getEffects(bytes32 battleKey, uint256 targetIndex, uint256 monIndex)
        external
        view
        returns (EffectInstance[] memory, uint256[] memory)
    {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        return _getEffectsForTarget(storageKey, targetIndex, monIndex);
    }

    /// @notice Targeted single-effect lookup. Scans a mon's (or the global) effect list for
    ///         `effectAddr` and returns its slot index + data, WITHOUT materializing the full
    ///         `EffectInstance[]` array. For abilities / move-effects that only need one known
    ///         effect (idempotency guards, reading own state) this avoids the array build + ABI
    ///         round-trip that dominates `getEffects()`. `effectIndex` matches the index that
    ///         `editEffect` expects (absolute slot for players, list index for global).
    function getEffectData(bytes32 battleKey, uint256 targetIndex, uint256 monIndex, address effectAddr)
        external
        view
        returns (bool exists, uint256 effectIndex, bytes32 data)
    {
        BattleConfig storage config = battleConfig[_resolveStorageKey(battleKey)];
        if (targetIndex == 2) {
            uint256 len = config.globalEffectsLength;
            for (uint256 i; i < len;) {
                EffectInstance storage e = config.globalEffects[i];
                if (address(e.effect) == effectAddr) return (true, i, e.data);
                unchecked { ++i; }
            }
            return (false, 0, bytes32(0));
        }
        uint96 packedCounts = targetIndex == 0 ? config.packedP0EffectsCount : config.packedP1EffectsCount;
        uint256 monEffectCount = _getMonEffectCount(packedCounts, monIndex);
        uint256 baseSlot = _getEffectSlotIndex(monIndex, 0);
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;
        for (uint256 i; i < monEffectCount;) {
            uint256 slotIndex = baseSlot + i;
            EffectInstance storage e = effects[slotIndex];
            if (address(e.effect) == effectAddr) return (true, slotIndex, e.data);
            unchecked { ++i; }
        }
        return (false, 0, bytes32(0));
    }

    function getWinner(bytes32 battleKey) external view returns (address) {
        BattleData storage data = battleData[battleKey];
        uint8 winnerIndex = data.winnerIndex;
        if (winnerIndex == 2) {
            return address(0);
        }
        return (winnerIndex == 0) ? data.p0 : data.p1;
    }

    function getKOBitmap(bytes32 battleKey, uint256 playerIndex) external view returns (uint256) {
        return _getKOBitmap(battleConfig[_resolveStorageKey(battleKey)], playerIndex);
    }

    function getBattleContext(bytes32 battleKey) external view returns (BattleContext memory ctx) {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleData storage data = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        ctx.startTimestamp = config.startTimestamp;
        ctx.p0 = data.p0;
        ctx.p1 = data.p1;
        ctx.winnerIndex = data.winnerIndex;
        ctx.turnId = data.turnId;
        ctx.playerSwitchForTurnFlag = data.playerSwitchForTurnFlag;
        ctx.p0ActiveMonIndex = uint8(data.activeMonIndex & 0xFF);
        ctx.p1ActiveMonIndex = uint8(data.activeMonIndex >> 8);
        ctx.validator = address(config.validator);
        ctx.moveManager = config.moveManager;
    }

    function _getDamageCalcContextInternal(
        BattleConfig storage config,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderPlayerIndex,
        uint256 defenderMonIndex
    ) internal view returns (DamageCalcContext memory ctx) {
        ctx.attackerMonIndex = uint8(attackerMonIndex);
        ctx.defenderMonIndex = uint8(defenderMonIndex);

        // Get attacker stats
        Mon storage attackerMon = _getTeamMon(config, attackerPlayerIndex, attackerMonIndex);
        MonState storage attackerState = _getMonState(config, attackerPlayerIndex, attackerMonIndex);
        ctx.attackerAttack = attackerMon.stats.attack;
        ctx.attackerAttackDelta =
            attackerState.attackDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : attackerState.attackDelta;
        ctx.attackerSpAtk = attackerMon.stats.specialAttack;
        ctx.attackerSpAtkDelta = attackerState.specialAttackDelta == CLEARED_MON_STATE_SENTINEL
            ? int32(0)
            : attackerState.specialAttackDelta;

        // Get defender stats and types
        Mon storage defenderMon = _getTeamMon(config, defenderPlayerIndex, defenderMonIndex);
        MonState storage defenderState = _getMonState(config, defenderPlayerIndex, defenderMonIndex);
        ctx.defenderDef = defenderMon.stats.defense;
        ctx.defenderDefDelta =
            defenderState.defenceDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : defenderState.defenceDelta;
        ctx.defenderSpDef = defenderMon.stats.specialDefense;
        ctx.defenderSpDefDelta = defenderState.specialDefenceDelta == CLEARED_MON_STATE_SENTINEL
            ? int32(0)
            : defenderState.specialDefenceDelta;
        ctx.defenderType1 = defenderMon.stats.type1;
        ctx.defenderType2 = defenderMon.stats.type2;
    }

    function getDamageCalcContext(bytes32 battleKey, uint256 attackerPlayerIndex, uint256 defenderPlayerIndex)
        external
        view
        returns (DamageCalcContext memory ctx)
    {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleData storage data = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];
        uint256 attackerMonIndex = _unpackActiveMonIndex(data.activeMonIndex, attackerPlayerIndex);
        uint256 defenderMonIndex = _unpackActiveMonIndex(data.activeMonIndex, defenderPlayerIndex);
        return _getDamageCalcContextInternal(
            config, attackerPlayerIndex, attackerMonIndex, defenderPlayerIndex, defenderMonIndex
        );
    }

    /// @notice Returns the MonState array for one side of a battle. Used by registry-side
    ///         quest opcodes that aggregate over MonState fields (e.g. MIN/MAX_HP_DELTA) so
    ///         they pay 1 extcall + N internal SLOADs instead of N separate getMonStateForBattle
    ///         extcalls. Length = team size for that side.
    function getMonStatesForSide(bytes32 battleKey, uint256 playerIndex)
        external
        view
        returns (MonState[] memory states)
    {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        uint8 teamSizes = config.teamSizes;
        uint256 size = playerIndex == 0 ? (teamSizes & 0xF) : (teamSizes >> 4);
        states = new MonState[](size);
        if (playerIndex == 0) {
            for (uint256 i; i < size;) {
                states[i] = config.p0States[i];
                unchecked { ++i; }
            }
        } else {
            for (uint256 i; i < size;) {
                states[i] = config.p1States[i];
                unchecked { ++i; }
            }
        }
    }

    /// @notice Batched getter for the registry's onBattleEnd hook. Bundles every
    ///         BattleData + BattleConfig field needed at battle end into a single staticcall —
    ///         replaces the older split (getPlayersForBattle + getWinner + getKOBitmap×2).
    function getBattleEndContext(bytes32 battleKey) external view returns (BattleEndContext memory ctx) {
        bytes32 storageKey = _resolveStorageKey(battleKey);
        BattleData storage data = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        ctx.p0 = data.p0;
        ctx.p1 = data.p1;
        // winner: address(0) when uninitialized OR when it's a draw the engine never
        // explicitly sets to a non-2 winnerIndex; both cases collapse to address(0).
        uint8 wi = data.winnerIndex;
        ctx.winner = wi == 0 ? data.p0 : (wi == 1 ? data.p1 : address(0));

        ctx.p0TeamIndex = data.p0TeamIndex;
        ctx.p1TeamIndex = data.p1TeamIndex;

        uint16 koBitmaps = config.koBitmaps;
        ctx.p0KOBitmap = uint8(koBitmaps & 0xFF);
        ctx.p1KOBitmap = uint8(koBitmaps >> 8);

        ctx.p0ActiveMonIndex = uint8(_unpackActiveMonIndex(data.activeMonIndex, 0));
        ctx.p1ActiveMonIndex = uint8(_unpackActiveMonIndex(data.activeMonIndex, 1));

        ctx.turnId = data.turnId;
    }
}
