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

    event ValidMoves(bytes32 battleKey, RevealedMove[] noOp, RevealedMove[] moves, RevealedMove[] switches);
    event SmartSelect(bytes32 battleKey, uint256 moveIndex);
    event AttackSelect(bytes32 battleKey, uint256 moveIndex);
    event SelfOrOtherSelect(bytes32 battleKey, uint256 moveIndex);

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

        emit ValidMoves(battleKey, noOp, moves, switches);

        // Merge all three arrays into one
        uint256 totalChoices = noOp.length + moves.length + switches.length;
        RevealedMove[] memory allChoices = new RevealedMove[](totalChoices);
        {
            uint256 index = 0;
            for (uint256 i = 0; i < noOp.length; i++) {
                allChoices[index++] = noOp[i];
            }
            for (uint256 i = 0; i < moves.length; i++) {
                allChoices[index++] = moves[i];
            }
            for (uint256 i = 0; i < switches.length; i++) {
                allChoices[index++] = switches[i];
            }
        }
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
            // If we are KO'ed
            uint256 activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[playerIndex];
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
            int32 staminaDelta = ENGINE.getMonStateForBattle(battleKey, playerIndex, ENGINE.getActiveMonIndexForBattleState(battleKey)[playerIndex], MonStateIndexName.Stamina);
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
                    // Look up move if the opponent is switching and set the correct active mon index
                    uint256 opponentMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[opponentIndex];
                    // Unpack the move index from packedMoveIndex
                    uint8 opponentMoveIndex = opponentMove.packedMoveIndex & MOVE_INDEX_MASK;
                    if (opponentMoveIndex == SWITCH_MOVE_INDEX) {
                        opponentMonIndex = uint256(opponentMove.extraData);
                    }
                    Type opponentType1 = Type(ENGINE.getMonValueForBattle(battleKey, opponentIndex, opponentMonIndex, MonStateIndexName.Type1));
                    Type opponentType2 = Type(ENGINE.getMonValueForBattle(battleKey, opponentIndex, opponentMonIndex, MonStateIndexName.Type2));
                    MoveClass[] memory moveClasses = new MoveClass[](2);
                    moveClasses[0] = MoveClass.Physical;
                    moveClasses[1] = MoveClass.Special;
                    uint128[] memory physicalOrSpecialMoves = _filterMoves(battleKey, playerIndex, moves, moveClasses);
                    if (physicalOrSpecialMoves.length > 0) {
                        uint128[] memory typeAdvantagedMoves = _getTypeAdvantageAttacks(battleKey, opponentIndex, opponentType1, opponentType2, moves, physicalOrSpecialMoves);
                        if (typeAdvantagedMoves.length > 0) {
                            uint256 rngIndex = _getRNG(battleKey) % typeAdvantagedMoves.length;
                            emit AttackSelect(battleKey, moves[typeAdvantagedMoves[rngIndex]].moveIndex);
                            return (moves[typeAdvantagedMoves[rngIndex]].moveIndex, moves[typeAdvantagedMoves[rngIndex]].extraData);
                        }
                    }
                }
                else {
                    MoveClass[] memory moveClasses = new MoveClass[](2);
                    moveClasses[0] = MoveClass.Self;
                    moveClasses[1] = MoveClass.Other;
                    uint128[] memory selfOrOtherMoves = _filterMoves(battleKey, playerIndex, moves, moveClasses);
                    if (selfOrOtherMoves.length > 0) {
                        uint256 rngIndex = _getRNG(battleKey) % selfOrOtherMoves.length;
                        emit SelfOrOtherSelect(battleKey, moves[selfOrOtherMoves[rngIndex]].moveIndex);
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
        uint256 rngIndex = _getRNG(battleKey);
        uint256 adjustedTotalMovesDenom = moves.length + 1;
        if (rngIndex % adjustedTotalMovesDenom == 0) {
            uint256 switchOrNoOp = _getRNG(battleKey) % 2;
            if (switchOrNoOp == 0 && noOp.length > 0) {
                emit SmartSelect(battleKey, noOp[0].moveIndex);
                return (noOp[0].moveIndex, noOp[0].extraData);
            } else if (switches.length > 0) {
                uint256 rngSwitchIndex = _getRNG(battleKey) % switches.length;
                emit SmartSelect(battleKey, switches[rngSwitchIndex].moveIndex);
                return (switches[rngSwitchIndex].moveIndex, switches[rngSwitchIndex].extraData);
            }
        } else if (moves.length > 0) {
            uint256 moveIndex = _getRNG(battleKey) % moves.length;
            emit SmartSelect(battleKey, moves[moveIndex].moveIndex);
            return (moves[moveIndex].moveIndex, moves[moveIndex].extraData);
        }
        // We should never get here, but`
        emit SmartSelect(battleKey, noOp[0].moveIndex);
        return (noOp[0].moveIndex, noOp[0].extraData);
    }

    function _filterMoves(bytes32 battleKey, uint256 playerIndex, RevealedMove[] memory moves, MoveClass[] memory moveClasses) internal view returns (uint128[] memory) {
        uint128[] memory validIndices = new uint128[](moves.length);
        uint256 validCount = 0;
        for (uint256 i = 0; i < moves.length; i++) {
            MoveClass currentMoveClass = ENGINE.getMoveForMonForBattle(battleKey, playerIndex, ENGINE.getActiveMonIndexForBattleState(battleKey)[playerIndex], moves[i].moveIndex).moveClass(battleKey);
            for (uint256 j = 0; j < moveClasses.length; j++) {
                if (currentMoveClass == moveClasses[j]) {
                    validIndices[validCount] = uint128(i);
                    validCount++;
                    break;
                }
            }
        }
        // Copy the valid indices into a new array with only the valid ones
        uint128[] memory validIndicesCopy = new uint128[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            validIndicesCopy[i] = validIndices[i];
        }
        return validIndicesCopy;
    }

    function _getTypeAdvantageAttacks(bytes32 battleKey, uint256 defenderPlayerIndex, Type defenderType1, Type defenderType2, RevealedMove[] memory attacks, uint128[] memory validAttackIndices) internal view returns (uint128[] memory) {
        uint128[] memory validIndices = new uint128[](validAttackIndices.length);
        uint256 validCount = 0;
        for (uint256 i = 0; i < validAttackIndices.length; i++) {
            IMoveSet currentMoveSet = ENGINE.getMoveForMonForBattle(battleKey, defenderPlayerIndex, ENGINE.getActiveMonIndexForBattleState(battleKey)[defenderPlayerIndex], attacks[validAttackIndices[i]].moveIndex);
            uint256 effectiveness = TYPE_CALC.getTypeEffectiveness(currentMoveSet.moveType(battleKey), defenderType1, 2);
            if (defenderType2 != Type.None) {
                uint256 effectiveness2 = TYPE_CALC.getTypeEffectiveness(currentMoveSet.moveType(battleKey), defenderType2, 2);
                effectiveness = (effectiveness * effectiveness2);
            }
            if (effectiveness > 2) {
                validIndices[validCount] = validAttackIndices[i];
                validCount++;
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
