// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Enums.sol";

import "./IValidator.sol";
import "./Structs.sol";
import "./moves/IMoveSet.sol";

interface IEngine {
    // Transient state
    function battleKeyForWrite() external view returns (bytes32);
    function tempRNG() external view returns (uint256);

    // State mutating effects
    function updateMatchmakers(address[] memory makersToAdd, address[] memory makersToRemove) external;
    function startBattle(Battle memory battle) external;
    function updateMonState(uint256 playerIndex, uint256 monIndex, MonStateIndexName stateVarIndex, int32 valueToAdd)
        external;
    function addEffect(uint256 targetIndex, uint256 monIndex, IEffect effect, bytes32 extraData) external;
    function removeEffect(uint256 targetIndex, uint256 monIndex, uint256 effectIndex) external;
    function editEffect(uint256 targetIndex, uint256 monIndex, uint256 effectIndex, bytes32 newExtraData) external;
    function setGlobalKV(bytes32 key, uint192 value) external;
    function dealDamage(uint256 playerIndex, uint256 monIndex, int32 damage) external;
    function switchActiveMon(uint256 playerIndex, uint256 monToSwitchIndex) external;
    function switchActiveMonForSlot(uint256 playerIndex, uint256 slotIndex, uint256 monToSwitchIndex) external;
    function setMove(bytes32 battleKey, uint256 playerIndex, uint8 moveIndex, bytes32 salt, uint240 extraData) external;
    function setMoveForSlot(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex, uint8 moveIndex, bytes32 salt, uint240 extraData) external;
    function execute(bytes32 battleKey) external;
    function emitEngineEvent(bytes32 eventType, bytes memory extraData) external;
    function setUpstreamCaller(address caller) external;

    // Getters
    function computeBattleKey(address p0, address p1) external view returns (bytes32 battleKey, bytes32 pairHash);
    function computePriorityPlayerIndex(bytes32 battleKey, uint256 rng) external view returns (uint256);
    function getMoveManager(bytes32 battleKey) external view returns (address);
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
    function getMonStateForStorageKey(
        bytes32 storageKey,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex
    ) external view returns (int32);
    function getMoveForMonForBattle(bytes32 battleKey, uint256 playerIndex, uint256 monIndex, uint256 moveIndex)
        external
        view
        returns (IMoveSet);
    function getMoveDecisionForBattleState(bytes32 battleKey, uint256 playerIndex)
        external
        view
        returns (MoveDecision memory);
    function getPlayersForBattle(bytes32 battleKey) external view returns (address[] memory);
    function getTeamSize(bytes32 battleKey, uint256 playerIndex) external view returns (uint256);
    function getTurnIdForBattleState(bytes32 battleKey) external view returns (uint256);
    function getActiveMonIndexForBattleState(bytes32 battleKey) external view returns (uint256[] memory);
    function getPlayerSwitchForTurnFlagForBattleState(bytes32 battleKey) external view returns (uint256);
    function getGlobalKV(bytes32 battleKey, bytes32 key) external view returns (uint192);
    function getBattleValidator(bytes32 battleKey) external view returns (IValidator);
    function getEffects(bytes32 battleKey, uint256 targetIndex, uint256 monIndex)
        external
        view
        returns (EffectInstance[] memory, uint256[] memory);
    function getWinner(bytes32 battleKey) external view returns (address);
    function getStartTimestamp(bytes32 battleKey) external view returns (uint256);
    function getPrevPlayerSwitchForTurnFlagForBattleState(bytes32 battleKey) external view returns (uint256);
    function getBattleContext(bytes32 battleKey) external view returns (BattleContext memory);
    function getCommitContext(bytes32 battleKey) external view returns (CommitContext memory);
    function getDamageCalcContext(bytes32 battleKey, uint256 attackerPlayerIndex, uint256 defenderPlayerIndex)
        external
        view
        returns (DamageCalcContext memory);

    // Doubles-specific getters
    function getGameMode(bytes32 battleKey) external view returns (GameMode);
    function getActiveMonIndexForSlot(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex)
        external
        view
        returns (uint256);
}
