// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Enums.sol";

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
    function removeStatBoost(uint256 targetIndex, uint256 monIndex, StatBoostFlag boostFlag) external;
    function clearAllStatBoosts(uint256 targetIndex, uint256 monIndex) external;
    function dealDamage(uint256 playerIndex, uint256 monIndex, int32 damage) external;
    function dispatchStandardAttack(
        uint256 attackerPlayerIndex,
        uint256 targetBits,
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
    function dispatchCustomAttack(
        uint256 attackerPlayerIndex,
        uint256 targetBits,
        uint32 basePower,
        uint32 accuracy,
        uint256 volatility,
        Type moveType,
        MoveClass moveClass,
        uint256 rng,
        uint256 critRate
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
    // 2-slot battles (Doubles/Multi)
    function startBattleWithMode(Battle memory battle, uint8 battleMode) external;
    function executeWithSlotMoves(bytes32 battleKey, uint256 side0Packed, uint256 side1Packed)
        external
        returns (address winner);
    function setMoveForSlot(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 slotIndex,
        uint8 moveIndex,
        uint16 extraData
    ) external;
    function switchActiveMonForSlot(uint256 playerIndex, uint256 slotIndex, uint256 monToSwitchIndex) external;
    function getMoveDecisionForSlot(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex)
        external
        view
        returns (MoveDecision memory);
    function getActiveSlots(bytes32 battleKey) external view returns (uint256[4] memory slots);
    function executeBatchedTurns(bytes32 battleKey, uint256[] calldata entries)
        external
        returns (uint64 executed, address winner);
    // 2-slot variant: entries are (side0, side1) wire-word pairs per turn.
    function executeBatchedSlotTurns(bytes32 battleKey, uint256[] calldata entries)
        external
        returns (uint64 executed, address winner);
    function resetCallContext() external;

    // Built-in dual-signed buffer flow (BUILTIN_DUAL_SIGNED_MANAGER battles). Flat args: a single packed
    // move word + an EIP-2098 compact revealer signature (r, vs).
    function submitTurnMoves(bytes32 battleKey, uint256 packedMoves, bytes32 r, bytes32 vs) external;
    function submitTurnMovesAndExecute(bytes32 battleKey, uint256 packedMoves, bytes32 r, bytes32 vs) external;
    function executeBuffered(bytes32 battleKey) external;
    function getBufferedTurns(bytes32 battleKey)
        external
        view
        returns (uint64 numExecuted, uint256[] memory packedTurns);
    // 2-slot variant: one wire word per side per turn (the executeWithSlotMoves layout)
    function submitSlotTurnMoves(
        bytes32 battleKey,
        uint256 committerSidePacked,
        uint256 revealerSidePacked,
        bytes32 r,
        bytes32 vs
    ) external;
    function submitSlotTurnMovesAndExecute(
        bytes32 battleKey,
        uint256 committerSidePacked,
        uint256 revealerSidePacked,
        bytes32 r,
        bytes32 vs
    ) external;
    function getBufferedSlotTurns(bytes32 battleKey)
        external
        view
        returns (uint64 numExecuted, uint256[] memory sideWords);

    // Getters
    function pairHashNonces(bytes32 pairHash) external view returns (uint256);
    function computeBattleKey(address p0, address p1) external view returns (bytes32 battleKey, bytes32 pairHash);
    function computePartyKey(address p0, address p1, address p2, address p3)
        external
        view
        returns (bytes32 battleKey, bytes32 partyHash);
    function getSeats(bytes32 battleKey) external view returns (address[4] memory seats);
    function computePriorityPlayerIndex(bytes32 battleKey, uint256 rng) external view returns (uint256);
    function getStorageKey(bytes32 battleKey) external view returns (bytes32);
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
    function getKOBitmap(bytes32 battleKey, uint256 playerIndex) external view returns (uint256);
    function getBattleContext(bytes32 battleKey) external view returns (BattleContext memory);
    function getDamageCalcContext(bytes32 battleKey, uint256 attackerPlayerIndex, uint256 defenderPlayerIndex)
        external
        view
        returns (DamageCalcContext memory);
    function getBattleEndContext(bytes32 battleKey) external view returns (BattleEndContext memory);
    function getMonStatesForSide(bytes32 battleKey, uint256 playerIndex) external view returns (MonState[] memory);
}
