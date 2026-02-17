// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Constants.sol";

import "./Enums.sol";
import "./Structs.sol";
import "./moves/IMoveSet.sol";

import {IEngine} from "./IEngine.sol";
import {ICommitManager} from "./commit-manager/ICommitManager.sol";
import {MappingAllocator} from "./lib/MappingAllocator.sol";
import {ValidatorLogic, TimeoutCheckParams} from "./lib/ValidatorLogic.sol";
import {IMatchmaker} from "./matchmaker/IMatchmaker.sol";

contract Engine is IEngine, MappingAllocator {
    // Default validator config (immutable, for inline validation when validator is address(0))
    uint256 public immutable DEFAULT_MONS_PER_TEAM;
    uint256 public immutable DEFAULT_MOVES_PER_MON;
    uint256 public immutable DEFAULT_TIMEOUT_DURATION;
    uint256 public constant PREV_TURN_MULTIPLIER = 2;

    bytes32 public transient battleKeyForWrite; // intended to be used during call stack by other contracts
    bytes32 private transient storageKeyForWrite; // cached storage key to avoid repeated lookups
    // Bitmap tracking which effect lists were modified (for caching effect counts)
    // Bit 0: global effects, Bits 1-8: P0 mons 0-7, Bits 9-16: P1 mons 0-7
    uint256 private transient effectsDirtyBitmap;
    mapping(bytes32 => uint256) public pairHashNonces; // imposes a global ordering across all matches
    mapping(address player => mapping(address maker => bool)) public isMatchmakerFor; // tracks approvals for matchmakers

    mapping(bytes32 => BattleData) private battleData; // These contain immutable data and battle state
    mapping(bytes32 => BattleConfig) private battleConfig; // These exist only throughout the lifecycle of a battle, we reuse these storage slots for subsequent battles
    mapping(bytes32 storageKey => mapping(bytes32 => bytes32)) private globalKV; // Value layout: [64 bits timestamp | 192 bits value]
    uint256 public transient tempRNG; // Used to provide RNG during execute() tx
    uint256 private transient currentStep; // Used to bubble up step data for events
    address private transient upstreamCaller; // Used to bubble up caller data for events

    // Errors
    error NoWriteAllowed();
    error WrongCaller();
    error MatchmakerNotAuthorized();
    error MatchmakerError();
    error MovesNotSet();
    error InvalidBattleConfig();
    error GameAlreadyOver();
    error GameStartsAndEndsSameBlock();
    error BattleNotStarted();
    error NotTwoPlayerTurn();

    // Events
    event BattleStart(bytes32 indexed battleKey, address p0, address p1);
    event EngineExecute(
        bytes32 indexed battleKey, uint256 turnId, uint256 playerSwitchForTurnFlag, uint256 priorityPlayerIndex
    );
    event MonSwitch(bytes32 indexed battleKey, uint256 playerIndex, uint256 newMonIndex, address source);
    event MonStateUpdate(
        bytes32 indexed battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        uint256 stateVarIndex,
        int32 valueDelta,
        address source,
        uint256 step
    );
    event MonMove(
        bytes32 indexed battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        uint256 moveIndex,
        uint240 extraData,
        int32 staminaCost
    );
    event P0MoveSet(bytes32 indexed battleKey, uint256 packedMoveIndexExtraData, bytes32 salt);
    event P1MoveSet(bytes32 indexed battleKey, uint256 packedMoveIndexExtraData, bytes32 salt);
    event DamageDeal(
        bytes32 indexed battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        int32 damageDealt,
        address source,
        uint256 step
    );
    event EffectAdd(
        bytes32 indexed battleKey,
        uint256 effectIndex,
        uint256 monIndex,
        address effectAddress,
        bytes32 extraData,
        address source,
        uint256 step
    );
    event EffectRun(
        bytes32 indexed battleKey,
        uint256 effectIndex,
        uint256 monIndex,
        address effectAddress,
        bytes32 extraData,
        address source,
        uint256 step
    );
    event EffectEdit(
        bytes32 indexed battleKey,
        uint256 effectIndex,
        uint256 monIndex,
        address effectAddress,
        bytes32 extraData,
        address source,
        uint256 step
    );
    event EffectRemove(
        bytes32 indexed battleKey,
        uint256 effectIndex,
        uint256 monIndex,
        address effectAddress,
        address source,
        uint256 step
    );
    event BattleComplete(bytes32 indexed battleKey, address winner);
    event EngineEvent(bytes32 indexed battleKey, bytes32 eventType, bytes eventData, address source, uint256 step);

    /// @notice Constructor to set default validator config for inline validation
    /// @dev When a battle's validator is address(0), Engine uses inline validation logic with these params
    /// @param _DEFAULT_MONS_PER_TEAM Default mons per team for inline validation
    /// @param _DEFAULT_MOVES_PER_MON Default moves per mon for inline validation
    /// @param _DEFAULT_TIMEOUT_DURATION Default timeout duration for inline validation
    constructor(uint256 _DEFAULT_MONS_PER_TEAM, uint256 _DEFAULT_MOVES_PER_MON, uint256 _DEFAULT_TIMEOUT_DURATION) {
        DEFAULT_MONS_PER_TEAM = _DEFAULT_MONS_PER_TEAM;
        DEFAULT_MOVES_PER_MON = _DEFAULT_MOVES_PER_MON;
        DEFAULT_TIMEOUT_DURATION = _DEFAULT_TIMEOUT_DURATION;
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
        if (!matchmaker.validateMatch(battleKey, battle.p0) || !matchmaker.validateMatch(battleKey, battle.p1)) {
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
        // Reset effects lengths and KO bitmaps to 0 for the new battle
        config.packedP0EffectsCount = 0;
        config.packedP1EffectsCount = 0;
        config.koBitmaps = 0;

        // Store the battle data with initial state
        // activeMonIndex uses 4-bit-per-slot packing for doubles:
        // Bits 0-3: p0 slot 0, Bits 4-7: p0 slot 1, Bits 8-11: p1 slot 0, Bits 12-15: p1 slot 1
        // For doubles: p0s0=0, p0s1=1, p1s0=0, p1s1=1
        // For singles: all 0 (backward compatible with 8-bit packing)
        uint16 initialActiveMonIndex = battle.gameMode == GameMode.Doubles
            ? uint16(0) | (uint16(1) << 4) | (uint16(0) << 8) | (uint16(1) << 12)
            : uint16(0);

        battleData[battleKey] = BattleData({
            p0: battle.p0,
            p1: battle.p1,
            winnerIndex: 2, // Initialize to 2 (uninitialized/no winner)
            prevPlayerSwitchForTurnFlag: 0,
            playerSwitchForTurnFlag: 2, // Set flag to be 2 which means both players act
            activeMonIndex: initialActiveMonIndex,
            turnId: 0,
            slotSwitchFlagsAndGameMode: battle.gameMode == GameMode.Doubles ? GAME_MODE_BIT : 0
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
        if (address(battle.ruleset) != address(0)) {
            (IEffect[] memory effects, bytes32[] memory data) = battle.ruleset.getInitialGlobalEffects();
            uint256 numEffects = effects.length;
            if (numEffects > 0) {
                for (uint256 i = 0; i < numEffects;) {
                    config.globalEffects[i].effect = effects[i];
                    config.globalEffects[i].stepsBitmap = effects[i].getStepsBitmap();
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
        config.startTimestamp = uint48(block.timestamp);

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

        _runEngineHooks(config, battleKey, EngineHookStep.OnBattleStart);

        emit BattleStart(battleKey, battle.p0, battle.p1);
    }

    // THE IMPORTANT FUNCTION
    function execute(bytes32 battleKey) external {
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

        _executeInternal(battleKey, storageKey);
    }

    /// @notice Combined setMove + setMove + execute for gas optimization
    /// @dev Only callable by moveManager. Sets both moves and executes in one call.
    function executeWithMoves(
        bytes32 battleKey,
        uint8 p0MoveIndex,
        bytes32 p0Salt,
        uint240 p0ExtraData,
        uint8 p1MoveIndex,
        bytes32 p1Salt,
        uint240 p1ExtraData
    ) external {
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;

        BattleConfig storage config = battleConfig[storageKey];

        if (msg.sender != config.moveManager) {
            revert WrongCaller();
        }

        _setMoveInternal(config, battleKey, 0, p0MoveIndex, p0Salt, p0ExtraData);
        _setMoveInternal(config, battleKey, 1, p1MoveIndex, p1Salt, p1ExtraData);

        // Execute (skip MovesNotSet check since we just set them)
        _executeInternal(battleKey, storageKey);
    }

    /// @notice Internal execution logic shared by execute() and executeWithMoves()
    function _executeInternal(bytes32 battleKey, bytes32 storageKey) internal {
        // Load storage vars
        BattleData storage battle = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        // Check for game over
        if (battle.winnerIndex != 2) {
            revert GameAlreadyOver();
        }

        // Set up turn / player vars
        uint256 turnId = battle.turnId;
        uint256 playerSwitchForTurnFlag = 2;
        uint256 priorityPlayerIndex;

        // Store the prev player switch for turn flag
        battle.prevPlayerSwitchForTurnFlag = battle.playerSwitchForTurnFlag;

        // Set the battle key for the stack frame
        // (gets cleared at the end of the transaction)
        battleKeyForWrite = battleKey;

        _runEngineHooks(config, battleKey, EngineHookStep.OnRoundStart);

        // Branch for doubles mode
        if (_isDoublesMode(battle)) {
            _executeDoubles(battleKey, config, battle, turnId, config.engineHooksLength);
            return;
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
            uint256 rng = config.rngOracle.getRNG(config.p0Salt, config.p1Salt);
            tempRNG = rng;

            // Calculate the priority and non-priority player indices
            priorityPlayerIndex = computePriorityPlayerIndex(battleKey, rng);
            uint256 otherPlayerIndex = 1 - priorityPlayerIndex;

            // Run beginning of round effects
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

            // Run priority player's move (NOTE: moves won't run if either mon is KOed)
            playerSwitchForTurnFlag =
                _handleMove(battleKey, config, battle, priorityPlayerIndex, playerSwitchForTurnFlag);

            // If priority mons is not KO'ed, then run the priority player's mon's afterMove hook(s)
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

            // Always run the global effect's afterMove hook(s)
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

            // Run the non priority player's move
            playerSwitchForTurnFlag = _handleMove(battleKey, config, battle, otherPlayerIndex, playerSwitchForTurnFlag);

            // For turn 0 only: wait for both mons to be sent in, then handle the ability activateOnSwitch
            // Happens immediately after both mons are sent in, before any other effects
            if (turnId == 0) {
                uint256 priorityMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, priorityPlayerIndex);
                Mon memory priorityMon = _getTeamMon(config, priorityPlayerIndex, priorityMonIndex);
                if (address(priorityMon.ability) != address(0)) {
                    priorityMon.ability.activateOnSwitch(battleKey, priorityPlayerIndex, priorityMonIndex);
                }
                uint256 otherMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, otherPlayerIndex);
                Mon memory otherMon = _getTeamMon(config, otherPlayerIndex, otherMonIndex);
                if (address(otherMon.ability) != address(0)) {
                    otherMon.ability.activateOnSwitch(battleKey, otherPlayerIndex, otherMonIndex);
                }
            }

            // If non priority mon is not KOed, then run the non priority player's mon's afterMove hook(s)
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

            // Always run the global effect's afterMove hook(s)
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

            // Always run global effects at the end of the round
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

        // Run the round end hooks
        _runEngineHooks(config, battleKey, EngineHookStep.OnRoundEnd);

        // If a winner has been set, handle the game over
        if (battle.winnerIndex != 2) {
            address winner = (battle.winnerIndex == 0) ? battle.p0 : battle.p1;
            _handleGameOver(battleKey, winner);

            // Still emit execute event
            emit EngineExecute(battleKey, turnId, playerSwitchForTurnFlag, priorityPlayerIndex);
            return;
        }

        // End of turn cleanup:
        // - Progress turn index
        // - Set the player switch for turn flag on battle data
        // - Clear move flags for next turn (clear isRealTurn bit by setting packedMoveIndex to 0)
        // - Update lastExecuteTimestamp for timeout tracking
        battle.turnId += 1;
        battle.playerSwitchForTurnFlag = uint8(playerSwitchForTurnFlag);
        config.p0Move.packedMoveIndex = 0;
        config.p1Move.packedMoveIndex = 0;
        config.lastExecuteTimestamp = uint48(block.timestamp);

        // Emits switch for turn flag for the next turn, but the priority index for this current turn
        emit EngineExecute(battleKey, turnId, playerSwitchForTurnFlag, priorityPlayerIndex);
    }

    function end(bytes32 battleKey) external {
        BattleData storage data = battleData[battleKey];
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;
        BattleConfig storage config = battleConfig[storageKey];
        if (data.winnerIndex != 2) {
            revert GameAlreadyOver();
        }
        for (uint256 i; i < 2;) {
            address potentialLoser;
            if (address(config.validator) != address(0)) {
                potentialLoser = config.validator.validateTimeout(battleKey, i);
            } 
            // Use inline timeout validation when validator is address(0)
            else {
                potentialLoser = _validateTimeoutInline(battleKey, data, config, i);
            }
            if (potentialLoser != address(0)) {
                address winner = potentialLoser == data.p0 ? data.p1 : data.p0;
                data.winnerIndex = (winner == data.p0) ? 0 : 1;
                _handleGameOver(battleKey, winner);
                return;
            }
            unchecked {
                ++i;
            }
        }
        // Allow forcible end of battle after max duration
        if (block.timestamp - config.startTimestamp > MAX_BATTLE_DURATION) {
            _handleGameOver(battleKey, data.p0);
            return;
        }
    }

    /// @dev Inline timeout validation logic using shared ValidatorLogic
    function _validateTimeoutInline(
        bytes32 battleKey,
        BattleData storage data,
        BattleConfig storage config,
        uint256 playerIndexToCheck
    ) private view returns (address loser) {
        uint256 otherPlayerIndex = 1 - playerIndexToCheck;
        ICommitManager commitManager = ICommitManager(config.moveManager);
        address[2] memory players = [data.p0, data.p1];

        // Fetch commit data for both players
        (bytes32 playerMoveHash, uint256 playerCommitTurnId) =
            commitManager.getCommitment(battleKey, players[playerIndexToCheck]);
        (bytes32 otherPlayerMoveHash, uint256 otherPlayerCommitTurnId) =
            commitManager.getCommitment(battleKey, players[otherPlayerIndex]);

        // Build params struct
        TimeoutCheckParams memory params = TimeoutCheckParams({
            turnId: data.turnId,
            playerSwitchForTurnFlag: data.playerSwitchForTurnFlag,
            playerIndexToCheck: playerIndexToCheck,
            lastTurnTimestamp: data.turnId == 0 ? config.startTimestamp : config.lastExecuteTimestamp,
            timeoutDuration: DEFAULT_TIMEOUT_DURATION,
            prevTurnMultiplier: PREV_TURN_MULTIPLIER,
            playerMoveHash: playerMoveHash,
            playerCommitTurnId: playerCommitTurnId,
            otherPlayerRevealCount: commitManager.getMoveCountForBattleState(battleKey, players[otherPlayerIndex]),
            otherPlayerTimestamp: commitManager.getLastMoveTimestampForPlayer(battleKey, players[otherPlayerIndex]),
            otherPlayerMoveHash: otherPlayerMoveHash,
            otherPlayerCommitTurnId: otherPlayerCommitTurnId
        });

        if (ValidatorLogic.validateTimeoutLogic(params)) {
            return players[playerIndexToCheck];
        }
        return address(0);
    }

    function _handleGameOver(bytes32 battleKey, address winner) internal {
        bytes32 storageKey = storageKeyForWrite;
        BattleConfig storage config = battleConfig[storageKey];

        if (block.timestamp == config.startTimestamp) {
            revert GameStartsAndEndsSameBlock();
        }

        _runEngineHooks(config, battleKey, EngineHookStep.OnBattleEnd);

        // Free the key used for battle configs so other battles can use it
        _freeStorageKey(battleKey, storageKey);
        emit BattleComplete(battleKey, winner);
    }

    /**
     * - Write functions for MonState, Effects, and GlobalKV
     */
    function updateMonState(uint256 playerIndex, uint256 monIndex, MonStateIndexName stateVarIndex, int32 valueToAdd)
        external
    {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }
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
            } else if (!newKOState && wasKOed) {
                _clearMonKO(config, playerIndex, monIndex);
            }
        } else if (stateVarIndex == MonStateIndexName.ShouldSkipTurn) {
            monState.shouldSkipTurn = (valueToAdd % 2) == 1;
        }

        // Grab state update source if it's set and use it, otherwise default to caller
        emit MonStateUpdate(
            battleKey,
            playerIndex,
            monIndex,
            uint256(stateVarIndex),
            valueToAdd,
            _getUpstreamCallerAndResetValue(),
            currentStep
        );

        // Trigger OnUpdateMonState lifecycle hook
        // Pass explicit monIndex so effects run on the correct mon (not just slot 0)
        _runEffects(
            battleKey,
            tempRNG,
            playerIndex,
            playerIndex,
            EffectStep.OnUpdateMonState,
            abi.encode(playerIndex, monIndex, stateVarIndex, valueToAdd),
            monIndex
        );
    }

    function addEffect(uint256 targetIndex, uint256 monIndex, IEffect effect, bytes32 extraData) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }
        if (effect.shouldApply(battleKey, extraData, targetIndex, monIndex)) {
            bytes32 extraDataToUse = extraData;
            bool removeAfterRun = false;

            // Fetch steps bitmap once from effect (stored as immutable in effect contract)
            uint16 stepsBitmap = effect.getStepsBitmap();

            // Emit event first, then handle side effects
            emit EffectAdd(
                battleKey,
                targetIndex,
                monIndex,
                address(effect),
                extraData,
                _getUpstreamCallerAndResetValue(),
                uint256(EffectStep.OnApply)
            );

            // Check if we have to run an onApply state update (use bitmap instead of external call)
            if ((stepsBitmap & (1 << uint8(EffectStep.OnApply))) != 0) {
                // Get active mon indices for both players
                BattleData storage battle = battleData[battleKey];
                uint256 p0ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
                uint256 p1ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);
                // If so, we run the effect first, and get updated extraData if necessary
                (extraDataToUse, removeAfterRun) = effect.onApply(battleKey, tempRNG, extraData, targetIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);
            }
            if (!removeAfterRun) {
                // Add to the appropriate effects mapping based on targetIndex
                BattleConfig storage config = battleConfig[storageKeyForWrite];

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

    function editEffect(uint256 targetIndex, uint256 monIndex, uint256 effectIndex, bytes32 newExtraData) external {
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
        emit EffectEdit(
            battleKey,
            targetIndex,
            monIndex,
            address(effectInstance.effect),
            newExtraData,
            _getUpstreamCallerAndResetValue(),
            currentStep
        );
    }

    function removeEffect(uint256 targetIndex, uint256 monIndex, uint256 indexToRemove) public {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }

        BattleConfig storage config = battleConfig[storageKeyForWrite];

        if (targetIndex == 2) {
            // Global effects use simple sequential indexing
            _removeGlobalEffect(config, battleKey, monIndex, indexToRemove);
        } else {
            // Player effects use per-mon indexing
            _removePlayerEffect(config, battleKey, targetIndex, monIndex, indexToRemove);
        }
    }

    function _removeGlobalEffect(
        BattleConfig storage config,
        bytes32 battleKey,
        uint256 monIndex,
        uint256 indexToRemove
    ) private {
        EffectInstance storage effectToRemove = config.globalEffects[indexToRemove];
        IEffect effect = effectToRemove.effect;
        uint16 stepsBitmap = effectToRemove.stepsBitmap;
        bytes32 data = effectToRemove.data;

        // Skip if already tombstoned
        if (address(effect) == TOMBSTONE_ADDRESS) {
            return;
        }

        // Use stored bitmap instead of external call to shouldRunAtStep()
        if ((stepsBitmap & (1 << uint8(EffectStep.OnRemove))) != 0) {
            // Get active mon indices for both players
            BattleData storage battle = battleData[battleKey];
            uint256 p0ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
            uint256 p1ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);
            effect.onRemove(battleKey, data, 2, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);
        }

        // Tombstone the effect (indices are stable, no need to re-find)
        effectToRemove.effect = IEffect(TOMBSTONE_ADDRESS);

        emit EffectRemove(battleKey, 2, monIndex, address(effect), _getUpstreamCallerAndResetValue(), currentStep);
    }

    function _removePlayerEffect(
        BattleConfig storage config,
        bytes32 battleKey,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 indexToRemove
    ) private {
        mapping(uint256 => EffectInstance) storage effects = targetIndex == 0 ? config.p0Effects : config.p1Effects;

        EffectInstance storage effectToRemove = effects[indexToRemove];
        IEffect effect = effectToRemove.effect;
        uint16 stepsBitmap = effectToRemove.stepsBitmap;
        bytes32 data = effectToRemove.data;

        // Skip if already tombstoned
        if (address(effect) == TOMBSTONE_ADDRESS) {
            return;
        }

        // Use stored bitmap instead of external call to shouldRunAtStep()
        if ((stepsBitmap & (1 << uint8(EffectStep.OnRemove))) != 0) {
            // Get active mon indices for both players
            BattleData storage battle = battleData[battleKey];
            uint256 p0ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
            uint256 p1ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);
            effect.onRemove(battleKey, data, targetIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);
        }

        // Tombstone the effect (indices are stable, no need to re-find)
        effectToRemove.effect = IEffect(TOMBSTONE_ADDRESS);

        emit EffectRemove(
            battleKey, targetIndex, monIndex, address(effect), _getUpstreamCallerAndResetValue(), currentStep
        );
    }

    function setGlobalKV(bytes32 key, uint192 value) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }
        bytes32 storageKey = storageKeyForWrite;
        uint64 timestamp = battleConfig[storageKey].startTimestamp;
        // Pack timestamp (upper 64 bits) with value (lower 192 bits)
        bytes32 packed = bytes32((uint256(timestamp) << 192) | uint256(value));
        globalKV[storageKey][key] = packed;
    }

    function dealDamage(uint256 playerIndex, uint256 monIndex, int32 damage) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        MonState storage monState = _getMonState(config, playerIndex, monIndex);

        // If sentinel, replace with -damage; otherwise subtract damage
        monState.hpDelta = (monState.hpDelta == CLEARED_MON_STATE_SENTINEL) ? -damage : monState.hpDelta - damage;

        // Set KO flag if the total hpDelta is greater than the original mon HP
        uint32 baseHp = _getTeamMon(config, playerIndex, monIndex).stats.hp;
        if (monState.hpDelta + int32(baseHp) <= 0 && !monState.isKnockedOut) {
            monState.isKnockedOut = true;
            // Set KO bit for this mon
            _setMonKO(config, playerIndex, monIndex);
        }
        emit DamageDeal(battleKey, playerIndex, monIndex, damage, _getUpstreamCallerAndResetValue(), currentStep);
        // Pass explicit monIndex so effects run on the correct mon (not just slot 0)
        _runEffects(battleKey, tempRNG, playerIndex, playerIndex, EffectStep.AfterDamage, abi.encode(damage), monIndex);
    }

    function switchActiveMon(uint256 playerIndex, uint256 monToSwitchIndex) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }

        BattleConfig storage config = battleConfig[storageKeyForWrite];
        BattleData storage battle = battleData[battleKey];

        // Use the validator to check if the switch is valid
        bool isValid;
        if (address(config.validator) == address(0)) {
            // Use inline validation (no external call)
            uint256 activeMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, playerIndex);
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
            _handleSwitch(battleKey, playerIndex, monToSwitchIndex, msg.sender);

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
        bytes32 battleKey,
        uint256 playerIndex,
        uint8 moveIndex,
        bytes32 salt,
        uint240 extraData
    ) internal {
        // Pack moveIndex with isRealTurn bit and apply +1 offset for regular moves
        // Regular moves (< SWITCH_MOVE_INDEX) are stored as moveIndex + 1 to avoid zero ambiguity
        uint8 storedMoveIndex = moveIndex < SWITCH_MOVE_INDEX ? moveIndex + MOVE_INDEX_OFFSET : moveIndex;
        MoveDecision memory newMove = MoveDecision({
            packedMoveIndex: storedMoveIndex | IS_REAL_TURN_BIT,
            extraData: extraData
        });

        if (playerIndex == 0) {
            config.p0Move = newMove;
            config.p0Salt = salt;
            emit P0MoveSet(battleKey, uint256(moveIndex) | (uint256(extraData) << 8), salt);
        } else {
            config.p1Move = newMove;
            config.p1Salt = salt;
            emit P1MoveSet(battleKey, uint256(moveIndex) | (uint256(extraData) << 8), salt);
        }
    }

    /**
     * @notice Switch active mon for a specific slot in doubles battles
     * @param playerIndex 0 or 1
     * @param slotIndex 0 or 1
     * @param monToSwitchIndex The mon index to switch to
     */
    function switchActiveMonForSlot(uint256 playerIndex, uint256 slotIndex, uint256 monToSwitchIndex) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }

        BattleConfig storage config = battleConfig[storageKeyForWrite];
        BattleData storage battle = battleData[battleKey];

        // Validate switch (use slot-aware validation for both external and inline paths)
        bool isValid;
        if (address(config.validator) != address(0)) {
            isValid = config.validator.validateSwitchForSlot(battleKey, playerIndex, slotIndex, monToSwitchIndex);
        } else {
            // Use inline validation via library (no external call)
            uint256 activeMonIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, slotIndex);
            uint256 otherSlotActiveMonIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, 1 - slotIndex);
            bool isTargetKnockedOut = _getMonState(config, playerIndex, monToSwitchIndex).isKnockedOut;
            isValid = ValidatorLogic.validateSwitchForSlot(
                battle.turnId, monToSwitchIndex, activeMonIndex, otherSlotActiveMonIndex, type(uint256).max, isTargetKnockedOut, DEFAULT_MONS_PER_TEAM
            );
        }

        if (isValid) {
            // Uses _handleSwitchForSlot which handles slot packing internally
            _handleSwitchForSlot(battleKey, playerIndex, slotIndex, monToSwitchIndex, msg.sender);

            // Use doubles-specific game over check
            bool isGameOver = _checkForGameOverOrKO_Doubles(config, battle);
            if (isGameOver) return;
            // playerSwitchForTurnFlag was already set by _checkForGameOverOrKO_Doubles
        }
    }

    function setMove(bytes32 battleKey, uint256 playerIndex, uint8 moveIndex, bytes32 salt, uint240 extraData)
        external
    {
        // Use cached key if called during execute(), otherwise lookup
        bool isForCurrentBattle = battleKeyForWrite == battleKey;
        bytes32 storageKey = isForCurrentBattle ? storageKeyForWrite : _getStorageKey(battleKey);

        // Cache storage pointer to avoid repeated mapping lookups
        BattleConfig storage config = battleConfig[storageKey];

        if (msg.sender != address(config.moveManager) && !isForCurrentBattle) {
            revert NoWriteAllowed();
        }

        _setMoveInternal(config, battleKey, playerIndex, moveIndex, salt, extraData);
    }

    /**
     * @notice Set a move for a specific slot in doubles battles
     * @param battleKey The battle identifier
     * @param playerIndex 0 or 1
     * @param slotIndex 0 or 1
     * @param moveIndex The move index
     * @param salt Salt for RNG (applied per-player, not per-slot — slot 1 shares the player's salt set via slot 0)
     * @param extraData Extra data for the move (e.g., target)
     */
    function setMoveForSlot(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 slotIndex,
        uint8 moveIndex,
        bytes32 salt,
        uint240 extraData
    ) external {
        BattleConfig storage config = _prepareMoveSet(battleKey);
        MoveDecision memory newMove = _packMoveDecision(moveIndex, extraData);

        if (playerIndex == 0) {
            if (slotIndex == 0) {
                config.p0Move = newMove;
                config.p0Salt = salt;
            } else {
                config.p0Move2 = newMove;
                // Salt is per-player, not per-slot; slot 0 sets p0Salt for RNG derivation
            }
        } else {
            if (slotIndex == 0) {
                config.p1Move = newMove;
                config.p1Salt = salt;
            } else {
                config.p1Move2 = newMove;
                // Salt is per-player, not per-slot; slot 0 sets p1Salt for RNG derivation
            }
        }
    }

    /// @dev Validates caller permissions and returns the BattleConfig storage pointer for move-setting
    function _prepareMoveSet(bytes32 battleKey) private view returns (BattleConfig storage config) {
        bool isForCurrentBattle = battleKeyForWrite == battleKey;
        bytes32 storageKey = isForCurrentBattle ? storageKeyForWrite : _getStorageKey(battleKey);
        config = battleConfig[storageKey];
        bool isMoveManager = msg.sender == address(config.moveManager);
        if (!isMoveManager && !isForCurrentBattle) {
            revert NoWriteAllowed();
        }
    }

    /// @dev Packs a moveIndex + extraData into a MoveDecision with IS_REAL_TURN_BIT set
    function _packMoveDecision(uint8 moveIndex, uint240 extraData) private pure returns (MoveDecision memory) {
        uint8 storedMoveIndex = moveIndex < SWITCH_MOVE_INDEX ? moveIndex + MOVE_INDEX_OFFSET : moveIndex;
        return MoveDecision({packedMoveIndex: storedMoveIndex | IS_REAL_TURN_BIT, extraData: extraData});
    }

    function emitEngineEvent(bytes32 eventType, bytes memory eventData) external {
        bytes32 battleKey = battleKeyForWrite;
        emit EngineEvent(battleKey, eventType, eventData, _getUpstreamCallerAndResetValue(), currentStep);
    }

    function setUpstreamCaller(address caller) external {
        upstreamCaller = caller;
    }

    function computeBattleKey(address p0, address p1) public view returns (bytes32 battleKey, bytes32 pairHash) {
        pairHash = keccak256(abi.encode(p0, p1));
        if (uint256(uint160(p0)) > uint256(uint160(p1))) {
            pairHash = keccak256(abi.encode(p1, p0));
        }
        uint256 pairHashNonce = pairHashNonces[pairHash];
        battleKey = keccak256(abi.encode(pairHash, pairHashNonce));
    }

    function _checkForGameOverOrKO(BattleConfig storage config, BattleData storage battle, uint256 priorityPlayerIndex)
        internal
        returns (uint256 playerSwitchForTurnFlag, bool isGameOver)
    {
        // Use shared game over check (loads KO bitmaps once)
        (uint256 winnerIndex, uint256 p0KOBitmap, uint256 p1KOBitmap) = _checkForGameOver(config, battle);

        if (winnerIndex != 2) {
            battle.winnerIndex = uint8(winnerIndex);
            return (playerSwitchForTurnFlag, true);
        }

        // No game over — check active mons for KOs to set the player switch for turn flag
        uint256 otherPlayerIndex = (priorityPlayerIndex + 1) % 2;
        playerSwitchForTurnFlag = 2;

        // Use already-loaded KO bitmaps to check active mon KO status (avoids SLOAD)
        uint256 priorityActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, priorityPlayerIndex);
        uint256 otherActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, otherPlayerIndex);
        uint256 priorityKOBitmap = priorityPlayerIndex == 0 ? p0KOBitmap : p1KOBitmap;
        uint256 otherKOBitmap = priorityPlayerIndex == 0 ? p1KOBitmap : p0KOBitmap;
        bool isPriorityPlayerActiveMonKnockedOut = (priorityKOBitmap & (1 << priorityActiveMonIndex)) != 0;
        bool isNonPriorityPlayerActiveMonKnockedOut = (otherKOBitmap & (1 << otherActiveMonIndex)) != 0;

        // If the priority player mon is KO'ed (and the other player isn't), then next turn we tenatively set it to be just the other player
        if (isPriorityPlayerActiveMonKnockedOut && !isNonPriorityPlayerActiveMonKnockedOut) {
            playerSwitchForTurnFlag = priorityPlayerIndex;
        }

        // If the non priority player mon is KO'ed (and the other player isn't), then next turn we tenatively set it to be just the priority player
        if (!isPriorityPlayerActiveMonKnockedOut && isNonPriorityPlayerActiveMonKnockedOut) {
            playerSwitchForTurnFlag = otherPlayerIndex;
        }
    }

    // Core switch-out logic shared between singles and doubles
    function _handleSwitchCore(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 currentActiveMonIndex,
        uint256 monToSwitchIndex,
        address source
    ) internal {
        BattleConfig storage config = battleConfig[storageKeyForWrite];
        MonState storage currentMonState = _getMonState(config, playerIndex, currentActiveMonIndex);

        // Emit event first, then run effects
        emit MonSwitch(battleKey, playerIndex, monToSwitchIndex, source);

        // If the current mon is not KO'ed, run switch-out effects
        // Pass explicit monIndex so effects run on the correct mon (not just slot 0)
        if (!currentMonState.isKnockedOut) {
            _runEffects(battleKey, tempRNG, playerIndex, playerIndex, EffectStep.OnMonSwitchOut, "", currentActiveMonIndex);
            _runEffects(battleKey, tempRNG, 2, playerIndex, EffectStep.OnMonSwitchOut, "", currentActiveMonIndex);
        }
        // Note: Caller is responsible for updating activeMonIndex with appropriate packing
    }

    // Complete switch-in effects (called after activeMonIndex is updated)
    function _completeSwitchIn(bytes32 battleKey, uint256 playerIndex, uint256 monToSwitchIndex) internal {
        BattleData storage battle = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKeyForWrite];

        // Run onMonSwitchIn hook for local effects
        // Pass explicit monIndex so effects run on the correct mon (not just slot 0)
        _runEffects(battleKey, tempRNG, playerIndex, playerIndex, EffectStep.OnMonSwitchIn, "", monToSwitchIndex);

        // Run onMonSwitchIn hook for global effects
        _runEffects(battleKey, tempRNG, 2, playerIndex, EffectStep.OnMonSwitchIn, "", monToSwitchIndex);

        // Run ability for the newly switched in mon (skip on turn 0 - execute() handles that)
        Mon memory mon = _getTeamMon(config, playerIndex, monToSwitchIndex);
        if (
            address(mon.ability) != address(0) && battle.turnId != 0
                && !_getMonState(config, playerIndex, monToSwitchIndex).isKnockedOut
        ) {
            mon.ability.activateOnSwitch(battleKey, playerIndex, monToSwitchIndex);
        }
    }

    // Singles switch: uses 8-bit packing
    function _handleSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monToSwitchIndex, address source) internal {
        BattleData storage battle = battleData[battleKey];
        uint256 currentActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, playerIndex);

        _handleSwitchCore(battleKey, playerIndex, currentActiveMonIndex, monToSwitchIndex, source);

        // Update to new active mon using 8-bit packing (singles)
        battle.activeMonIndex = _setActiveMonIndex(battle.activeMonIndex, playerIndex, monToSwitchIndex);

        _completeSwitchIn(battleKey, playerIndex, monToSwitchIndex);
    }

    // Doubles switch: uses 4-bit-per-slot packing
    function _handleSwitchForSlot(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 slotIndex,
        uint256 monToSwitchIndex,
        address source
    ) internal {
        BattleData storage battle = battleData[battleKey];
        uint256 currentActiveMonIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, slotIndex);

        _handleSwitchCore(battleKey, playerIndex, currentActiveMonIndex, monToSwitchIndex, source);

        // Update active mon for this slot using 4-bit packing (doubles)
        battle.activeMonIndex = _setActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, slotIndex, monToSwitchIndex);

        _completeSwitchIn(battleKey, playerIndex, monToSwitchIndex);
    }

    function _handleMove(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint256 playerIndex,
        uint256 prevPlayerSwitchForTurnFlag
    ) internal returns (uint256 playerSwitchForTurnFlag) {
        MoveDecision memory move = (playerIndex == 0) ? config.p0Move : config.p1Move;
        int32 staminaCost;
        playerSwitchForTurnFlag = prevPlayerSwitchForTurnFlag;

        uint8 moveIndex = _unpackMoveIndex(move.packedMoveIndex);

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

        // Handle a switch or a no-op
        // otherwise, execute the moveset
        if (moveIndex == SWITCH_MOVE_INDEX) {
            // Handle the switch (extraData contains the mon index to switch to as raw uint240)
            _handleSwitch(battleKey, playerIndex, uint256(move.extraData), address(0));
        } else if (moveIndex == NO_OP_MOVE_INDEX) {
            // Emit event and do nothing (e.g. just recover stamina)
            emit MonMove(battleKey, playerIndex, activeMonIndex, moveIndex, move.extraData, staminaCost);
        }
        // Execute the move and then set updated state, active mons, and effects/data
        else {
            // Validate the move is still valid to execute
            // Handles cases where e.g. some condition outside of the player's control leads to an invalid move
            if (!_validateMoveSelection(config, battleKey, playerIndex, activeMonIndex, moveIndex, move.extraData)) {
                return playerSwitchForTurnFlag;
            }

            IMoveSet moveSet = _getTeamMon(config, playerIndex, activeMonIndex).moves[moveIndex];

            // Update the mon state directly to account for the stamina cost of the move
            staminaCost = int32(moveSet.stamina(battleKey, playerIndex, activeMonIndex));
            currentMonState.staminaDelta = (currentMonState.staminaDelta == CLEARED_MON_STATE_SENTINEL)
                ? -staminaCost
                : currentMonState.staminaDelta - staminaCost;

            // Emit event and then run the move
            emit MonMove(battleKey, playerIndex, activeMonIndex, moveIndex, move.extraData, staminaCost);

            // Run the move with both active mon indices to avoid external lookups
            uint256 defenderMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1 - playerIndex);
            moveSet.move(battleKey, playerIndex, activeMonIndex, defenderMonIndex, move.extraData, tempRNG);
        }

        // Set Game Over if true, and calculate and return switch for turn flag
        (playerSwitchForTurnFlag,) = _checkForGameOverOrKO(config, battle, playerIndex);
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
        bytes memory extraEffectsData
    ) internal {
        // Default: calculate monIndex from active mon (singles behavior)
        _runEffectsForMon(battleKey, rng, effectIndex, playerIndex, round, extraEffectsData, type(uint256).max);
    }

    // Overload with explicit monIndex for doubles-aware effect execution
    function _runEffects(
        bytes32 battleKey,
        uint256 rng,
        uint256 effectIndex,
        uint256 playerIndex,
        EffectStep round,
        bytes memory extraEffectsData,
        uint256 monIndex
    ) internal {
        _runEffectsForMon(battleKey, rng, effectIndex, playerIndex, round, extraEffectsData, monIndex);
    }

    function _runEffectsForMon(
        bytes32 battleKey,
        uint256 rng,
        uint256 effectIndex,
        uint256 playerIndex,
        EffectStep round,
        bytes memory extraEffectsData,
        uint256 explicitMonIndex
    ) internal {
        BattleData storage battle = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKeyForWrite];

        // Get active mon indices for both players (passed to all effect hooks)
        uint256 p0ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
        uint256 p1ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);

        uint256 monIndex;
        // Use explicit monIndex if provided, otherwise calculate from active mon
        if (explicitMonIndex != type(uint256).max) {
            monIndex = explicitMonIndex;
        } else if (playerIndex != 2) {
            // Specific player - get their active mon (this takes priority over effectIndex)
            monIndex = _unpackActiveMonIndex(battle.activeMonIndex, playerIndex);
        } else if (effectIndex == 2) {
            // Global effects with global playerIndex - monIndex doesn't matter for filtering
            monIndex = 0;
        } else {
            // effectIndex is player-specific but playerIndex is global - use effectIndex
            monIndex = _unpackActiveMonIndex(battle.activeMonIndex, effectIndex);
        }

        // Iterate directly over storage, skipping tombstones
        // With tombstones, indices are stable so no snapshot needed
        uint256 baseSlot;
        if (effectIndex == 0) {
            baseSlot = _getEffectSlotIndex(monIndex, 0);
        } else if (effectIndex == 1) {
            baseSlot = _getEffectSlotIndex(monIndex, 0);
        }

        // Compute the dirty bit for this effect/mon combination
        // Bit 0: global, Bits 1-8: P0 mons 0-7, Bits 9-16: P1 mons 0-7
        uint256 dirtyBit;
        if (effectIndex == 2) {
            dirtyBit = 1;
        } else if (effectIndex == 0) {
            dirtyBit = 1 << (1 + monIndex);
        } else {
            dirtyBit = 1 << (9 + monIndex);
        }

        // Cache the initial effect count (only re-read if dirty bit is set)
        uint256 effectsCount;
        if (effectIndex == 2) {
            effectsCount = config.globalEffectsLength;
        } else if (effectIndex == 0) {
            effectsCount = _getMonEffectCount(config.packedP0EffectsCount, monIndex);
        } else {
            effectsCount = _getMonEffectCount(config.packedP1EffectsCount, monIndex);
        }

        uint256 i = 0;
        while (i < effectsCount) {
            // Read effect directly from storage
            EffectInstance storage eff;
            uint256 slotIndex;
            if (effectIndex == 2) {
                eff = config.globalEffects[i];
                slotIndex = i;
            } else if (effectIndex == 0) {
                slotIndex = baseSlot + i;
                eff = config.p0Effects[slotIndex];
            } else {
                slotIndex = baseSlot + i;
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

                // Check if this effect added new effects (dirty bit set)
                // Only re-read count if dirty, then clear the bit
                if (effectsDirtyBitmap & dirtyBit != 0) {
                    if (effectIndex == 2) {
                        effectsCount = config.globalEffectsLength;
                    } else if (effectIndex == 0) {
                        effectsCount = _getMonEffectCount(config.packedP0EffectsCount, monIndex);
                    } else {
                        effectsCount = _getMonEffectCount(config.packedP1EffectsCount, monIndex);
                    }
                    effectsDirtyBitmap &= ~dirtyBit;
                }
            }

            unchecked { ++i; }
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

        currentStep = uint256(round);

        // Emit event first, then handle side effects (use transient battleKeyForWrite)
        emit EffectRun(
            battleKeyForWrite,
            effectIndex,
            monIndex,
            address(effect),
            data,
            _getUpstreamCallerAndResetValue(),
            currentStep
        );

        // Run the effect and get result
        (bytes32 updatedExtraData, bool removeAfterRun) =
            _executeEffectHook(battleKeyForWrite, effect, rng, data, playerIndex, monIndex, round, extraEffectsData, p0ActiveMonIndex, p1ActiveMonIndex);

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
        if (round == EffectStep.RoundStart) {
            return effect.onRoundStart(battleKey, rng, data, playerIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);
        } else if (round == EffectStep.RoundEnd) {
            return effect.onRoundEnd(battleKey, rng, data, playerIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);
        } else if (round == EffectStep.OnMonSwitchIn) {
            return effect.onMonSwitchIn(battleKey, rng, data, playerIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);
        } else if (round == EffectStep.OnMonSwitchOut) {
            return effect.onMonSwitchOut(battleKey, rng, data, playerIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);
        } else if (round == EffectStep.AfterDamage) {
            return
                effect.onAfterDamage(battleKey, rng, data, playerIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex, abi.decode(extraEffectsData, (int32)));
        } else if (round == EffectStep.AfterMove) {
            return effect.onAfterMove(battleKey, rng, data, playerIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);
        } else if (round == EffectStep.OnUpdateMonState) {
            (uint256 statePlayerIndex, uint256 stateMonIndex, MonStateIndexName stateVarIndex, int32 valueToAdd) =
                abi.decode(extraEffectsData, (uint256, uint256, MonStateIndexName, int32));
            return
                effect.onUpdateMonState(
                    battleKey, rng, data, statePlayerIndex, stateMonIndex, p0ActiveMonIndex, p1ActiveMonIndex, stateVarIndex, valueToAdd
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
        // If non-global effect, check if we should still run if mon is KOed
        if (effectIndex != 2) {
            bool isMonKOed =
                _getMonState(config, playerIndex, _unpackActiveMonIndex(battle.activeMonIndex, playerIndex))
            .isKnockedOut;
            if (isMonKOed && condition == EffectRunCondition.SkipIfGameOverOrMonKO) {
                return playerSwitchForTurnFlag;
            }
        }

        // Otherwise, run the effect
        _runEffects(battleKey, rng, effectIndex, playerIndex, round, "");

        // Set Game Over if true, and calculate and return switch for turn flag
        (playerSwitchForTurnFlag,) = _checkForGameOverOrKO(config, battle, playerIndex);
        return playerSwitchForTurnFlag;
    }

    function computePriorityPlayerIndex(bytes32 battleKey, uint256 rng) public view returns (uint256) {
        // Use cached storage key if available (during execute), otherwise compute
        bytes32 storageKey = storageKeyForWrite != bytes32(0) ? storageKeyForWrite : _getStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        BattleData storage battle = battleData[battleKey];

        uint8 p0MoveIndex = _unpackMoveIndex(config.p0Move.packedMoveIndex);
        uint8 p1MoveIndex = _unpackMoveIndex(config.p1Move.packedMoveIndex);

        uint256 p0ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 0);
        uint256 p1ActiveMonIndex = _unpackActiveMonIndex(battle.activeMonIndex, 1);

        // Get priority and speed for each player's move
        (uint256 p0Priority, uint32 p0MonSpeed) = _getPriorityAndSpeed(config, battleKey, 0, p0ActiveMonIndex, p0MoveIndex);
        (uint256 p1Priority, uint32 p1MonSpeed) = _getPriorityAndSpeed(config, battleKey, 1, p1ActiveMonIndex, p1MoveIndex);

        // Determine priority based on (in descending order of importance):
        // - the higher priority tier
        // - within same priority, the higher speed
        // - if both are tied, use the rng value
        if (p0Priority > p1Priority) {
            return 0;
        } else if (p0Priority < p1Priority) {
            return 1;
        } else {
            if (p0MonSpeed > p1MonSpeed) {
                return 0;
            } else if (p0MonSpeed < p1MonSpeed) {
                return 1;
            } else {
                return rng % 2;
            }
        }
    }

    function _getUpstreamCallerAndResetValue() internal view returns (address) {
        address source = upstreamCaller;
        if (source == address(0)) {
            source = msg.sender;
        }
        return source;
    }

    /**
     * - Helper functions for packing/unpacking activeMonIndex
     */
    function _packActiveMonIndices(uint8 player0Index, uint8 player1Index) internal pure returns (uint16) {
        return uint16(player0Index) | (uint16(player1Index) << 8);
    }

    function _unpackActiveMonIndex(uint16 packed, uint256 playerIndex) internal pure returns (uint256) {
        // Use 4-bit mask (0x0F) to be compatible with both 8-bit (singles) and 4-bit (doubles) packing
        // Mon indices are always < 16, so this is safe for both formats
        if (playerIndex == 0) {
            return uint256(packed) & ACTIVE_MON_INDEX_MASK;
        } else {
            return (uint256(packed) >> 8) & ACTIVE_MON_INDEX_MASK;
        }
    }

    function _setActiveMonIndex(uint16 packed, uint256 playerIndex, uint256 monIndex) internal pure returns (uint16) {
        if (playerIndex == 0) {
            return (packed & 0xFF00) | uint16(uint8(monIndex));
        } else {
            return (packed & 0x00FF) | (uint16(uint8(monIndex)) << 8);
        }
    }

    // Doubles-specific helper functions for slot-based active mon packing
    // Layout: 4 bits per slot - [p0s0][p0s1][p1s0][p1s1] from LSB to MSB
    function _getActiveMonIndexForSlot(uint16 packed, uint256 playerIndex, uint256 slotIndex)
        internal
        pure
        returns (uint256)
    {
        uint256 shift = (playerIndex * 2 + slotIndex) * ACTIVE_MON_INDEX_BITS;
        return (uint256(packed) >> shift) & ACTIVE_MON_INDEX_MASK;
    }

    function _setActiveMonIndexForSlot(uint16 packed, uint256 playerIndex, uint256 slotIndex, uint256 monIndex)
        internal
        pure
        returns (uint16)
    {
        uint256 shift = (playerIndex * 2 + slotIndex) * ACTIVE_MON_INDEX_BITS;
        uint256 cleared = uint256(packed) & ~(uint256(ACTIVE_MON_INDEX_MASK) << shift);
        return uint16(cleared | (monIndex << shift));
    }

    function _isDoublesMode(BattleData storage data) internal view returns (bool) {
        return (data.slotSwitchFlagsAndGameMode & GAME_MODE_BIT) != 0;
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

    function _getMonState(BattleConfig storage config, uint256 playerIndex, uint256 monIndex)
        private
        view
        returns (MonState storage)
    {
        return playerIndex == 0 ? config.p0States[monIndex] : config.p1States[monIndex];
    }

    // Unpack moveIndex from packedMoveIndex (lower 7 bits, with +1 offset for regular moves)
    function _unpackMoveIndex(uint8 packedMoveIndex) private pure returns (uint8) {
        uint8 storedMoveIndex = packedMoveIndex & MOVE_INDEX_MASK;
        return storedMoveIndex >= SWITCH_MOVE_INDEX ? storedMoveIndex : storedMoveIndex - MOVE_INDEX_OFFSET;
    }

    // Get priority and effective speed for a player's move (shared between singles and doubles)
    function _getPriorityAndSpeed(
        BattleConfig storage config,
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        uint8 moveIndex
    ) private view returns (uint256 priority, uint32 speed) {
        if (moveIndex == SWITCH_MOVE_INDEX || moveIndex == NO_OP_MOVE_INDEX) {
            priority = SWITCH_PRIORITY;
        } else {
            IMoveSet moveSet = _getTeamMon(config, playerIndex, monIndex).moves[moveIndex];
            priority = moveSet.priority(battleKey, playerIndex);
        }

        int32 speedDelta = _getMonState(config, playerIndex, monIndex).speedDelta;
        speed = uint32(
            int32(_getTeamMon(config, playerIndex, monIndex).stats.speed)
                + (speedDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : speedDelta)
        );
    }

    // Validate a specific move selection using either inline or external validator
    function _validateMoveSelection(
        BattleConfig storage config,
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        uint8 moveIndex,
        uint240 extraData
    ) private returns (bool) {
        if (address(config.validator) == address(0)) {
            // Use inline validation (no external call)
            IMoveSet moveSet = _getTeamMon(config, playerIndex, monIndex).moves[moveIndex];
            uint32 baseStamina = _getTeamMon(config, playerIndex, monIndex).stats.stamina;
            int32 staminaDelta = _getMonState(config, playerIndex, monIndex).staminaDelta;
            return ValidatorLogic.validateSpecificMoveSelection(
                battleKey, moveSet, playerIndex, monIndex, extraData, baseStamina, staminaDelta
            );
        } else {
            // Use external validator
            return config.validator.validateSpecificMoveSelection(battleKey, moveIndex, playerIndex, extraData);
        }
    }

    // Run engine hooks for a specific step
    function _runEngineHooks(BattleConfig storage config, bytes32 battleKey, EngineHookStep step) internal {
        uint256 numHooks = config.engineHooksLength;
        uint256 stepBit = 1 << uint8(step);
        for (uint256 i = 0; i < numHooks;) {
            if ((config.engineHooks[i].stepsBitmap & stepBit) != 0) {
                IEngineHook hook = config.engineHooks[i].hook;
                if (step == EngineHookStep.OnBattleStart) {
                    hook.onBattleStart(battleKey);
                } else if (step == EngineHookStep.OnRoundStart) {
                    hook.onRoundStart(battleKey);
                } else if (step == EngineHookStep.OnRoundEnd) {
                    hook.onRoundEnd(battleKey);
                } else {
                    hook.onBattleEnd(battleKey);
                }
            }
            unchecked {
                ++i;
            }
        }
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
        bytes32 storageKey = _getStorageKey(battleKey);
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

        BattleConfigView memory configView = BattleConfigView({
            validator: config.validator,
            rngOracle: config.rngOracle,
            moveManager: config.moveManager,
            globalEffectsLength: config.globalEffectsLength,
            packedP0EffectsCount: config.packedP0EffectsCount,
            packedP1EffectsCount: config.packedP1EffectsCount,
            teamSizes: config.teamSizes,
            p0Salt: config.p0Salt,
            p1Salt: config.p1Salt,
            p0Move: config.p0Move,
            p1Move: config.p1Move,
            p0Move2: config.p0Move2,
            p1Move2: config.p1Move2,
            globalEffects: globalEffects,
            p0Effects: p0Effects,
            p1Effects: p1Effects,
            teams: teams,
            monStates: monStates
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

    function getBattleValidator(bytes32 battleKey) external view returns (IValidator) {
        return battleConfig[_getStorageKey(battleKey)].validator;
    }

    /// @notice Validates a player move, handling both inline validation (when validator is address(0)) and external validators
    /// @dev This allows callers like CPU to validate moves without needing to handle the address(0) case themselves
    function validatePlayerMoveForBattle(
        bytes32 battleKey,
        uint256 moveIndex,
        uint256 playerIndex,
        uint240 extraData
    ) external returns (bool) {
        bytes32 storageKey = _getStorageKey(battleKey);
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
        (, bool isNoOp, bool isSwitch, bool isRegularMove, bool basicValid) =
            ValidatorLogic.validatePlayerMoveBasics(moveIndex, data.turnId, activeMonState.isKnockedOut, DEFAULT_MOVES_PER_MON);

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
            IMoveSet moveSet = activeMon.moves[moveIndex];
            uint32 baseStamina = activeMon.stats.stamina;
            int32 staminaDelta = activeMonState.staminaDelta;
            return ValidatorLogic.validateSpecificMoveSelection(
                battleKey, moveSet, playerIndex, activeMonIndex, extraData, baseStamina, staminaDelta
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
        bytes32 storageKey = _getStorageKey(battleKey);
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
        bytes32 storageKey = _getStorageKey(battleKey);
        uint8 teamSizes = battleConfig[storageKey].teamSizes;
        return (playerIndex == 0) ? (teamSizes & 0x0F) : (teamSizes >> 4);
    }

    function getMoveForMonForBattle(bytes32 battleKey, uint256 playerIndex, uint256 monIndex, uint256 moveIndex)
        external
        view
        returns (IMoveSet)
    {
        bytes32 storageKey = _getStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        return _getTeamMon(config, playerIndex, monIndex).moves[moveIndex];
    }

    function getMoveDecisionForBattleState(bytes32 battleKey, uint256 playerIndex)
        external
        view
        returns (MoveDecision memory)
    {
        BattleConfig storage config = battleConfig[_getStorageKey(battleKey)];
        return (playerIndex == 0) ? config.p0Move : config.p1Move;
    }

    function getPlayersForBattle(bytes32 battleKey) external view returns (address[] memory) {
        address[] memory players = new address[](2);
        players[0] = battleData[battleKey].p0;
        players[1] = battleData[battleKey].p1;
        return players;
    }

    function getMonStatsForBattle(bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        external
        view
        returns (MonStats memory)
    {
        bytes32 storageKey = _getStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
        return _getTeamMon(config, playerIndex, monIndex).stats;
    }

    function getMonStateForBattle(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex
    ) external view returns (int32) {
        bytes32 storageKey = _getStorageKey(battleKey);
        BattleConfig storage config = battleConfig[storageKey];
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

    function getMonStateForStorageKey(
        bytes32 storageKey,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex
    ) external view returns (int32) {
        BattleConfig storage config = battleConfig[storageKey];
        MonState storage monState = _getMonState(config, playerIndex, monIndex);

        if (stateVarIndex == MonStateIndexName.Hp) {
            return monState.hpDelta;
        } else if (stateVarIndex == MonStateIndexName.Stamina) {
            return monState.staminaDelta;
        } else if (stateVarIndex == MonStateIndexName.Speed) {
            return monState.speedDelta;
        } else if (stateVarIndex == MonStateIndexName.Attack) {
            return monState.attackDelta;
        } else if (stateVarIndex == MonStateIndexName.Defense) {
            return monState.defenceDelta;
        } else if (stateVarIndex == MonStateIndexName.SpecialAttack) {
            return monState.specialAttackDelta;
        } else if (stateVarIndex == MonStateIndexName.SpecialDefense) {
            return monState.specialDefenceDelta;
        } else if (stateVarIndex == MonStateIndexName.IsKnockedOut) {
            return monState.isKnockedOut ? int32(1) : int32(0);
        } else if (stateVarIndex == MonStateIndexName.ShouldSkipTurn) {
            return monState.shouldSkipTurn ? int32(1) : int32(0);
        } else {
            return int32(0);
        }
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

    function getPlayerSwitchForTurnFlagForBattleState(bytes32 battleKey) external view returns (uint256) {
        return battleData[battleKey].playerSwitchForTurnFlag;
    }

    function getGlobalKV(bytes32 battleKey, bytes32 key) external view returns (uint192) {
        bytes32 storageKey = _getStorageKey(battleKey);
        bytes32 packed = globalKV[storageKey][key];
        // Extract timestamp (upper 64 bits) and value (lower 192 bits)
        uint64 storedTimestamp = uint64(uint256(packed) >> 192);
        uint64 currentTimestamp = battleConfig[storageKey].startTimestamp;
        // If timestamps don't match, return 0 (stale value from different battle)
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
        bytes32 storageKey = _getStorageKey(battleKey);
        return _getEffectsForTarget(storageKey, targetIndex, monIndex);
    }

    function getWinner(bytes32 battleKey) external view returns (address) {
        BattleData storage data = battleData[battleKey];
        uint8 winnerIndex = data.winnerIndex;
        if (winnerIndex == 2) {
            return address(0);
        }
        return (winnerIndex == 0) ? data.p0 : data.p1;
    }

    function getStartTimestamp(bytes32 battleKey) external view returns (uint256) {
        return battleConfig[_getStorageKey(battleKey)].startTimestamp;
    }

    function getLastExecuteTimestamp(bytes32 battleKey) external view returns (uint48) {
        return battleConfig[_getStorageKey(battleKey)].lastExecuteTimestamp;
    }

    function getKOBitmap(bytes32 battleKey, uint256 playerIndex) external view returns (uint256) {
        return _getKOBitmap(battleConfig[_getStorageKey(battleKey)], playerIndex);
    }

    function getPrevPlayerSwitchForTurnFlagForBattleState(bytes32 battleKey) external view returns (uint256) {
        return battleData[battleKey].prevPlayerSwitchForTurnFlag;
    }

    function getMoveManager(bytes32 battleKey) external view returns (address) {
        return battleConfig[_getStorageKey(battleKey)].moveManager;
    }

    function getGameMode(bytes32 battleKey) external view returns (GameMode) {
        return _isDoublesMode(battleData[battleKey]) ? GameMode.Doubles : GameMode.Singles;
    }

    function getActiveMonIndexForSlot(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex)
        external
        view
        returns (uint256)
    {
        return _getActiveMonIndexForSlot(battleData[battleKey].activeMonIndex, playerIndex, slotIndex);
    }

    function getBattleContext(bytes32 battleKey) external view returns (BattleContext memory ctx) {
        bytes32 storageKey = _getStorageKey(battleKey);
        BattleData storage data = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        ctx.startTimestamp = config.startTimestamp;
        ctx.p0 = data.p0;
        ctx.p1 = data.p1;
        ctx.winnerIndex = data.winnerIndex;
        ctx.turnId = data.turnId;
        ctx.playerSwitchForTurnFlag = data.playerSwitchForTurnFlag;
        ctx.prevPlayerSwitchForTurnFlag = data.prevPlayerSwitchForTurnFlag;
        ctx.validator = address(config.validator);
        ctx.moveManager = config.moveManager;

        uint8 flags = data.slotSwitchFlagsAndGameMode;
        if ((flags & GAME_MODE_BIT) != 0) {
            // Doubles mode: use 4-bit slot packing
            ctx.gameMode = GameMode.Doubles;
            ctx.slotSwitchFlags = flags & SWITCH_FLAGS_MASK;
            uint16 packed = data.activeMonIndex;
            ctx.p0ActiveMonIndex = uint8(_getActiveMonIndexForSlot(packed, 0, 0));
            ctx.p1ActiveMonIndex = uint8(_getActiveMonIndexForSlot(packed, 1, 0));
            ctx.p0ActiveMonIndex1 = uint8(_getActiveMonIndexForSlot(packed, 0, 1));
            ctx.p1ActiveMonIndex1 = uint8(_getActiveMonIndexForSlot(packed, 1, 1));
        } else {
            // Singles mode: use 8-bit packing (backward compatible)
            ctx.gameMode = GameMode.Singles;
            ctx.p0ActiveMonIndex = uint8(data.activeMonIndex & 0xFF);
            ctx.p1ActiveMonIndex = uint8(data.activeMonIndex >> 8);
        }
    }

    function getCommitContext(bytes32 battleKey) external view returns (CommitContext memory ctx) {
        bytes32 storageKey = _getStorageKey(battleKey);
        BattleData storage data = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        ctx.startTimestamp = config.startTimestamp;
        ctx.p0 = data.p0;
        ctx.p1 = data.p1;
        ctx.winnerIndex = data.winnerIndex;
        ctx.turnId = data.turnId;
        ctx.playerSwitchForTurnFlag = data.playerSwitchForTurnFlag;
        ctx.validator = address(config.validator);

        uint8 flags = data.slotSwitchFlagsAndGameMode;
        ctx.slotSwitchFlags = flags & SWITCH_FLAGS_MASK;
        ctx.gameMode = (flags & GAME_MODE_BIT) != 0 ? GameMode.Doubles : GameMode.Singles;
    }

    /// @notice Lightweight getter for dual-signed flow that validates state and returns only needed fields
    /// @dev Reverts internally if battle not started, already complete, or not a two-player turn
    function getCommitAuthForDualSigned(bytes32 battleKey)
        external
        view
        returns (address committer, address revealer, uint64 turnId)
    {
        bytes32 storageKey = _getStorageKey(battleKey);
        BattleData storage data = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        if (config.startTimestamp == 0) revert BattleNotStarted();
        if (data.winnerIndex != 2) revert GameAlreadyOver();
        if (data.playerSwitchForTurnFlag != 2) revert NotTwoPlayerTurn();

        turnId = data.turnId;
        if (turnId % 2 == 0) {
            committer = data.p0;
            revealer = data.p1;
        } else {
            committer = data.p1;
            revealer = data.p0;
        }
    }

    function getDamageCalcContext(bytes32 battleKey, uint256 attackerPlayerIndex, uint256 defenderPlayerIndex)
        external
        view
        returns (DamageCalcContext memory ctx)
    {
        bytes32 storageKey = _getStorageKey(battleKey);
        BattleData storage data = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        // Get active mon indices
        uint256 attackerMonIndex = _unpackActiveMonIndex(data.activeMonIndex, attackerPlayerIndex);
        uint256 defenderMonIndex = _unpackActiveMonIndex(data.activeMonIndex, defenderPlayerIndex);

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

    // Slot-aware overload for doubles - uses explicit slot indices to get correct mon
    function getDamageCalcContext(
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerSlotIndex,
        uint256 defenderPlayerIndex,
        uint256 defenderSlotIndex
    ) external view returns (DamageCalcContext memory ctx) {
        bytes32 storageKey = _getStorageKey(battleKey);
        BattleData storage data = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        // Get active mon indices using slot-aware lookup
        uint256 attackerMonIndex = _getActiveMonIndexForSlot(data.activeMonIndex, attackerPlayerIndex, attackerSlotIndex);
        uint256 defenderMonIndex = _getActiveMonIndexForSlot(data.activeMonIndex, defenderPlayerIndex, defenderSlotIndex);

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

    // ==================== Doubles Support Functions ====================

    // Struct for tracking move order in doubles
    struct MoveOrder {
        uint256 playerIndex;
        uint256 slotIndex;
        uint256 priority;
        uint256 speed;
    }

    // Main execution function for doubles mode
    function _executeDoubles(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint256 turnId,
        uint256 numHooks
    ) internal {
        // Update the temporary RNG
        uint256 rng = config.rngOracle.getRNG(config.p0Salt, config.p1Salt);
        tempRNG = rng;

        // Compute move order for all 4 slots
        MoveOrder[4] memory moveOrder = _computeMoveOrderForDoubles(battleKey, config, battle);

        // Run beginning of round effects (global)
        _runEffects(battleKey, rng, 2, 2, EffectStep.RoundStart, "");

        // Run beginning of round effects for each slot's mon (if not KO'd)
        for (uint256 i = 0; i < 4; i++) {
            uint256 p = moveOrder[i].playerIndex;
            uint256 s = moveOrder[i].slotIndex;
            uint256 monIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, p, s);
            if (!_getMonState(config, p, monIndex).isKnockedOut) {
                _runEffects(battleKey, rng, p, p, EffectStep.RoundStart, "", monIndex);
            }
        }

        // Execute moves in priority order
        for (uint256 i = 0; i < 4; i++) {
            uint256 p = moveOrder[i].playerIndex;
            uint256 s = moveOrder[i].slotIndex;

            // Execute the move for this slot
            _handleMoveForSlot(battleKey, config, battle, p, s);

            // Check for game over after each move
            if (_checkForGameOverOrKO_Doubles(config, battle)) {
                // Game is over, handle cleanup and return
                address winner = (battle.winnerIndex == 0) ? battle.p0 : battle.p1;
                _handleGameOver(battleKey, winner);
                for (uint256 j = 0; j < numHooks;) {
                    if ((config.engineHooks[j].stepsBitmap & (1 << uint8(EngineHookStep.OnRoundEnd))) != 0) {
                        config.engineHooks[j].hook.onRoundEnd(battleKey);
                    }
                    unchecked { ++j; }
                }
                emit EngineExecute(battleKey, turnId, 2, moveOrder[0].playerIndex);
                return;
            }
        }

        // For turn 0 only: handle ability activateOnSwitch for all 4 mons
        if (turnId == 0) {
            for (uint256 p = 0; p < 2; p++) {
                for (uint256 s = 0; s < 2; s++) {
                    uint256 monIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, p, s);
                    Mon memory mon = _getTeamMon(config, p, monIndex);
                    if (address(mon.ability) != address(0)) {
                        mon.ability.activateOnSwitch(battleKey, p, monIndex);
                    }
                }
            }
        }

        // Run afterMove effects for each slot (in move order)
        for (uint256 i = 0; i < 4; i++) {
            uint256 p = moveOrder[i].playerIndex;
            uint256 s = moveOrder[i].slotIndex;
            uint256 monIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, p, s);
            if (!_getMonState(config, p, monIndex).isKnockedOut) {
                _runEffects(battleKey, rng, p, p, EffectStep.AfterMove, "", monIndex);
            }
        }

        // Run global afterMove effects
        _runEffects(battleKey, rng, 2, 2, EffectStep.AfterMove, "");

        // Check for game over after effects
        if (_checkForGameOverOrKO_Doubles(config, battle)) {
            address winner = (battle.winnerIndex == 0) ? battle.p0 : battle.p1;
            _handleGameOver(battleKey, winner);
            for (uint256 j = 0; j < numHooks;) {
                if ((config.engineHooks[j].stepsBitmap & (1 << uint8(EngineHookStep.OnRoundEnd))) != 0) {
                    config.engineHooks[j].hook.onRoundEnd(battleKey);
                }
                unchecked { ++j; }
            }
            emit EngineExecute(battleKey, turnId, 2, moveOrder[0].playerIndex);
            return;
        }

        // Run global roundEnd effects
        _runEffects(battleKey, rng, 2, 2, EffectStep.RoundEnd, "");

        // Run roundEnd effects for each slot (in move order)
        for (uint256 i = 0; i < 4; i++) {
            uint256 p = moveOrder[i].playerIndex;
            uint256 s = moveOrder[i].slotIndex;
            uint256 monIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, p, s);
            if (!_getMonState(config, p, monIndex).isKnockedOut) {
                _runEffects(battleKey, rng, p, p, EffectStep.RoundEnd, "", monIndex);
            }
        }

        // Final game over check after round end effects
        if (_checkForGameOverOrKO_Doubles(config, battle)) {
            address winner = (battle.winnerIndex == 0) ? battle.p0 : battle.p1;
            _handleGameOver(battleKey, winner);
            for (uint256 j = 0; j < numHooks;) {
                if ((config.engineHooks[j].stepsBitmap & (1 << uint8(EngineHookStep.OnRoundEnd))) != 0) {
                    config.engineHooks[j].hook.onRoundEnd(battleKey);
                }
                unchecked { ++j; }
            }
            emit EngineExecute(battleKey, turnId, 2, moveOrder[0].playerIndex);
            return;
        }

        // Run round end hooks
        for (uint256 i = 0; i < numHooks;) {
            if ((config.engineHooks[i].stepsBitmap & (1 << uint8(EngineHookStep.OnRoundEnd))) != 0) {
                config.engineHooks[i].hook.onRoundEnd(battleKey);
            }
            unchecked { ++i; }
        }

        // End of turn cleanup
        battle.turnId += 1;
        // playerSwitchForTurnFlag was already set by _checkForGameOverOrKO_Doubles

        // Clear move flags for next turn
        config.p0Move.packedMoveIndex = 0;
        config.p1Move.packedMoveIndex = 0;
        config.p0Move2.packedMoveIndex = 0;
        config.p1Move2.packedMoveIndex = 0;

        emit EngineExecute(battleKey, turnId, 2, moveOrder[0].playerIndex);
    }

    // Handle a move for a specific slot in doubles
    function _handleMoveForSlot(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle,
        uint256 playerIndex,
        uint256 slotIndex
    ) internal returns (bool monKOed) {
        MoveDecision memory move = _getMoveDecisionForSlot(config, playerIndex, slotIndex);
        int32 staminaCost;

        // Check if move was set (isRealTurn bit)
        if ((move.packedMoveIndex & IS_REAL_TURN_BIT) == 0) {
            return false;
        }

        uint8 moveIndex = _unpackMoveIndex(move.packedMoveIndex);

        // Get active mon for this slot
        uint256 activeMonIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, slotIndex);
        MonState storage currentMonState = _getMonState(config, playerIndex, activeMonIndex);

        // Handle shouldSkipTurn flag
        if (currentMonState.shouldSkipTurn) {
            currentMonState.shouldSkipTurn = false;
            return false;
        }

        // Skip if mon is already KO'd (unless it's a switch - switching away from KO'd mon is allowed)
        if (currentMonState.isKnockedOut && moveIndex != SWITCH_MOVE_INDEX) {
            return false;
        }

        // Handle switch, no-op, or regular move
        if (moveIndex == SWITCH_MOVE_INDEX) {
            uint256 targetMonIndex = uint256(move.extraData);
            // Check if target mon is already active in other slot
            uint256 otherSlotIndex = 1 - slotIndex;
            uint256 otherSlotActiveMonIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, otherSlotIndex);
            if (targetMonIndex == otherSlotActiveMonIndex) {
                // Target mon is already active in other slot - treat as NO_OP
                emit MonMove(battleKey, playerIndex, activeMonIndex, NO_OP_MOVE_INDEX, move.extraData, staminaCost);
            } else {
                _handleSwitchForSlot(battleKey, playerIndex, slotIndex, targetMonIndex, address(0));
            }
        } else if (moveIndex == NO_OP_MOVE_INDEX) {
            emit MonMove(battleKey, playerIndex, activeMonIndex, moveIndex, move.extraData, staminaCost);
        } else {
            // Validate the move is still valid to execute
            if (!_validateMoveSelection(config, battleKey, playerIndex, activeMonIndex, moveIndex, move.extraData)) {
                return false;
            }

            IMoveSet moveSet = _getTeamMon(config, playerIndex, activeMonIndex).moves[moveIndex];

            // Deduct stamina
            staminaCost = int32(moveSet.stamina(battleKey, playerIndex, activeMonIndex));
            currentMonState.staminaDelta = (currentMonState.staminaDelta == CLEARED_MON_STATE_SENTINEL)
                ? -staminaCost
                : currentMonState.staminaDelta - staminaCost;

            emit MonMove(battleKey, playerIndex, activeMonIndex, moveIndex, move.extraData, staminaCost);

            // Execute the move - use slot 0 of opponent as default defender
            uint256 defenderMonIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, 1 - playerIndex, 0);
            moveSet.move(battleKey, playerIndex, activeMonIndex, defenderMonIndex, move.extraData, tempRNG);
        }

        // Check if mon got KO'd as a result of this move
        return currentMonState.isKnockedOut;
    }

    // Get the move decision for a specific player and slot
    function _getMoveDecisionForSlot(BattleConfig storage config, uint256 playerIndex, uint256 slotIndex)
        internal
        view
        returns (MoveDecision memory)
    {
        if (playerIndex == 0) {
            return slotIndex == 0 ? config.p0Move : config.p0Move2;
        } else {
            return slotIndex == 0 ? config.p1Move : config.p1Move2;
        }
    }

    // Compute move order for all 4 slots in doubles (sorted by priority desc, then speed desc)
    function _computeMoveOrderForDoubles(
        bytes32 battleKey,
        BattleConfig storage config,
        BattleData storage battle
    ) internal view returns (MoveOrder[4] memory moveOrder) {
        // Collect move info for all 4 slots
        for (uint256 p = 0; p < 2; p++) {
            for (uint256 s = 0; s < 2; s++) {
                uint256 idx = p * 2 + s;
                moveOrder[idx].playerIndex = p;
                moveOrder[idx].slotIndex = s;

                MoveDecision memory move = _getMoveDecisionForSlot(config, p, s);

                // If move wasn't set, treat as lowest priority
                if ((move.packedMoveIndex & IS_REAL_TURN_BIT) == 0) {
                    moveOrder[idx].priority = 0;
                    moveOrder[idx].speed = 0;
                    continue;
                }

                uint8 moveIndex = _unpackMoveIndex(move.packedMoveIndex);
                uint256 monIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, p, s);

                (uint256 priority, uint32 speed) = _getPriorityAndSpeed(config, battleKey, p, monIndex, moveIndex);
                moveOrder[idx].priority = priority;
                moveOrder[idx].speed = speed;
            }
        }

        // Sort by priority (desc), then speed (desc), position as tiebreaker (implicit)
        // Simple bubble sort (only 4 elements)
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = 0; j < 3 - i; j++) {
                bool shouldSwap = false;
                if (moveOrder[j].priority < moveOrder[j + 1].priority) {
                    shouldSwap = true;
                } else if (moveOrder[j].priority == moveOrder[j + 1].priority) {
                    if (moveOrder[j].speed < moveOrder[j + 1].speed) {
                        shouldSwap = true;
                    }
                }

                if (shouldSwap) {
                    MoveOrder memory temp = moveOrder[j];
                    moveOrder[j] = moveOrder[j + 1];
                    moveOrder[j + 1] = temp;
                }
            }
        }
    }

    // Shared game over check - returns winner index (0, 1, or 2 if no winner) and KO bitmaps
    function _checkForGameOver(BattleConfig storage config, BattleData storage battle)
        internal
        view
        returns (uint256 winnerIndex, uint256 p0KOBitmap, uint256 p1KOBitmap)
    {
        // First check if we already calculated a winner
        if (battle.winnerIndex != 2) {
            return (battle.winnerIndex, 0, 0);
        }

        // Load KO bitmaps and team sizes, delegate pure comparison to library
        p0KOBitmap = _getKOBitmap(config, 0);
        p1KOBitmap = _getKOBitmap(config, 1);
        winnerIndex = ValidatorLogic.checkGameOver(
            p0KOBitmap, p1KOBitmap, config.teamSizes & 0x0F, config.teamSizes >> 4
        );
    }

    // Check for game over or KO in doubles mode
    function _checkForGameOverOrKO_Doubles(
        BattleConfig storage config,
        BattleData storage battle
    ) internal returns (bool isGameOver) {
        // Use shared game over check
        (uint256 winnerIndex, uint256 p0KOBitmap, uint256 p1KOBitmap) = _checkForGameOver(config, battle);

        if (winnerIndex != 2) {
            battle.winnerIndex = uint8(winnerIndex);
            return true;
        }

        // No game over - check each slot for KO and set switch flags
        _clearSlotSwitchFlags(battle);
        for (uint256 p = 0; p < 2; p++) {
            uint256 koBitmap = p == 0 ? p0KOBitmap : p1KOBitmap;
            for (uint256 s = 0; s < 2; s++) {
                uint256 activeMonIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, p, s);
                bool isKOed = (koBitmap & (1 << activeMonIndex)) != 0;
                if (isKOed) {
                    _setSlotSwitchFlag(battle, p, s);
                }
            }
        }

        // Determine if either player needs a switch turn
        bool p0NeedsSwitch = _playerNeedsSwitchTurn(config, battle, 0, p0KOBitmap);
        bool p1NeedsSwitch = _playerNeedsSwitchTurn(config, battle, 1, p1KOBitmap);

        // Set playerSwitchForTurnFlag
        if (p0NeedsSwitch && p1NeedsSwitch) {
            battle.playerSwitchForTurnFlag = 2; // Both act (switch-only turn)
        } else if (p0NeedsSwitch) {
            battle.playerSwitchForTurnFlag = 0; // Only p0
        } else if (p1NeedsSwitch) {
            battle.playerSwitchForTurnFlag = 1; // Only p1
        } else {
            battle.playerSwitchForTurnFlag = 2; // Normal turn (both act)
        }

        return false;
    }

    // Check if a player has any KO'd slot with a valid switch target
    function _playerNeedsSwitchTurn(
        BattleConfig storage config,
        BattleData storage battle,
        uint256 playerIndex,
        uint256 koBitmap
    ) internal view returns (bool needsSwitch) {
        uint256 teamSize = playerIndex == 0 ? (config.teamSizes & 0x0F) : (config.teamSizes >> 4);

        for (uint256 s = 0; s < 2; s++) {
            uint256 activeMonIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, s);
            bool isSlotKOed = (koBitmap & (1 << activeMonIndex)) != 0;

            if (isSlotKOed) {
                // Check if there's a valid switch target
                uint256 otherSlotMonIndex = _getActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, 1 - s);
                for (uint256 m = 0; m < teamSize; m++) {
                    if ((koBitmap & (1 << m)) != 0) continue; // Skip KO'd
                    if (m == otherSlotMonIndex) continue; // Skip other slot's active mon
                    return true; // Found valid target
                }
            }
        }
        return false;
    }

    // Set slot switch flag for a specific slot
    function _setSlotSwitchFlag(BattleData storage battle, uint256 playerIndex, uint256 slotIndex) internal {
        uint8 flagBit;
        if (playerIndex == 0) {
            flagBit = slotIndex == 0 ? SWITCH_FLAG_P0_SLOT0 : SWITCH_FLAG_P0_SLOT1;
        } else {
            flagBit = slotIndex == 0 ? SWITCH_FLAG_P1_SLOT0 : SWITCH_FLAG_P1_SLOT1;
        }
        battle.slotSwitchFlagsAndGameMode |= flagBit;
    }

    // Clear all slot switch flags (keep game mode bit)
    function _clearSlotSwitchFlags(BattleData storage battle) internal {
        battle.slotSwitchFlagsAndGameMode &= ~SWITCH_FLAGS_MASK;
    }

    // ==================== End Doubles Support Functions ====================

    function getValidationContext(bytes32 battleKey) external view returns (ValidationContext memory ctx) {
        bytes32 storageKey = _getStorageKey(battleKey);
        BattleData storage data = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        ctx.turnId = data.turnId;
        ctx.playerSwitchForTurnFlag = data.playerSwitchForTurnFlag;

        // Get active mon indices
        uint256 p0MonIndex = _unpackActiveMonIndex(data.activeMonIndex, 0);
        uint256 p1MonIndex = _unpackActiveMonIndex(data.activeMonIndex, 1);
        ctx.p0ActiveMonIndex = uint8(p0MonIndex);
        ctx.p1ActiveMonIndex = uint8(p1MonIndex);

        // Get KO status for active mons
        MonState storage p0State = config.p0States[p0MonIndex];
        MonState storage p1State = config.p1States[p1MonIndex];
        ctx.p0ActiveMonKnockedOut = p0State.isKnockedOut;
        ctx.p1ActiveMonKnockedOut = p1State.isKnockedOut;

        // Get stamina info for active mons
        Mon storage p0Mon = config.p0Team[p0MonIndex];
        Mon storage p1Mon = config.p1Team[p1MonIndex];
        ctx.p0ActiveMonBaseStamina = p0Mon.stats.stamina;
        ctx.p0ActiveMonStaminaDelta =
            p0State.staminaDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : p0State.staminaDelta;
        ctx.p1ActiveMonBaseStamina = p1Mon.stats.stamina;
        ctx.p1ActiveMonStaminaDelta =
            p1State.staminaDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : p1State.staminaDelta;
    }
}
