// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";
import {ICPURNG} from "../rng/ICPURNG.sol";
import {CPU} from "./CPU.sol";
import {MoveDecision, RevealedMove} from "../Structs.sol";
import {ITypeCalculator} from "../types/ITypeCalculator.sol";
import {MonStateIndexName, Type, MoveClass} from "../Enums.sol";
import {IMoveSet} from "../moves/IMoveSet.sol";
import {SWITCH_MOVE_INDEX, MOVE_INDEX_MASK} from "../Constants.sol";

contract OkayCPU is CPU {

    uint256 public constant SMART_SELECT_SHORT_CIRCUIT_DENOM = 6;
    ITypeCalculator public immutable TYPE_CALC;

    constructor(uint256 numMoves, IEngine engine, ICPURNG rng, ITypeCalculator typeCalc) CPU(numMoves, engine, rng) {
        TYPE_CALC = typeCalc;
    }

    /**
     * If it's turn 0, swap in a mon that resists the other player's type1 (if possible)
     */
    function calculateMove(bytes32 battleKey, uint256 playerIndex)
        external
        override
        returns (uint128 moveIndex, uint240 extraData)
    {
        (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches) = calculateValidMoves(battleKey, playerIndex);

        uint256 opponentIndex = (playerIndex + 1) % 2;
        MoveDecision memory opponentMove = ENGINE.getMoveDecisionForBattleState(battleKey, opponentIndex);
        uint256 turnId = ENGINE.getTurnIdForBattleState(battleKey);

        // If it's the first turn, try and find a mon who has a type advantage to the opponent's type1
        if (turnId == 0) {
            Type opponentType1 = Type(ENGINE.getMonValueForBattle(battleKey, opponentIndex, uint256(opponentMove.extraData), MonStateIndexName.Type1));
            Type[] memory selfTypes = new Type[](switches.length);
            for (uint256 i = 0; i < switches.length; i++) {
                selfTypes[i] = Type(ENGINE.getMonValueForBattle(battleKey, playerIndex, uint256(switches[i].extraData), MonStateIndexName.Type1));
            }
            int256 bestIndex = _getTypeAdvantageOrNullToDefend(opponentType1, selfTypes);
            if (bestIndex != -1) {
                return (switches[uint256(bestIndex)].moveIndex, switches[uint256(bestIndex)].extraData);
            }
            else {
                uint256 rngIndex = _getRNG(battleKey) % switches.length;
                return (switches[rngIndex].moveIndex, switches[rngIndex].extraData);
            }
        } 
        /*
            Else, 1/6 of the time we act randomly.
            Otherwise, if:
            - We have 2 or less stamina, we rest (75%) or swap (if possible)
            - If we are at full health, try and choose a non-damaging move if possible
            - If we are not at full health, try and choose a MoveClass.Physical or MoveClass.Special move (with advantage) if possible
            - Otherwise, do a smart random select
        */
        else {
            // Cache active mon indices - single external call instead of multiple
            uint256[] memory activeMonIndices = ENGINE.getActiveMonIndexForBattleState(battleKey);
            uint256 activeMonIndex = activeMonIndices[playerIndex];
            uint256 opponentMonIndex = activeMonIndices[opponentIndex];

            // If we are KO'ed
            int32 isKOed = ENGINE.getMonStateForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.IsKnockedOut);
            if (isKOed == 1) {
                uint256 rngIndex = _getRNG(battleKey) % switches.length;
                return (switches[rngIndex].moveIndex, switches[rngIndex].extraData);
            }
            // Add some default unpredictability
            if (_getRNG(battleKey) % SMART_SELECT_SHORT_CIRCUIT_DENOM == (SMART_SELECT_SHORT_CIRCUIT_DENOM - 1)) {
                return _smartRandomSelect(battleKey, noOp, moves, switches);
            }
            // Otherwise, try and act smart
            int32 staminaDelta = ENGINE.getMonStateForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.Stamina);
            if (staminaDelta <= -3) {
                if (_getRNG(battleKey) % 4 != 0 && noOp.length > 0) {
                    return (noOp[0].moveIndex, noOp[0].extraData);
                } else if (switches.length > 0) {
                    uint256 rngIndex = _getRNG(battleKey) % switches.length;
                    return (switches[rngIndex].moveIndex, switches[rngIndex].extraData);
                }
            }
            else {
                int256 hpDelta = ENGINE.getMonStateForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.Hp);
                if (hpDelta != 0) {
                    // Check if the opponent is switching and update mon index accordingly
                    uint8 opponentMoveIdx = opponentMove.packedMoveIndex & MOVE_INDEX_MASK;
                    if (opponentMoveIdx == SWITCH_MOVE_INDEX) {
                        opponentMonIndex = uint256(opponentMove.extraData);
                    }
                    Type opponentType1 = Type(ENGINE.getMonValueForBattle(battleKey, opponentIndex, opponentMonIndex, MonStateIndexName.Type1));
                    Type opponentType2 = Type(ENGINE.getMonValueForBattle(battleKey, opponentIndex, opponentMonIndex, MonStateIndexName.Type2));
                    uint128[] memory physicalOrSpecialMoves = _filterMoves(battleKey, playerIndex, activeMonIndex, moves, MoveClass.Physical, MoveClass.Special);
                    if (physicalOrSpecialMoves.length > 0) {
                        uint128[] memory typeAdvantagedMoves = _getTypeAdvantageAttacks(battleKey, playerIndex, activeMonIndex, opponentType1, opponentType2, moves, physicalOrSpecialMoves);
                        if (typeAdvantagedMoves.length > 0) {
                            uint256 rngIndex = _getRNG(battleKey) % typeAdvantagedMoves.length;
                            return (moves[typeAdvantagedMoves[rngIndex]].moveIndex, moves[typeAdvantagedMoves[rngIndex]].extraData);
                        }
                    }
                }
                else {
                    uint128[] memory selfOrOtherMoves = _filterMoves(battleKey, playerIndex, activeMonIndex, moves, MoveClass.Self, MoveClass.Other);
                    if (selfOrOtherMoves.length > 0) {
                        uint256 rngIndex = _getRNG(battleKey) % selfOrOtherMoves.length;
                        return (moves[selfOrOtherMoves[rngIndex]].moveIndex, moves[selfOrOtherMoves[rngIndex]].extraData);
                    }
                }
                return _smartRandomSelect(battleKey, noOp, moves, switches);
            }
        }
    }

    function _getRNG(bytes32 battleKey) internal returns (uint256) {
        return RNG.getRNG(keccak256(abi.encode(nonceToUse++, battleKey, block.timestamp)));
    }

    // Biased towards moves versus swapping or resting
    function _smartRandomSelect(bytes32 battleKey, RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches) internal returns (uint128, uint240) {
        // Single RNG call - use different bit ranges for different random decisions
        uint256 rng = _getRNG(battleKey);
        uint256 movesLen = moves.length;
        uint256 adjustedTotalMovesDenom = movesLen + 1;

        if (rng % adjustedTotalMovesDenom == 0) {
            // Use bits 8-15 for switch vs noOp decision
            uint256 switchOrNoOp = (rng >> 8) % 2;
            if (switchOrNoOp == 0 && noOp.length > 0) {
                return (noOp[0].moveIndex, noOp[0].extraData);
            } else if (switches.length > 0) {
                // Use bits 16-31 for switch index
                uint256 rngSwitchIndex = (rng >> 16) % switches.length;
                return (switches[rngSwitchIndex].moveIndex, switches[rngSwitchIndex].extraData);
            }
        } else if (movesLen > 0) {
            // Use bits 8-23 for move index
            uint256 moveIdx = (rng >> 8) % movesLen;
            return (moves[moveIdx].moveIndex, moves[moveIdx].extraData);
        }
        // Fallback
        return (noOp[0].moveIndex, noOp[0].extraData);
    }

    function _filterMoves(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 activeMonIndex,
        RevealedMove[] memory moves,
        MoveClass class1,
        MoveClass class2
    ) internal view returns (uint128[] memory) {
        uint128[] memory validIndices = new uint128[](moves.length);
        uint256 validCount = 0;
        uint256 movesLen = moves.length;
        for (uint256 i = 0; i < movesLen; i++) {
            MoveClass currentMoveClass = ENGINE.getMoveForMonForBattle(battleKey, playerIndex, activeMonIndex, moves[i].moveIndex).moveClass(battleKey);
            if (currentMoveClass == class1 || currentMoveClass == class2) {
                validIndices[validCount++] = uint128(i);
            }
        }
        // Copy the valid indices into a new array with only the valid ones
        uint128[] memory validIndicesCopy = new uint128[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            validIndicesCopy[i] = validIndices[i];
        }
        return validIndicesCopy;
    }

    function _getTypeAdvantageAttacks(
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        Type defenderType1,
        Type defenderType2,
        RevealedMove[] memory attacks,
        uint128[] memory validAttackIndices
    ) internal view returns (uint128[] memory) {
        uint128[] memory validIndices = new uint128[](validAttackIndices.length);
        uint256 validCount = 0;
        uint256 indicesLen = validAttackIndices.length;
        for (uint256 i = 0; i < indicesLen; i++) {
            IMoveSet currentMoveSet = ENGINE.getMoveForMonForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, attacks[validAttackIndices[i]].moveIndex);
            Type moveType = currentMoveSet.moveType(battleKey);
            uint256 effectiveness = TYPE_CALC.getTypeEffectiveness(moveType, defenderType1, 2);
            if (defenderType2 != Type.None) {
                effectiveness = effectiveness * TYPE_CALC.getTypeEffectiveness(moveType, defenderType2, 2);
            }
            if (effectiveness > 2) {
                validIndices[validCount++] = validAttackIndices[i];
            }
        }
        // Copy the valid indices into a new array with only the valid ones
        uint128[] memory validIndicesCopy = new uint128[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            validIndicesCopy[i] = validIndices[i];
        }
        return validIndicesCopy;
    }

    function _getTypeAdvantageOrNullToDefend(Type attackerType, Type[] memory defenderTypes) internal view returns (int) {
        for (uint256 i = 0; i < defenderTypes.length; i++) {
            uint256 effectiveness = TYPE_CALC.getTypeEffectiveness(attackerType, defenderTypes[i], 2);
            if (effectiveness == 0 || effectiveness == 1) {
                return int256(i);
            }
        }
        return -1;
    }
}
