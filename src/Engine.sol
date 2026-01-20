// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Constants.sol";

import "./Enums.sol";
import "./Structs.sol";
import "./moves/IMoveSet.sol";

import {IEngine} from "./IEngine.sol";
import {MappingAllocator} from "./lib/MappingAllocator.sol";
import {IMatchmaker} from "./matchmaker/IMatchmaker.sol";

contract Engine is IEngine, MappingAllocator {

    bytes32 public transient battleKeyForWrite; // intended to be used during call stack by other contracts
    bytes32 private transient storageKeyForWrite; // cached storage key to avoid repeated lookups
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
    event EngineEvent(
        bytes32 indexed battleKey, bytes32 eventType, bytes eventData, address source, uint256 step
    );

    function updateMatchmakers(address[] memory makersToAdd, address[] memory makersToRemove) external {
        for (uint256 i; i < makersToAdd.length; ++i) {
            isMatchmakerFor[msg.sender][makersToAdd[i]] = true;
        }
        for (uint256 i; i < makersToRemove.length; ++i) {
            isMatchmakerFor[msg.sender][makersToRemove[i]] = false;
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
        for (uint256 j = 0; j < prevP0Size; j++) {
            MonState storage monState = config.p0States[j];
            assembly {
                let slot := monState.slot
                if sload(slot) {
                    sstore(slot, PACKED_CLEARED_MON_STATE)
                }
            }
        }
        for (uint256 j = 0; j < prevP1Size; j++) {
            MonState storage monState = config.p1States[j];
            assembly {
                let slot := monState.slot
                if sload(slot) {
                    sstore(slot, PACKED_CLEARED_MON_STATE)
                }
            }
        }

        // Store the battle config (update fields individually to preserve effects mapping slots)
        if (config.validator != battle.validator) {
            config.validator = battle.validator;
        }
        if (config.rngOracle != battle.rngOracle) {
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
        // activeMonIndex always uses 4-bit-per-slot packing (unified for singles and doubles):
        // Bits 0-3: p0 slot 0, Bits 4-7: p0 slot 1, Bits 8-11: p1 slot 0, Bits 12-15: p1 slot 1
        // For doubles: all 4 slots are active (p0s0=0, p0s1=1, p1s0=0, p1s1=1)
        // For singles: only slot 0 is used for each player, slot 1 stays 0
        uint16 initialActiveMonIndex = battle.gameMode == GameMode.Doubles
            ? uint16(0) | (uint16(1) << 4) | (uint16(0) << 8) | (uint16(1) << 12) // p0s0=0, p0s1=1, p1s0=0, p1s1=1
            : uint16(0); // Singles: p0s0=0, p1s0=0 (slot 1 unused)

        // Pack game mode into slotSwitchFlagsAndGameMode (bit 4 = game mode)
        uint8 slotSwitchFlagsAndGameMode = battle.gameMode == GameMode.Doubles ? GAME_MODE_BIT : 0;

        battleData[battleKey] = BattleData({
            p0: battle.p0,
            p1: battle.p1,
            winnerIndex: 2, // Initialize to 2 (uninitialized/no winner)
            prevPlayerSwitchForTurnFlag: 0,
            playerSwitchForTurnFlag: 2, // Set flag to be 2 which means both players act
            activeMonIndex: initialActiveMonIndex,
            turnId: 0,
            slotSwitchFlagsAndGameMode: slotSwitchFlagsAndGameMode
        });

        // Set the team for p0 and p1 in the reusable config storage
        (Mon[] memory p0Team, Mon[] memory p1Team) = battle.teamRegistry.getTeams(
            battle.p0, battle.p0TeamIndex,
            battle.p1, battle.p1TeamIndex
        );

        // Store actual team sizes (packed: lower 4 bits = p0, upper 4 bits = p1)
        uint256 p0Len = p0Team.length;
        uint256 p1Len = p1Team.length;
        config.teamSizes = uint8(p0Len) | (uint8(p1Len) << 4);

        // Store teams in mappings
        for (uint256 j = 0; j < p0Len; j++) {
            config.p0Team[j] = p0Team[j];
        }
        for (uint256 j = 0; j < p1Len; j++) {
            config.p1Team[j] = p1Team[j];
        }

        // Set the global effects and data to start the game if any
        if (address(battle.ruleset) != address(0)) {
            (IEffect[] memory effects, bytes32[] memory data) = battle.ruleset.getInitialGlobalEffects();
            uint256 numEffects = effects.length;
            if (numEffects > 0) {
                for (uint i = 0; i < numEffects; ++i) {
                    config.globalEffects[i].effect = effects[i];
                    config.globalEffects[i].data = data[i];
                }
                config.globalEffectsLength = uint8(effects.length);
            }
        } else {
            config.globalEffectsLength = 0;
        }

        // Set the engine hooks to start the game if any
        uint256 numHooks = battle.engineHooks.length;
        if (numHooks > 0) {
            for (uint i; i < numHooks; ++i) {
                config.engineHooks[i] = battle.engineHooks[i];
            }
            config.engineHooksLength = uint8(numHooks);
        }
        else {
            config.engineHooksLength = 0;
        }

        // Set start timestamp
        config.startTimestamp = uint48(block.timestamp);

        // Build teams array for validation
        Mon[][] memory teams = new Mon[][](2);
        teams[0] = p0Team;
        teams[1] = p1Team;

        // Validate the battle config
        if (!battle.validator
                .validateGameStart(battle.p0, battle.p1, teams, battle.teamRegistry, battle.p0TeamIndex, battle.p1TeamIndex))
        {
            revert InvalidBattleConfig();
        }

        for (uint256 i = 0; i < battle.engineHooks.length; ++i) {
            battle.engineHooks[i].onBattleStart(battleKey);
        }

        emit BattleStart(battleKey, battle.p0, battle.p1);
    }

    // THE IMPORTANT FUNCTION
    function execute(bytes32 battleKey) external {
        // Cache storage key in transient storage for the duration of the call
        bytes32 storageKey = _getStorageKey(battleKey);
        storageKeyForWrite = storageKey;

        // Load storage vars
        BattleData storage battle = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        // Check for game over
        if (battle.winnerIndex != 2) {
            revert GameAlreadyOver();
        }

        // Check that at least one move has been set (isRealTurn is stored in bit 7 of packedMoveIndex)
        if ((config.p0Move.packedMoveIndex & IS_REAL_TURN_BIT) == 0 && (config.p1Move.packedMoveIndex & IS_REAL_TURN_BIT) == 0) {
            revert MovesNotSet();
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

        uint256 numHooks = config.engineHooksLength;
        for (uint256 i = 0; i < numHooks; ++i) {
            config.engineHooks[i].onRoundStart(battleKey);
        }

        // Branch for doubles mode
        if (_isDoublesMode(battle)) {
            _executeDoubles(battleKey, config, battle, turnId, numHooks);
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
            uint256 otherPlayerIndex;
            if (priorityPlayerIndex == 0) {
                otherPlayerIndex = 1;
            }

            // Run beginning of round effects
            playerSwitchForTurnFlag = _handleEffects(
                battleKey, config, battle, rng, 2, 2, EffectStep.RoundStart, EffectRunCondition.SkipIfGameOver, playerSwitchForTurnFlag
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
            playerSwitchForTurnFlag = _handleMove(battleKey, config, battle, priorityPlayerIndex, playerSwitchForTurnFlag);

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
                uint256 priorityMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, priorityPlayerIndex, 0);
                Mon memory priorityMon = _getTeamMon(config, priorityPlayerIndex, priorityMonIndex);
                if (address(priorityMon.ability) != address(0)) {
                    priorityMon.ability.activateOnSwitch(battleKey, priorityPlayerIndex, priorityMonIndex);
                }
                uint256 otherMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, otherPlayerIndex, 0);
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
                battleKey, config, battle, rng, 2, 2, EffectStep.RoundEnd, EffectRunCondition.SkipIfGameOver, playerSwitchForTurnFlag
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
        for (uint256 i = 0; i < numHooks; ++i) {
            config.engineHooks[i].onRoundEnd(battleKey);
        }

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
        battle.turnId += 1;
        battle.playerSwitchForTurnFlag = uint8(playerSwitchForTurnFlag);
        config.p0Move.packedMoveIndex = 0;
        config.p1Move.packedMoveIndex = 0;

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
        for (uint256 i; i < 2; ++i) {
            address potentialLoser = config.validator.validateTimeout(battleKey, i);
            if (potentialLoser != address(0)) {
                address winner = potentialLoser == data.p0 ? data.p1 : data.p0;
                data.winnerIndex = (winner == data.p0) ? 0 : 1;
                _handleGameOver(battleKey, winner);
                return;
            }
        }
        // Allow forcible end of battle after max duration
        if (block.timestamp - config.startTimestamp > MAX_BATTLE_DURATION) {
            _handleGameOver(battleKey, data.p0);
            return;
        }
    }

    function _handleGameOver(bytes32 battleKey, address winner) internal {
        bytes32 storageKey = storageKeyForWrite;
        BattleConfig storage config = battleConfig[storageKey];

        if (block.timestamp == config.startTimestamp) {
            revert GameStartsAndEndsSameBlock();
        }

        for (uint256 i = 0; i < config.engineHooksLength; ++i) {
            config.engineHooks[i].onBattleEnd(battleKey);
        }

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
            monState.hpDelta = (monState.hpDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.hpDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.Stamina) {
            monState.staminaDelta = (monState.staminaDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.staminaDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.Speed) {
            monState.speedDelta = (monState.speedDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.speedDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.Attack) {
            monState.attackDelta = (monState.attackDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.attackDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.Defense) {
            monState.defenceDelta = (monState.defenceDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.defenceDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.SpecialAttack) {
            monState.specialAttackDelta = (monState.specialAttackDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.specialAttackDelta + valueToAdd;
        } else if (stateVarIndex == MonStateIndexName.SpecialDefense) {
            monState.specialDefenceDelta = (monState.specialDefenceDelta == CLEARED_MON_STATE_SENTINEL) ? valueToAdd : monState.specialDefenceDelta + valueToAdd;
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
        if (effect.shouldApply(extraData, targetIndex, monIndex)) {
            bytes32 extraDataToUse = extraData;
            bool removeAfterRun = false;

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

            // Check if we have to run an onApply state update
            if (effect.shouldRunAtStep(EffectStep.OnApply)) {
                // If so, we run the effect first, and get updated extraData if necessary
                (extraDataToUse, removeAfterRun) = effect.onApply(tempRNG, extraData, targetIndex, monIndex);
            }
            if (!removeAfterRun) {
                // Add to the appropriate effects mapping based on targetIndex
                BattleConfig storage config = battleConfig[storageKeyForWrite];

                if (targetIndex == 2) {
                    // Global effects use simple sequential indexing
                    uint256 effectIndex = config.globalEffectsLength;
                    EffectInstance storage effectSlot = config.globalEffects[effectIndex];
                    effectSlot.effect = effect;
                    effectSlot.data = extraDataToUse;
                    config.globalEffectsLength = uint8(effectIndex + 1);
                } else if (targetIndex == 0) {
                    // Player effects use per-mon indexing: slot = MAX_EFFECTS_PER_MON * monIndex + count[monIndex]
                    uint256 monEffectCount = _getMonEffectCount(config.packedP0EffectsCount, monIndex);
                    uint256 slotIndex = _getEffectSlotIndex(monIndex, monEffectCount);
                    EffectInstance storage effectSlot = config.p0Effects[slotIndex];
                    effectSlot.effect = effect;
                    effectSlot.data = extraDataToUse;
                    config.packedP0EffectsCount = _setMonEffectCount(config.packedP0EffectsCount, monIndex, monEffectCount + 1);
                } else {
                    uint256 monEffectCount = _getMonEffectCount(config.packedP1EffectsCount, monIndex);
                    uint256 slotIndex = _getEffectSlotIndex(monIndex, monEffectCount);
                    EffectInstance storage effectSlot = config.p1Effects[slotIndex];
                    effectSlot.effect = effect;
                    effectSlot.data = extraDataToUse;
                    config.packedP1EffectsCount = _setMonEffectCount(config.packedP1EffectsCount, monIndex, monEffectCount + 1);
                }
            }
        }
    }

    function editEffect(uint256 targetIndex, uint256 monIndex, uint256 effectIndex, bytes32 newExtraData)
        external
    {
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
        bytes32 data = effectToRemove.data;

        // Skip if already tombstoned
        if (address(effect) == TOMBSTONE_ADDRESS) {
            return;
        }

        if (effect.shouldRunAtStep(EffectStep.OnRemove)) {
            effect.onRemove(data, 2, monIndex);
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
        bytes32 data = effectToRemove.data;

        // Skip if already tombstoned
        if (address(effect) == TOMBSTONE_ADDRESS) {
            return;
        }

        if (effect.shouldRunAtStep(EffectStep.OnRemove)) {
            effect.onRemove(data, targetIndex, monIndex);
        }

        // Tombstone the effect (indices are stable, no need to re-find)
        effectToRemove.effect = IEffect(TOMBSTONE_ADDRESS);

        emit EffectRemove(battleKey, targetIndex, monIndex, address(effect), _getUpstreamCallerAndResetValue(), currentStep);
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
        if (config.validator.validateSwitch(battleKey, playerIndex, monToSwitchIndex))
        {
            // Only call the internal switch function if the switch is valid
            _handleSwitchForSlot(battleKey, playerIndex, 0, monToSwitchIndex, msg.sender);

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

    /// @notice Force switch a mon in a specific slot (for doubles mode)
    /// @dev Used by moves that force switches (e.g., Roar, Whirlwind) in doubles battles
    /// @param playerIndex The player whose mon will be switched (0 or 1)
    /// @param slotIndex The slot to switch (0 or 1)
    /// @param monToSwitchIndex The index of the mon to switch to
    function switchActiveMonForSlot(uint256 playerIndex, uint256 slotIndex, uint256 monToSwitchIndex) external {
        bytes32 battleKey = battleKeyForWrite;
        if (battleKey == bytes32(0)) {
            revert NoWriteAllowed();
        }

        BattleConfig storage config = battleConfig[storageKeyForWrite];
        BattleData storage battle = battleData[battleKey];

        // Use the validator to check if the switch is valid
        if (config.validator.validateSwitch(battleKey, playerIndex, monToSwitchIndex))
        {
            // Use the slot-aware switch handler for doubles
            _handleSwitchForSlot(battleKey, playerIndex, slotIndex, monToSwitchIndex, msg.sender);

            // Check for game over using doubles logic
            bool isGameOver = _checkForGameOverOrKO_Doubles(config, battle);
            if (isGameOver) return;

            // Determine player switch flag based on slot switch flags
            uint8 slotFlags = battle.slotSwitchFlagsAndGameMode & SWITCH_FLAGS_MASK;
            bool p0NeedsSwitch = (slotFlags & 0x03) != 0; // bits 0-1 for P0
            bool p1NeedsSwitch = (slotFlags & 0x0C) != 0; // bits 2-3 for P1
            if (p0NeedsSwitch && p1NeedsSwitch) {
                battle.playerSwitchForTurnFlag = 2;
            } else if (p0NeedsSwitch) {
                battle.playerSwitchForTurnFlag = 0;
            } else if (p1NeedsSwitch) {
                battle.playerSwitchForTurnFlag = 1;
            } else {
                battle.playerSwitchForTurnFlag = 2;
            }
        }
        // If the switch is invalid, we simply do nothing and continue execution
    }

    function setMove(bytes32 battleKey, uint256 playerIndex, uint8 moveIndex, bytes32 salt, uint240 extraData)
        external
    {
        // Use cached key if called during execute(), otherwise lookup
        bool isForCurrentBattle = battleKeyForWrite == battleKey;
        bytes32 storageKey = isForCurrentBattle ? storageKeyForWrite : _getStorageKey(battleKey);

        // Cache storage pointer to avoid repeated mapping lookups
        BattleConfig storage config = battleConfig[storageKey];

        bool isMoveManager = msg.sender == address(config.moveManager);
        if (!isMoveManager && !isForCurrentBattle) {
            revert NoWriteAllowed();
        }

        // Pack moveIndex with isRealTurn bit and apply +1 offset for regular moves
        // Regular moves (< SWITCH_MOVE_INDEX) are stored as moveIndex + 1 to avoid zero ambiguity
        uint8 storedMoveIndex = moveIndex < SWITCH_MOVE_INDEX ? moveIndex + MOVE_INDEX_OFFSET : moveIndex;
        uint8 packedMoveIndex = storedMoveIndex | IS_REAL_TURN_BIT;

        MoveDecision memory newMove = MoveDecision({packedMoveIndex: packedMoveIndex, extraData: extraData});

        // playerIndex 0-1: slot 0 moves, playerIndex 2-3: slot 1 moves (for doubles)
        if (playerIndex == 0) {
            config.p0Move = newMove;
            config.p0Salt = salt;
        } else if (playerIndex == 1) {
            config.p1Move = newMove;
            config.p1Salt = salt;
        } else if (playerIndex == 2) {
            // p0 slot 1 move (doubles)
            config.p0Move2 = newMove;
        } else if (playerIndex == 3) {
            // p1 slot 1 move (doubles)
            config.p1Move2 = newMove;
        }
    }

    /**
     * @notice Set a move for a specific slot in doubles battles
     * @param battleKey The battle identifier
     * @param playerIndex 0 or 1
     * @param slotIndex 0 or 1
     * @param moveIndex The move index
     * @param salt Salt for RNG
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
        // Use cached key if called during execute(), otherwise lookup
        bool isForCurrentBattle = battleKeyForWrite == battleKey;
        bytes32 storageKey = isForCurrentBattle ? storageKeyForWrite : _getStorageKey(battleKey);

        BattleConfig storage config = battleConfig[storageKey];

        bool isMoveManager = msg.sender == address(config.moveManager);
        if (!isMoveManager && !isForCurrentBattle) {
            revert NoWriteAllowed();
        }

        // Pack moveIndex with isRealTurn bit and apply +1 offset for regular moves
        uint8 storedMoveIndex = moveIndex < SWITCH_MOVE_INDEX ? moveIndex + MOVE_INDEX_OFFSET : moveIndex;
        uint8 packedMoveIndex = storedMoveIndex | IS_REAL_TURN_BIT;

        MoveDecision memory newMove = MoveDecision({packedMoveIndex: packedMoveIndex, extraData: extraData});

        if (playerIndex == 0) {
            if (slotIndex == 0) {
                config.p0Move = newMove;
                config.p0Salt = salt;
            } else {
                config.p0Move2 = newMove;
            }
        } else {
            if (slotIndex == 0) {
                config.p1Move = newMove;
                config.p1Salt = salt;
            } else {
                config.p1Move2 = newMove;
            }
        }
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

    // Shared game over check - returns winner index (0, 1, or 2 if no winner)
    function _checkForGameOver(BattleConfig storage config, BattleData storage battle)
        internal
        view
        returns (uint256 winnerIndex, uint256 p0KOBitmap, uint256 p1KOBitmap)
    {
        // First check if we already calculated a winner
        if (battle.winnerIndex != 2) {
            return (battle.winnerIndex, 0, 0);
        }

        // Load KO bitmaps and team sizes
        uint256 p0TeamSize = config.teamSizes & 0x0F;
        uint256 p1TeamSize = config.teamSizes >> 4;
        p0KOBitmap = _getKOBitmap(config, 0);
        p1KOBitmap = _getKOBitmap(config, 1);

        // Full team mask: (1 << teamSize) - 1, e.g. teamSize=3 -> 0b111
        uint256 p0FullMask = (1 << p0TeamSize) - 1;
        uint256 p1FullMask = (1 << p1TeamSize) - 1;

        // Check if all mons are KO'd for either player
        if (p0KOBitmap == p0FullMask) {
            winnerIndex = 1; // p1 wins
        } else if (p1KOBitmap == p1FullMask) {
            winnerIndex = 0; // p0 wins
        } else {
            winnerIndex = 2; // No winner yet
        }
    }

    function _checkForGameOverOrKO(
        BattleConfig storage config,
        BattleData storage battle,
        uint256 priorityPlayerIndex
    ) internal returns (uint256 playerSwitchForTurnFlag, bool isGameOver) {
        uint256 otherPlayerIndex = (priorityPlayerIndex + 1) % 2;

        // Use shared game over check
        (uint256 winnerIndex, uint256 p0KOBitmap, uint256 p1KOBitmap) = _checkForGameOver(config, battle);

        if (winnerIndex != 2) {
            battle.winnerIndex = uint8(winnerIndex);
            return (playerSwitchForTurnFlag, true);
        }

        // No game over - check for KOs and set player switch for turn flag
        playerSwitchForTurnFlag = 2;

        // Use already-loaded KO bitmaps to check active mon KO status (slot 0 for singles)
        uint256 priorityActiveMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, priorityPlayerIndex, 0);
        uint256 otherActiveMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, otherPlayerIndex, 0);
        uint256 priorityKOBitmap = priorityPlayerIndex == 0 ? p0KOBitmap : p1KOBitmap;
        uint256 otherKOBitmap = priorityPlayerIndex == 0 ? p1KOBitmap : p0KOBitmap;
        bool isPriorityPlayerActiveMonKnockedOut = (priorityKOBitmap & (1 << priorityActiveMonIndex)) != 0;
        bool isNonPriorityPlayerActiveMonKnockedOut = (otherKOBitmap & (1 << otherActiveMonIndex)) != 0;

        // If the priority player mon is KO'ed (and the other player isn't), next turn only other player acts
        if (isPriorityPlayerActiveMonKnockedOut && !isNonPriorityPlayerActiveMonKnockedOut) {
            playerSwitchForTurnFlag = priorityPlayerIndex;
        }

        // If the non priority player mon is KO'ed (and the other player isn't), next turn only priority player acts
        if (!isPriorityPlayerActiveMonKnockedOut && isNonPriorityPlayerActiveMonKnockedOut) {
            playerSwitchForTurnFlag = otherPlayerIndex;
        }
    }

    // Core switch logic shared between singles and doubles
    function _handleSwitchCore(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 currentActiveMonIndex,
        uint256 monToSwitchIndex,
        address source
    ) internal {
        BattleData storage battle = battleData[battleKey];
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

        // Run onMonSwitchIn hooks (these run after the index is updated by the caller)
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

        // Run ability for the newly switched in mon
        Mon memory mon = _getTeamMon(config, playerIndex, monToSwitchIndex);
        if (
            address(mon.ability) != address(0) && battle.turnId != 0
                && !_getMonState(config, playerIndex, monToSwitchIndex).isKnockedOut
        ) {
            mon.ability.activateOnSwitch(battleKey, playerIndex, monToSwitchIndex);
        }
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

        // Unpack moveIndex from packedMoveIndex (lower 7 bits, with +1 offset for regular moves)
        uint8 storedMoveIndex = move.packedMoveIndex & MOVE_INDEX_MASK;
        uint8 moveIndex = storedMoveIndex >= SWITCH_MOVE_INDEX ? storedMoveIndex : storedMoveIndex - MOVE_INDEX_OFFSET;

        // Handle shouldSkipTurn flag first and toggle it off if set (slot 0 for singles)
        uint256 activeMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, 0);
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
            _handleSwitchForSlot(battleKey, playerIndex, 0, uint256(move.extraData), address(0));
        } else if (moveIndex == NO_OP_MOVE_INDEX) {
            // Emit event and do nothing (e.g. just recover stamina)
            emit MonMove(battleKey, playerIndex, activeMonIndex, moveIndex, move.extraData, staminaCost);
        }
        // Execute the move and then set updated state, active mons, and effects/data
        else {
            // Call validateSpecificMoveSelection again from the validator to ensure that it is still valid to execute
            // If not, then we just return early
            // Handles cases where e.g. some condition outside of the player's control leads to an invalid move
            // Singles always uses slot 0
            if (!config.validator.validateSpecificMoveSelection(battleKey, moveIndex, playerIndex, 0, move.extraData))
            {
                return playerSwitchForTurnFlag;
            }

            IMoveSet moveSet = _getTeamMon(config, playerIndex, activeMonIndex).moves[moveIndex];

            // Update the mon state directly to account for the stamina cost of the move
            staminaCost = int32(moveSet.stamina(battleKey, playerIndex, activeMonIndex));
            MonState storage monState = _getMonState(config, playerIndex, activeMonIndex);
            monState.staminaDelta =
                (monState.staminaDelta == CLEARED_MON_STATE_SENTINEL) ? -staminaCost : monState.staminaDelta - staminaCost;

            // Emit event and then run the move
            emit MonMove(battleKey, playerIndex, activeMonIndex, moveIndex, move.extraData, staminaCost);

            // Run the move (no longer checking for a return value)
            moveSet.move(battleKey, playerIndex, move.extraData, tempRNG);
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

        uint256 monIndex;
        // Use explicit monIndex if provided, otherwise calculate from active mon (slot 0 for singles)
        if (explicitMonIndex != type(uint256).max) {
            monIndex = explicitMonIndex;
        } else if (playerIndex != 2) {
            // Specific player - get their active mon (this takes priority over effectIndex)
            monIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, 0);
        } else if (effectIndex == 2) {
            // Global effects with global playerIndex - monIndex doesn't matter for filtering
            monIndex = 0;
        } else {
            // effectIndex is player-specific but playerIndex is global - use effectIndex
            monIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, effectIndex, 0);
        }

        // Iterate directly over storage, skipping tombstones
        // With tombstones, indices are stable so no snapshot needed
        uint256 baseSlot = (effectIndex != 2) ? _getEffectSlotIndex(monIndex, 0) : 0;

        // Use a loop index that reads current length each iteration (allows processing newly added effects)
        uint256 i = 0;
        while (true) {
            // Get current length (may grow if effects add new effects)
            uint256 effectsCount;
            if (effectIndex == 2) {
                effectsCount = config.globalEffectsLength;
            } else if (effectIndex == 0) {
                effectsCount = _getMonEffectCount(config.packedP0EffectsCount, monIndex);
            } else {
                effectsCount = _getMonEffectCount(config.packedP1EffectsCount, monIndex);
            }

            if (i >= effectsCount) break;

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
                    config, rng, effectIndex, playerIndex, monIndex, round, extraEffectsData,
                    eff.effect, eff.data, uint96(slotIndex)
                );
            }

            ++i;
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
        bytes32 data,
        uint96 slotIndex
    ) private {
        if (!effect.shouldRunAtStep(round)) {
            return;
        }

        currentStep = uint256(round);

        // Emit event first, then handle side effects (use transient battleKeyForWrite)
        emit EffectRun(
            battleKeyForWrite, effectIndex, monIndex, address(effect), data, _getUpstreamCallerAndResetValue(), currentStep
        );

        // Run the effect and get result
        (bytes32 updatedExtraData, bool removeAfterRun) = _executeEffectHook(
            effect, rng, data, playerIndex, monIndex, round, extraEffectsData
        );

        // If we need to remove or update the effect
        if (removeAfterRun || updatedExtraData != data) {
            _updateOrRemoveEffect(config, effectIndex, monIndex, effect, data, slotIndex, updatedExtraData, removeAfterRun);
        }
    }

    function _executeEffectHook(
        IEffect effect,
        uint256 rng,
        bytes32 data,
        uint256 playerIndex,
        uint256 monIndex,
        EffectStep round,
        bytes memory extraEffectsData
    ) private returns (bytes32 updatedExtraData, bool removeAfterRun) {
        if (round == EffectStep.RoundStart) {
            return effect.onRoundStart(rng, data, playerIndex, monIndex);
        } else if (round == EffectStep.RoundEnd) {
            return effect.onRoundEnd(rng, data, playerIndex, monIndex);
        } else if (round == EffectStep.OnMonSwitchIn) {
            return effect.onMonSwitchIn(rng, data, playerIndex, monIndex);
        } else if (round == EffectStep.OnMonSwitchOut) {
            return effect.onMonSwitchOut(rng, data, playerIndex, monIndex);
        } else if (round == EffectStep.AfterDamage) {
            return effect.onAfterDamage(rng, data, playerIndex, monIndex, abi.decode(extraEffectsData, (int32)));
        } else if (round == EffectStep.AfterMove) {
            return effect.onAfterMove(rng, data, playerIndex, monIndex);
        } else if (round == EffectStep.OnUpdateMonState) {
            (uint256 statePlayerIndex, uint256 stateMonIndex, MonStateIndexName stateVarIndex, int32 valueToAdd) =
                abi.decode(extraEffectsData, (uint256, uint256, MonStateIndexName, int32));
            return effect.onUpdateMonState(rng, data, statePlayerIndex, stateMonIndex, stateVarIndex, valueToAdd);
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
        // If non-global effect, check if we should still run if mon is KOed (slot 0 for singles)
        if (effectIndex != 2) {
            bool isMonKOed =
                _getMonState(config, playerIndex, _unpackActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, 0)).isKnockedOut;
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
        BattleConfig storage config = battleConfig[_getStorageKey(battleKey)];
        BattleData storage battle = battleData[battleKey];

        // Unpack move indices from packed format
        uint8 p0StoredIndex = config.p0Move.packedMoveIndex & MOVE_INDEX_MASK;
        uint8 p1StoredIndex = config.p1Move.packedMoveIndex & MOVE_INDEX_MASK;
        uint8 p0MoveIndex = p0StoredIndex >= SWITCH_MOVE_INDEX ? p0StoredIndex : p0StoredIndex - MOVE_INDEX_OFFSET;
        uint8 p1MoveIndex = p1StoredIndex >= SWITCH_MOVE_INDEX ? p1StoredIndex : p1StoredIndex - MOVE_INDEX_OFFSET;

        uint256 p0ActiveMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, 0, 0);
        uint256 p1ActiveMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, 1, 0);
        uint256 p0Priority;
        uint256 p1Priority;

        // Call the move for its priority, unless it's the switch or no op move index
        {
            if (p0MoveIndex == SWITCH_MOVE_INDEX || p0MoveIndex == NO_OP_MOVE_INDEX) {
                p0Priority = SWITCH_PRIORITY;
            } else {
                IMoveSet p0MoveSet = _getTeamMon(config, 0, p0ActiveMonIndex).moves[p0MoveIndex];
                p0Priority = p0MoveSet.priority(battleKey, 0);
            }

            if (p1MoveIndex == SWITCH_MOVE_INDEX || p1MoveIndex == NO_OP_MOVE_INDEX) {
                p1Priority = SWITCH_PRIORITY;
            } else {
                IMoveSet p1MoveSet = _getTeamMon(config, 1, p1ActiveMonIndex).moves[p1MoveIndex];
                p1Priority = p1MoveSet.priority(battleKey, 1);
            }
        }

        // Determine priority based on (in descending order of importance):
        // - the higher priority tier
        // - within same priority, the higher speed
        // - if both are tied, use the rng value
        if (p0Priority > p1Priority) {
            return 0;
        } else if (p0Priority < p1Priority) {
            return 1;
        } else {
            // Calculate speeds by combining base stats with deltas
            // Note: speedDelta may be sentinel value (CLEARED_MON_STATE_SENTINEL) which should be treated as 0
            int32 p0SpeedDelta = _getMonState(config, 0, p0ActiveMonIndex).speedDelta;
            int32 p1SpeedDelta = _getMonState(config, 1, p1ActiveMonIndex).speedDelta;
            uint32 p0MonSpeed = uint32(
                int32(_getTeamMon(config, 0, p0ActiveMonIndex).stats.speed) + (p0SpeedDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : p0SpeedDelta)
            );
            uint32 p1MonSpeed = uint32(
                int32(_getTeamMon(config, 1, p1ActiveMonIndex).stats.speed) + (p1SpeedDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : p1SpeedDelta)
            );
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
    function _getTeamMon(BattleConfig storage config, uint256 playerIndex, uint256 monIndex) private view returns (Mon storage) {
        return playerIndex == 0 ? config.p0Team[monIndex] : config.p1Team[monIndex];
    }

    function _getMonState(BattleConfig storage config, uint256 playerIndex, uint256 monIndex) private view returns (MonState storage) {
        return playerIndex == 0 ? config.p0States[monIndex] : config.p1States[monIndex];
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
            for (uint256 i = 0; i < globalEffectsLength; ++i) {
                if (address(config.globalEffects[i].effect) != TOMBSTONE_ADDRESS) {
                    globalResult[globalIdx] = config.globalEffects[i];
                    globalIndices[globalIdx] = i;
                    globalIdx++;
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
        for (uint256 i = 0; i < monEffectCount; ++i) {
            uint256 slotIndex = baseSlot + i;
            if (address(effects[slotIndex].effect) != TOMBSTONE_ADDRESS) {
                result[idx] = effects[slotIndex];
                indices[idx] = slotIndex;
                idx++;
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
        for (uint256 i = 0; i < globalLen; ++i) {
            if (address(config.globalEffects[i].effect) != TOMBSTONE_ADDRESS) {
                globalEffects[gIdx] = config.globalEffects[i];
                gIdx++;
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

        EffectInstance[][] memory p0Effects = _buildPlayerEffectsArray(config.p0Effects, config.packedP0EffectsCount, p0TeamSize);
        EffectInstance[][] memory p1Effects = _buildPlayerEffectsArray(config.p1Effects, config.packedP1EffectsCount, p1TeamSize);

        // Build teams array from mappings
        Mon[][] memory teams = new Mon[][](2);
        teams[0] = new Mon[](p0TeamSize);
        teams[1] = new Mon[](p1TeamSize);
        for (uint256 i = 0; i < p0TeamSize; i++) {
            teams[0][i] = config.p0Team[i];
        }
        for (uint256 i = 0; i < p1TeamSize; i++) {
            teams[1][i] = config.p1Team[i];
        }

        // Build monStates array from mappings
        MonState[][] memory monStates = new MonState[][](2);
        monStates[0] = new MonState[](p0TeamSize);
        monStates[1] = new MonState[](p1TeamSize);
        for (uint256 i = 0; i < p0TeamSize; i++) {
            monStates[0][i] = config.p0States[i];
        }
        for (uint256 i = 0; i < p1TeamSize; i++) {
            monStates[1][i] = config.p1States[i];
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

        for (uint256 m = 0; m < teamSize; m++) {
            uint256 monCount = _getMonEffectCount(packedCounts, m);
            uint256 baseSlot = _getEffectSlotIndex(m, 0);

            // Allocate max size for this mon's effects
            EffectInstance[] memory monEffects = new EffectInstance[](monCount);
            uint256 idx = 0;
            for (uint256 i = 0; i < monCount; ++i) {
                if (address(effects[baseSlot + i].effect) != TOMBSTONE_ADDRESS) {
                    monEffects[idx] = effects[baseSlot + i];
                    idx++;
                }
            }

            // Resize array to actual count
            assembly ("memory-safe") {
                mstore(monEffects, idx)
            }
            result[m] = monEffects;
        }

        return result;
    }

    function getBattleValidator(bytes32 battleKey) external view returns (IValidator) {
        return battleConfig[_getStorageKey(battleKey)].validator;
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
        BattleData storage data = battleData[battleKey];
        uint16 packed = data.activeMonIndex;

        // Unified packing: always use slot 0 for each player (works for both singles and doubles)
        uint256[] memory result = new uint256[](2);
        result[0] = _unpackActiveMonIndexForSlot(packed, 0, 0);
        result[1] = _unpackActiveMonIndexForSlot(packed, 1, 0);
        return result;
    }

    function getGameMode(bytes32 battleKey) external view returns (GameMode) {
        uint8 slotSwitchFlagsAndGameMode = battleData[battleKey].slotSwitchFlagsAndGameMode;
        return (slotSwitchFlagsAndGameMode & GAME_MODE_BIT) != 0 ? GameMode.Doubles : GameMode.Singles;
    }

    function getActiveMonIndexForSlot(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex)
        external
        view
        returns (uint256)
    {
        BattleData storage data = battleData[battleKey];
        // Unified packing: 4 bits per slot for both singles and doubles
        // For singles, slot 1 returns 0 (unused)
        return _unpackActiveMonIndexForSlot(data.activeMonIndex, playerIndex, slotIndex);
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
        uint8 winnerIndex = battleData[battleKey].winnerIndex;
        if (winnerIndex == 2) {
            return address(0);
        }
        return (winnerIndex == 0) ? battleData[battleKey].p0 : battleData[battleKey].p1;
    }

    function getStartTimestamp(bytes32 battleKey) external view returns (uint256) {
        return battleConfig[_getStorageKey(battleKey)].startTimestamp;
    }

    function getPrevPlayerSwitchForTurnFlagForBattleState(bytes32 battleKey) external view returns (uint256) {
        return battleData[battleKey].prevPlayerSwitchForTurnFlag;
    }

    function getMoveManager(bytes32 battleKey) external view returns (address) {
        return battleConfig[_getStorageKey(battleKey)].moveManager;
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

        // Extract game mode and active mon indices (unified 4-bit packing for both modes)
        uint8 slotSwitchFlagsAndGameMode = data.slotSwitchFlagsAndGameMode;
        ctx.gameMode = (slotSwitchFlagsAndGameMode & GAME_MODE_BIT) != 0 ? GameMode.Doubles : GameMode.Singles;
        ctx.slotSwitchFlags = slotSwitchFlagsAndGameMode & SWITCH_FLAGS_MASK;

        // Unified packing: 4 bits per slot (for singles, slot 1 values are 0/unused)
        ctx.p0ActiveMonIndex0 = uint8(data.activeMonIndex & ACTIVE_MON_INDEX_MASK);
        ctx.p0ActiveMonIndex1 = uint8((data.activeMonIndex >> 4) & ACTIVE_MON_INDEX_MASK);
        ctx.p1ActiveMonIndex0 = uint8((data.activeMonIndex >> 8) & ACTIVE_MON_INDEX_MASK);
        ctx.p1ActiveMonIndex1 = uint8((data.activeMonIndex >> 12) & ACTIVE_MON_INDEX_MASK);

        ctx.validator = address(config.validator);
        ctx.moveManager = config.moveManager;
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

        // Extract game mode and slot switch flags
        uint8 slotSwitchFlagsAndGameMode = data.slotSwitchFlagsAndGameMode;
        ctx.gameMode = (slotSwitchFlagsAndGameMode & GAME_MODE_BIT) != 0 ? GameMode.Doubles : GameMode.Singles;
        ctx.slotSwitchFlags = slotSwitchFlagsAndGameMode & SWITCH_FLAGS_MASK;

        ctx.validator = address(config.validator);
    }

    function getDamageCalcContext(bytes32 battleKey, uint256 attackerPlayerIndex, uint256 defenderPlayerIndex)
        external
        view
        returns (DamageCalcContext memory ctx)
    {
        bytes32 storageKey = _getStorageKey(battleKey);
        BattleData storage data = battleData[battleKey];
        BattleConfig storage config = battleConfig[storageKey];

        // Get active mon indices (unified packing, use slot 0)
        uint256 attackerMonIndex = _unpackActiveMonIndexForSlot(data.activeMonIndex, attackerPlayerIndex, 0);
        uint256 defenderMonIndex = _unpackActiveMonIndexForSlot(data.activeMonIndex, defenderPlayerIndex, 0);

        ctx.attackerMonIndex = uint8(attackerMonIndex);
        ctx.defenderMonIndex = uint8(defenderMonIndex);

        // Get attacker stats
        Mon storage attackerMon = _getTeamMon(config, attackerPlayerIndex, attackerMonIndex);
        MonState storage attackerState = _getMonState(config, attackerPlayerIndex, attackerMonIndex);
        ctx.attackerAttack = attackerMon.stats.attack;
        ctx.attackerAttackDelta = attackerState.attackDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : attackerState.attackDelta;
        ctx.attackerSpAtk = attackerMon.stats.specialAttack;
        ctx.attackerSpAtkDelta = attackerState.specialAttackDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : attackerState.specialAttackDelta;

        // Get defender stats and types
        Mon storage defenderMon = _getTeamMon(config, defenderPlayerIndex, defenderMonIndex);
        MonState storage defenderState = _getMonState(config, defenderPlayerIndex, defenderMonIndex);
        ctx.defenderDef = defenderMon.stats.defense;
        ctx.defenderDefDelta = defenderState.defenceDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : defenderState.defenceDelta;
        ctx.defenderSpDef = defenderMon.stats.specialDefense;
        ctx.defenderSpDefDelta = defenderState.specialDefenceDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : defenderState.specialDefenceDelta;
        ctx.defenderType1 = defenderMon.stats.type1;
        ctx.defenderType2 = defenderMon.stats.type2;
    }

    /**
     * - Doubles helper functions
     */

    // Unpack active mon index for a specific slot in doubles mode
    // Doubles packing: bits 0-3 = p0s0, 4-7 = p0s1, 8-11 = p1s0, 12-15 = p1s1
    function _unpackActiveMonIndexForSlot(uint16 packed, uint256 playerIndex, uint256 slotIndex) internal pure returns (uint256) {
        uint256 shift = (playerIndex * 2 + slotIndex) * ACTIVE_MON_INDEX_BITS;
        return (packed >> shift) & ACTIVE_MON_INDEX_MASK;
    }

    // Set active mon index for a specific slot in doubles mode
    function _setActiveMonIndexForSlot(uint16 packed, uint256 playerIndex, uint256 slotIndex, uint256 monIndex) internal pure returns (uint16) {
        uint256 shift = (playerIndex * 2 + slotIndex) * ACTIVE_MON_INDEX_BITS;
        uint16 mask = uint16(uint256(ACTIVE_MON_INDEX_MASK) << shift);
        return (packed & ~mask) | uint16((monIndex & ACTIVE_MON_INDEX_MASK) << shift);
    }

    // Get the move decision for a specific player and slot
    function _getMoveDecisionForSlot(BattleConfig storage config, uint256 playerIndex, uint256 slotIndex) internal view returns (MoveDecision memory) {
        if (playerIndex == 0) {
            return slotIndex == 0 ? config.p0Move : config.p0Move2;
        } else {
            return slotIndex == 0 ? config.p1Move : config.p1Move2;
        }
    }

    // Check if game mode is doubles
    function _isDoublesMode(BattleData storage battle) internal view returns (bool) {
        return (battle.slotSwitchFlagsAndGameMode & GAME_MODE_BIT) != 0;
    }

    // Get slot switch flags (lower 4 bits of slotSwitchFlagsAndGameMode)
    function _getSlotSwitchFlags(BattleData storage battle) internal view returns (uint8) {
        return battle.slotSwitchFlagsAndGameMode & SWITCH_FLAGS_MASK;
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

    /**
     * @dev Check if a player has any KO'd slot that has a valid switch target
     * @param config Battle config
     * @param battle Battle data
     * @param playerIndex Which player to check (0 or 1)
     * @param koBitmap Bitmap of KO'd mons for this player
     * @return needsSwitch True if player has a KO'd slot with valid switch target
     */
    function _playerNeedsSwitchTurn(
        BattleConfig storage config,
        BattleData storage battle,
        uint256 playerIndex,
        uint256 koBitmap
    ) internal view returns (bool needsSwitch) {
        uint256 teamSize = playerIndex == 0 ? (config.teamSizes & 0x0F) : (config.teamSizes >> 4);

        // Check each slot
        for (uint256 s = 0; s < 2; s++) {
            uint256 activeMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, s);
            bool isSlotKOed = (koBitmap & (1 << activeMonIndex)) != 0;

            if (isSlotKOed) {
                // This slot is KO'd - check if there's a valid switch target
                uint256 otherSlotMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, 1 - s);

                for (uint256 m = 0; m < teamSize; m++) {
                    // Skip if mon is KO'd
                    if ((koBitmap & (1 << m)) != 0) continue;
                    // Skip if mon is active in other slot
                    if (m == otherSlotMonIndex) continue;
                    // Found a valid switch target
                    return true;
                }
            }
        }
        return false;
    }

    // Struct for tracking move order in doubles
    struct MoveOrder {
        uint256 playerIndex;
        uint256 slotIndex;
        uint256 priority;
        uint256 speed;
    }

    // Compute move order for all 4 slots in doubles (sorted by priority desc, then speed desc, then position)
    // Position tiebreaker: p0s0 > p0s1 > p1s0 > p1s1 (lower position index = higher priority)
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

                // If move wasn't set (single-player turn), treat as NO_OP for ordering
                if ((move.packedMoveIndex & IS_REAL_TURN_BIT) == 0) {
                    moveOrder[idx].priority = 0; // Lowest priority - will be skipped anyway
                    moveOrder[idx].speed = 0;
                    continue;
                }

                uint8 storedMoveIndex = move.packedMoveIndex & MOVE_INDEX_MASK;
                uint8 moveIndex = storedMoveIndex >= SWITCH_MOVE_INDEX ? storedMoveIndex : storedMoveIndex - MOVE_INDEX_OFFSET;

                uint256 monIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, p, s);

                // Get priority
                if (moveIndex == SWITCH_MOVE_INDEX || moveIndex == NO_OP_MOVE_INDEX) {
                    moveOrder[idx].priority = SWITCH_PRIORITY;
                } else {
                    IMoveSet moveSet = _getTeamMon(config, p, monIndex).moves[moveIndex];
                    moveOrder[idx].priority = moveSet.priority(battleKey, p);
                }

                // Get speed
                int32 speedDelta = _getMonState(config, p, monIndex).speedDelta;
                uint32 monSpeed = uint32(
                    int32(_getTeamMon(config, p, monIndex).stats.speed) +
                    (speedDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : speedDelta)
                );
                moveOrder[idx].speed = monSpeed;
            }
        }

        // Sort by priority (desc), then speed (desc), then position (asc, implicit from initial order)
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
                    // If both priority and speed are equal, keep original order (position tiebreaker)
                }

                if (shouldSwap) {
                    MoveOrder memory temp = moveOrder[j];
                    moveOrder[j] = moveOrder[j + 1];
                    moveOrder[j + 1] = temp;
                }
            }
        }
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

        // Unpack moveIndex from packedMoveIndex
        uint8 storedMoveIndex = move.packedMoveIndex & MOVE_INDEX_MASK;
        uint8 moveIndex = storedMoveIndex >= SWITCH_MOVE_INDEX ? storedMoveIndex : storedMoveIndex - MOVE_INDEX_OFFSET;

        // Get active mon for this slot
        uint256 activeMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, slotIndex);
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
            // Check if target mon is already active in other slot (handles case where both slots try to switch to same mon)
            uint256 otherSlotIndex = 1 - slotIndex;
            uint256 otherSlotActiveMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, otherSlotIndex);
            if (targetMonIndex == otherSlotActiveMonIndex) {
                // Target mon is already active in other slot - treat as NO_OP
                emit MonMove(battleKey, playerIndex, activeMonIndex, NO_OP_MOVE_INDEX, move.extraData, staminaCost);
            } else {
                _handleSwitchForSlot(battleKey, playerIndex, slotIndex, targetMonIndex, address(0));
            }
        } else if (moveIndex == NO_OP_MOVE_INDEX) {
            emit MonMove(battleKey, playerIndex, activeMonIndex, moveIndex, move.extraData, staminaCost);
        } else {
            // Validate move is still valid (pass slotIndex for correct mon lookup in doubles)
            if (!config.validator.validateSpecificMoveSelection(battleKey, moveIndex, playerIndex, slotIndex, move.extraData)) {
                return false;
            }

            IMoveSet moveSet = _getTeamMon(config, playerIndex, activeMonIndex).moves[moveIndex];

            // Deduct stamina
            staminaCost = int32(moveSet.stamina(battleKey, playerIndex, activeMonIndex));
            MonState storage monState = _getMonState(config, playerIndex, activeMonIndex);
            monState.staminaDelta = (monState.staminaDelta == CLEARED_MON_STATE_SENTINEL) ? -staminaCost : monState.staminaDelta - staminaCost;

            emit MonMove(battleKey, playerIndex, activeMonIndex, moveIndex, move.extraData, staminaCost);

            // Execute the move
            moveSet.move(battleKey, playerIndex, move.extraData, tempRNG);
        }

        // Check if mon got KO'd as a result of this move
        return currentMonState.isKnockedOut;
    }

    // Handle switch for a specific slot in doubles (uses shared core functions)
    function _handleSwitchForSlot(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex, uint256 monToSwitchIndex, address source) internal {
        BattleData storage battle = battleData[battleKey];
        uint256 currentActiveMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, slotIndex);

        // Run switch-out effects (shared)
        _handleSwitchCore(battleKey, playerIndex, currentActiveMonIndex, monToSwitchIndex, source);

        // Update active mon for this slot (doubles packing)
        battle.activeMonIndex = _setActiveMonIndexForSlot(battle.activeMonIndex, playerIndex, slotIndex, monToSwitchIndex);

        // Run switch-in effects (shared)
        _completeSwitchIn(battleKey, playerIndex, monToSwitchIndex);
    }

    // Check for game over or KO in doubles mode (uses shared game over check)
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
                uint256 activeMonIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, p, s);
                bool isKOed = (koBitmap & (1 << activeMonIndex)) != 0;
                if (isKOed) {
                    _setSlotSwitchFlag(battle, p, s);
                }
            }
        }

        // Determine if either player needs a switch turn (has KO'd slot with valid target)
        bool p0NeedsSwitch = _playerNeedsSwitchTurn(config, battle, 0, p0KOBitmap);
        bool p1NeedsSwitch = _playerNeedsSwitchTurn(config, battle, 1, p1KOBitmap);

        // Set playerSwitchForTurnFlag based on who needs to switch
        if (p0NeedsSwitch && p1NeedsSwitch) {
            // Both players have KO'd mons with valid targets - both act (switch-only turn)
            battle.playerSwitchForTurnFlag = 2;
        } else if (p0NeedsSwitch) {
            // Only p0 needs to switch
            battle.playerSwitchForTurnFlag = 0;
        } else if (p1NeedsSwitch) {
            // Only p1 needs to switch
            battle.playerSwitchForTurnFlag = 1;
        } else {
            // Neither needs switch - normal turn (both act)
            battle.playerSwitchForTurnFlag = 2;
        }

        return false;
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
            uint256 monIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, p, s);
            if (!_getMonState(config, p, monIndex).isKnockedOut) {
                _runEffectsForMon(battleKey, rng, p, p, EffectStep.RoundStart, "", monIndex);
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

                // Run round end hooks
                for (uint256 j = 0; j < numHooks; ++j) {
                    config.engineHooks[j].onRoundEnd(battleKey);
                }

                emit EngineExecute(battleKey, turnId, 2, moveOrder[0].playerIndex);
                return;
            }
        }

        // For turn 0 only: handle ability activateOnSwitch for all 4 mons
        if (turnId == 0) {
            for (uint256 p = 0; p < 2; p++) {
                for (uint256 s = 0; s < 2; s++) {
                    uint256 monIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, p, s);
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
            uint256 monIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, p, s);
            if (!_getMonState(config, p, monIndex).isKnockedOut) {
                _runEffectsForMon(battleKey, rng, p, p, EffectStep.AfterMove, "", monIndex);
            }
        }

        // Run global afterMove effects
        _runEffects(battleKey, rng, 2, 2, EffectStep.AfterMove, "");

        // Check for game over after effects
        if (_checkForGameOverOrKO_Doubles(config, battle)) {
            address winner = (battle.winnerIndex == 0) ? battle.p0 : battle.p1;
            _handleGameOver(battleKey, winner);

            for (uint256 j = 0; j < numHooks; ++j) {
                config.engineHooks[j].onRoundEnd(battleKey);
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
            uint256 monIndex = _unpackActiveMonIndexForSlot(battle.activeMonIndex, p, s);
            if (!_getMonState(config, p, monIndex).isKnockedOut) {
                _runEffectsForMon(battleKey, rng, p, p, EffectStep.RoundEnd, "", monIndex);
            }
        }

        // Final game over check after round end effects
        if (_checkForGameOverOrKO_Doubles(config, battle)) {
            address winner = (battle.winnerIndex == 0) ? battle.p0 : battle.p1;
            _handleGameOver(battleKey, winner);

            for (uint256 j = 0; j < numHooks; ++j) {
                config.engineHooks[j].onRoundEnd(battleKey);
            }

            emit EngineExecute(battleKey, turnId, 2, moveOrder[0].playerIndex);
            return;
        }

        // Run round end hooks
        for (uint256 i = 0; i < numHooks; ++i) {
            config.engineHooks[i].onRoundEnd(battleKey);
        }

        // End of turn cleanup
        battle.turnId += 1;

        // playerSwitchForTurnFlag was already set by _checkForGameOverOrKO_Doubles
        // based on whether players need to switch (have KO'd slots with valid targets)

        // Clear move flags for next turn
        config.p0Move.packedMoveIndex = 0;
        config.p1Move.packedMoveIndex = 0;
        config.p0Move2.packedMoveIndex = 0;
        config.p1Move2.packedMoveIndex = 0;

        emit EngineExecute(battleKey, turnId, 2, moveOrder[0].playerIndex);
    }
}
