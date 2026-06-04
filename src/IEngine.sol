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
    function removeEffect(uint256 targetIndex, uint256 monIndex, uint256 effectIndex) external;
    function editEffect(uint256 targetIndex, uint256 effectIndex, bytes32 newExtraData) external;
    function setGlobalKV(uint64 key, uint192 value) external;
    // Inlined stat boosts (formerly the StatBoosts effect contract). Keyed by msg.sender.
    function addStatBoost(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostToApply[] calldata statBoostsToApply,
        StatBoostFlag boostFlag
    ) external;
    function addKeyedStatBoost(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostToApply[] calldata statBoostsToApply,
        StatBoostFlag boostFlag,
        string calldata keyToUse
    ) external;
    function removeStatBoost(uint256 targetIndex, uint256 monIndex, StatBoostFlag boostFlag) external;
    function removeKeyedStatBoost(
        uint256 targetIndex,
        uint256 monIndex,
        StatBoostFlag boostFlag,
        string calldata keyToUse
    ) external;
    function clearAllStatBoosts(uint256 targetIndex, uint256 monIndex) external;
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

    // Built-in dual-signed buffer flow (BUILTIN_DUAL_SIGNED_MANAGER battles)
    function submitTurnMoves(bytes32 battleKey, TurnSubmission calldata entry) external;
    function submitTurnMovesAndExecute(bytes32 battleKey, TurnSubmission calldata entry) external;
    function executeBuffered(bytes32 battleKey) external;
    function getBufferStatus(bytes32 battleKey) external view returns (uint64 numExecuted, uint8 numBuffered);
    function getBufferedTurn(bytes32 battleKey, uint64 turnId)
        external
        view
        returns (uint8 p0Move, uint16 p0Extra, uint104 p0Salt, uint8 p1Move, uint16 p1Extra, uint104 p1Salt);

    // Getters
    function pairHashNonces(bytes32 pairHash) external view returns (uint256);
    function computeBattleKey(address p0, address p1) external view returns (bytes32 battleKey, bytes32 pairHash);
    function computePriorityPlayerIndex(bytes32 battleKey, uint256 rng) external view returns (uint256);
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
    function getGlobalKV(bytes32 battleKey, uint64 key) external view returns (uint192);
    function validatePlayerMoveForBattle(bytes32 battleKey, uint256 moveIndex, uint256 playerIndex, uint16 extraData)
        external
        returns (bool);
    function getEffects(bytes32 battleKey, uint256 targetIndex, uint256 monIndex)
        external
        view
        returns (EffectInstance[] memory, uint256[] memory);
    function getEffectData(bytes32 battleKey, uint256 targetIndex, uint256 monIndex, address effectAddr)
        external
        view
        returns (bool exists, uint256 effectIndex, bytes32 data);
    function getWinner(bytes32 battleKey) external view returns (address);
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
    function getBattleEndContext(bytes32 battleKey) external view returns (BattleEndContext memory);
    function getMonStatesForSide(bytes32 battleKey, uint256 playerIndex)
        external
        view
        returns (MonState[] memory);
}
