// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Enums.sol";

import "./IValidator.sol";
import "./Structs.sol";
import "./effects/IEffect.sol";
import "./moves/IMoveSet.sol";

interface IEngine {
    // Transient state
    function battleKeyForWrite() external view returns (bytes32);
    function tempRNG() external view returns (uint256);

    // PreDamage threading: hooks read the running damage and call setPreDamage to mutate it.
    function getPreDamage() external view returns (int32);
    function setPreDamage(int32 value) external;

    // State mutating effects
    function updateMatchmakers(address[] memory makersToAdd, address[] memory makersToRemove) external;
    function startBattle(Battle memory battle) external;
    function updateMonState(uint256 playerIndex, uint256 monIndex, MonStateIndexName stateVarIndex, int32 valueToAdd)
        external;
    function addEffect(uint256 targetIndex, uint256 monIndex, IEffect effect, bytes32 extraData) external;
    /// @notice Add `effect` to (`targetIndex`, `monIndex`) only if no live slot already holds it.
    ///         Coalesces the canonical ability "iterate getEffects to dedup, then addEffect" pattern
    ///         into a single CALL with an internal storage-side scan.
    /// @return added True if newly added; false if a live slot already held this effect.
    function addEffectIfNotPresent(uint256 targetIndex, uint256 monIndex, IEffect effect, bytes32 extraData)
        external
        returns (bool added);
    function removeEffect(uint256 targetIndex, uint256 monIndex, uint256 effectIndex) external;
    function editEffect(uint256 targetIndex, uint256 effectIndex, bytes32 newExtraData) external;
    function setGlobalKV(uint64 key, uint192 value) external;
    /// @notice Read the current value at `key` and, if it was zero, store `valueIfZero` in the same call.
    ///         Coalesces the "if (getGlobalKV(key) == 0) { …; setGlobalKV(key, v); }" once-per-battle
    ///         flag pattern. Callers that need to mutate conditionally on an unrelated runtime check
    ///         should keep using `getGlobalKV` + `setGlobalKV` — this primitive eagerly initializes.
    /// @return previousValue The value read before any write was applied.
    function getAndInitGlobalKV(uint64 key, uint192 valueIfZero) external returns (uint192 previousValue);
    function dealDamage(uint256 playerIndex, uint256 monIndex, int32 damage) external;
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
    ) external returns (int32 damage, bytes32 eventType);
    function switchActiveMon(uint256 playerIndex, uint256 monToSwitchIndex) external;
    function setMove(bytes32 battleKey, uint256 playerIndex, uint8 moveIndex, uint104 salt, uint16 extraData) external;
    function execute(bytes32 battleKey) external returns (address winner);
    function executeWithMoves(
        bytes32 battleKey,
        uint8 p0MoveIndex,
        uint104 p0Salt,
        uint16 p0ExtraData,
        uint8 p1MoveIndex,
        uint104 p1Salt,
        uint16 p1ExtraData
    ) external returns (address winner);
    function executeWithSingleMove(bytes32 battleKey, uint8 moveIndex, uint104 salt, uint16 extraData)
        external
        returns (address winner);
    function executeBatchedTurns(bytes32 battleKey, uint256[] calldata entries)
        external
        returns (uint64 executed, address winner);
    function resetCallContext() external;

    // Getters
    function pairHashNonces(bytes32 pairHash) external view returns (uint256);
    function computeBattleKey(address p0, address p1) external view returns (bytes32 battleKey, bytes32 pairHash);
    function computePriorityPlayerIndex(bytes32 battleKey, uint256 rng) external view returns (uint256);
    /// @notice Resolves a `battleKey` to the storage key used by `BattleConfig` slot allocation.
    /// @dev Returns the battleKey itself when no allocation has been recorded. Used by managers
    ///      that want to key their own buffers on storageKey (so slots reuse across battles via
    ///      `MappingAllocator`'s free-list and benefit from steady-state warm-SSTORE costs).
    function getStorageKey(bytes32 battleKey) external view returns (bytes32);
    function getSubmitContext(bytes32 battleKey)
        external
        view
        returns (address p0, address p1, uint64 turnId, uint8 winnerIndex, bytes32 storageKey);
    function getBattle(bytes32 battleKey) external view returns (BattleConfigView memory, BattleData memory);
    function getMonValueForBattle(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex
    ) external view returns (uint32);
    function getMonStatsForBattle(bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        external
        view
        returns (MonStats memory);
    function getMonStateForBattle(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex
    ) external view returns (int32);
    function getMoveForMonForBattle(bytes32 battleKey, uint256 playerIndex, uint256 monIndex, uint256 moveIndex)
        external
        view
        returns (uint256);
    function getMoveDecisionForBattleState(bytes32 battleKey, uint256 playerIndex)
        external
        view
        returns (MoveDecision memory);
    function getPlayersForBattle(bytes32 battleKey) external view returns (address[] memory);
    function getTeamSize(bytes32 battleKey, uint256 playerIndex) external view returns (uint256);
    function getTurnIdForBattleState(bytes32 battleKey) external view returns (uint256);
    function getActiveMonIndexForBattleState(bytes32 battleKey) external view returns (uint256[] memory);
    function getPlayerSwitchForTurnFlagForBattleState(bytes32 battleKey) external view returns (uint256);
    function getGlobalKV(bytes32 battleKey, uint64 key) external view returns (uint192);
    function validatePlayerMoveForBattle(bytes32 battleKey, uint256 moveIndex, uint256 playerIndex, uint16 extraData)
        external
        returns (bool);
    function getEffects(bytes32 battleKey, uint256 targetIndex, uint256 monIndex)
        external
        view
        returns (EffectInstance[] memory, uint256[] memory);
    function getWinner(bytes32 battleKey) external view returns (address);
    function getStartTimestamp(bytes32 battleKey) external view returns (uint256);
    function getLastExecuteTimestamp(bytes32 battleKey) external view returns (uint48);
    function getKOBitmap(bytes32 battleKey, uint256 playerIndex) external view returns (uint256);
    function getBattleContext(bytes32 battleKey) external view returns (BattleContext memory);
    function getCommitContext(bytes32 battleKey) external view returns (CommitContext memory);
    function getCommitAuthForDualSigned(bytes32 battleKey)
        external
        view
        returns (address committer, address revealer, uint64 turnId);
    function getDamageCalcContext(bytes32 battleKey, uint256 attackerPlayerIndex, uint256 defenderPlayerIndex)
        external
        view
        returns (DamageCalcContext memory);
    /// @notice Batched read of both sides' base stats, deltas, and live effect lists for an
    ///         attacker/defender pair. Lets custom moves consume one STATICCALL instead of the
    ///         4–7 individual `getMonStatsForBattle` / `getMonStateForBattle` / `getEffects`
    ///         callbacks the worst offenders do today. Sentinel deltas are returned as 0;
    ///         tombstoned effect slots are filtered out.
    function getMoveContext(
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderPlayerIndex,
        uint256 defenderMonIndex
    ) external view returns (MoveContext memory);
    function getValidationContext(bytes32 battleKey) external view returns (ValidationContext memory);
    function getCPUContext(bytes32 battleKey) external view returns (CPUContext memory);
    function getCPURouteContext(bytes32 battleKey)
        external
        view
        returns (address p0, uint8 winnerIndex, uint8 playerSwitchForTurnFlag);
    function getBattleEndContext(bytes32 battleKey) external view returns (BattleEndContext memory);
    function getMonStatesForSide(bytes32 battleKey, uint256 playerIndex)
        external
        view
        returns (MonState[] memory);
}
