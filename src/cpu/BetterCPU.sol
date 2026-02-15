// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";
import {ICPURNG} from "../rng/ICPURNG.sol";
import {CPU} from "./CPU.sol";
import {DamageCalcContext, MoveDecision, RevealedMove} from "../Structs.sol";
import {ITypeCalculator} from "../types/ITypeCalculator.sol";
import {MonStateIndexName, Type, MoveClass} from "../Enums.sol";
import {IMoveSet} from "../moves/IMoveSet.sol";
import {SWITCH_MOVE_INDEX, MOVE_INDEX_MASK} from "../Constants.sol";

/// @notice Interface for moves that expose basePower (e.g., StandardAttack)
interface IAttackMove {
    function basePower(bytes32 battleKey) external view returns (uint32);
    function accuracy(bytes32 battleKey) external view returns (uint32);
}

/// @title BetterCPU
/// @notice An improved CPU that adds kill threat detection and 1-turn lookahead
contract BetterCPU is CPU {
    uint256 public constant SMART_SELECT_SHORT_CIRCUIT_DENOM = 10; // Less random than OkayCPU (10% vs 16%)
    ITypeCalculator public immutable TYPE_CALC;

    // Damage estimation constants
    uint32 constant DAMAGE_ESTIMATE_SCALING = 100;
    uint32 constant MIN_KO_CONFIDENCE = 80; // Only count as KO if estimated damage >= 80% of remaining HP

    constructor(uint256 numMoves, IEngine engine, ICPURNG rng, ITypeCalculator typeCalc) CPU(numMoves, engine, rng) {
        TYPE_CALC = typeCalc;
    }

    function calculateMove(bytes32 battleKey, uint256 playerIndex)
        external
        override
        returns (uint128 moveIndex, uint240 extraData)
    {
        (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches) = calculateValidMoves(battleKey, playerIndex);

        uint256 opponentIndex = (playerIndex + 1) % 2;
        MoveDecision memory opponentMove = ENGINE.getMoveDecisionForBattleState(battleKey, opponentIndex);
        uint256 turnId = ENGINE.getTurnIdForBattleState(battleKey);

        // Turn 0: Select lead with type advantage
        if (turnId == 0) {
            return _selectLead(battleKey, playerIndex, opponentIndex, opponentMove, switches);
        }

        // Cache indices
        uint256[] memory activeMonIndices = ENGINE.getActiveMonIndexForBattleState(battleKey);
        uint256 activeMonIndex = activeMonIndices[playerIndex];
        uint256 opponentMonIndex = activeMonIndices[opponentIndex];

        // If KO'ed, must switch
        int32 isKOed = ENGINE.getMonStateForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.IsKnockedOut);
        if (isKOed == 1) {
            return _selectBestSwitch(battleKey, playerIndex, opponentIndex, opponentMonIndex, switches);
        }

        // Check if opponent is switching - update their mon index
        uint8 opponentMoveIdx = opponentMove.packedMoveIndex & MOVE_INDEX_MASK;
        if (opponentMoveIdx == SWITCH_MOVE_INDEX) {
            opponentMonIndex = uint256(opponentMove.extraData);
        }

        // === KILL THREAT DETECTION ===
        // Check if we can KO the opponent - if so, take it!
        int256 koMoveIndex = _findKOMove(battleKey, playerIndex, activeMonIndex, opponentIndex, opponentMonIndex, moves);
        if (koMoveIndex >= 0) {
            return (moves[uint256(koMoveIndex)].moveIndex, moves[uint256(koMoveIndex)].extraData);
        }

        // === 1-TURN LOOKAHEAD: SURVIVAL CHECK ===
        // Check if opponent can KO us - if so, consider switching to a mon that resists
        if (switches.length > 0 && _canOpponentKOUs(battleKey, playerIndex, activeMonIndex, opponentIndex, opponentMonIndex)) {
            int256 bestSwitch = _findSafeSwitch(battleKey, playerIndex, opponentIndex, opponentMonIndex, switches);
            if (bestSwitch >= 0) {
                return (switches[uint256(bestSwitch)].moveIndex, switches[uint256(bestSwitch)].extraData);
            }
        }

        // Add some unpredictability (less than OkayCPU)
        if (_getRNG(battleKey) % SMART_SELECT_SHORT_CIRCUIT_DENOM == 0) {
            return _smartRandomSelect(battleKey, noOp, moves, switches);
        }

        // Stamina management
        int32 staminaDelta = ENGINE.getMonStateForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.Stamina);
        if (staminaDelta <= -3) {
            if (_getRNG(battleKey) % 4 != 0 && noOp.length > 0) {
                return (noOp[0].moveIndex, noOp[0].extraData);
            } else if (switches.length > 0) {
                return _selectBestSwitch(battleKey, playerIndex, opponentIndex, opponentMonIndex, switches);
            }
        }

        // Standard move selection with type advantage
        int256 hpDelta = ENGINE.getMonStateForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.Hp);
        if (hpDelta != 0) {
            // Damaged: prefer attacking moves with type advantage
            Type opponentType1 = Type(ENGINE.getMonValueForBattle(battleKey, opponentIndex, opponentMonIndex, MonStateIndexName.Type1));
            Type opponentType2 = Type(ENGINE.getMonValueForBattle(battleKey, opponentIndex, opponentMonIndex, MonStateIndexName.Type2));
            uint128[] memory attackMoves = _filterMoves(battleKey, playerIndex, activeMonIndex, moves, MoveClass.Physical, MoveClass.Special);
            if (attackMoves.length > 0) {
                // Find best move by estimated damage
                int256 bestMove = _findHighestDamageMove(battleKey, playerIndex, activeMonIndex, opponentIndex, opponentMonIndex, opponentType1, opponentType2, moves, attackMoves);
                if (bestMove >= 0) {
                    return (moves[uint256(bestMove)].moveIndex, moves[uint256(bestMove)].extraData);
                }
            }
        } else {
            // Full HP: prefer setup moves
            uint128[] memory setupMoves = _filterMoves(battleKey, playerIndex, activeMonIndex, moves, MoveClass.Self, MoveClass.Other);
            if (setupMoves.length > 0) {
                uint256 rngIndex = _getRNG(battleKey) % setupMoves.length;
                return (moves[setupMoves[rngIndex]].moveIndex, moves[setupMoves[rngIndex]].extraData);
            }
        }

        return _smartRandomSelect(battleKey, noOp, moves, switches);
    }

    // ============ KILL THREAT DETECTION ============

    /// @notice Find a move that can KO the opponent
    function _findKOMove(
        bytes32 battleKey,
        uint256 attackerIndex,
        uint256 attackerMonIndex,
        uint256 defenderIndex,
        uint256 defenderMonIndex,
        RevealedMove[] memory moves
    ) internal view returns (int256) {
        // Get defender's remaining HP
        uint32 defenderBaseHp = ENGINE.getMonValueForBattle(battleKey, defenderIndex, defenderMonIndex, MonStateIndexName.Hp);
        int32 defenderHpDelta = ENGINE.getMonStateForBattle(battleKey, defenderIndex, defenderMonIndex, MonStateIndexName.Hp);
        int256 defenderCurrentHp = int256(uint256(defenderBaseHp)) + int256(defenderHpDelta);
        if (defenderCurrentHp <= 0) return -1; // Already KO'd

        // Get damage calc context
        DamageCalcContext memory ctx = ENGINE.getDamageCalcContext(battleKey, attackerIndex, defenderIndex);

        int256 bestMoveIndex = -1;
        uint256 bestDamage = 0;

        for (uint256 i = 0; i < moves.length; i++) {
            IMoveSet moveSet = ENGINE.getMoveForMonForBattle(battleKey, attackerIndex, attackerMonIndex, moves[i].moveIndex);
            MoveClass moveClass = moveSet.moveClass(battleKey);

            // Only consider damaging moves
            if (moveClass != MoveClass.Physical && moveClass != MoveClass.Special) continue;

            uint256 estimatedDamage = _estimateDamage(battleKey, ctx, moveSet, moveClass);

            // Check if this KOs with confidence threshold
            if (estimatedDamage * 100 >= uint256(defenderCurrentHp) * MIN_KO_CONFIDENCE) {
                if (estimatedDamage > bestDamage) {
                    bestDamage = estimatedDamage;
                    bestMoveIndex = int256(i);
                }
            }
        }

        return bestMoveIndex;
    }

    /// @notice Estimate damage a move will deal (simplified calculation)
    function _estimateDamage(
        bytes32 battleKey,
        DamageCalcContext memory ctx,
        IMoveSet moveSet,
        MoveClass moveClass
    ) internal view returns (uint256) {
        // Try to get base power - not all moves expose this
        uint32 basePower;
        try IAttackMove(address(moveSet)).basePower(battleKey) returns (uint32 bp) {
            basePower = bp;
        } catch {
            return 0; // Can't estimate damage for non-standard moves
        }

        if (basePower == 0) return 0;

        // Get attack/defense stats
        uint32 attackStat;
        uint32 defenceStat;
        if (moveClass == MoveClass.Physical) {
            attackStat = uint32(int32(ctx.attackerAttack) + ctx.attackerAttackDelta);
            defenceStat = uint32(int32(ctx.defenderDef) + ctx.defenderDefDelta);
        } else {
            attackStat = uint32(int32(ctx.attackerSpAtk) + ctx.attackerSpAtkDelta);
            defenceStat = uint32(int32(ctx.defenderSpDef) + ctx.defenderSpDefDelta);
        }

        if (attackStat == 0) attackStat = 1;
        if (defenceStat == 0) defenceStat = 1;

        // Apply type effectiveness
        Type moveType = moveSet.moveType(battleKey);
        uint32 scaledBasePower = TYPE_CALC.getTypeEffectiveness(moveType, ctx.defenderType1, basePower);
        if (ctx.defenderType2 != Type.None) {
            scaledBasePower = TYPE_CALC.getTypeEffectiveness(moveType, ctx.defenderType2, scaledBasePower);
        }

        // Simplified damage formula (no crit, no volatility)
        return (uint256(scaledBasePower) * uint256(attackStat)) / uint256(defenceStat);
    }

    // ============ 1-TURN LOOKAHEAD ============

    /// @notice Check if opponent can KO us this turn
    function _canOpponentKOUs(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 playerMonIndex,
        uint256 opponentIndex,
        uint256 opponentMonIndex
    ) internal view returns (bool) {
        // Get our remaining HP
        uint32 ourBaseHp = ENGINE.getMonValueForBattle(battleKey, playerIndex, playerMonIndex, MonStateIndexName.Hp);
        int32 ourHpDelta = ENGINE.getMonStateForBattle(battleKey, playerIndex, playerMonIndex, MonStateIndexName.Hp);
        int256 ourCurrentHp = int256(uint256(ourBaseHp)) + int256(ourHpDelta);
        if (ourCurrentHp <= 0) return true; // Already KO'd

        // Get damage context from opponent's perspective
        DamageCalcContext memory ctx = ENGINE.getDamageCalcContext(battleKey, opponentIndex, playerIndex);

        // Estimate max damage opponent can deal
        // We check all 4 potential move slots
        for (uint256 moveIdx = 0; moveIdx < 4; moveIdx++) {
            try ENGINE.getMoveForMonForBattle(battleKey, opponentIndex, opponentMonIndex, moveIdx) returns (IMoveSet moveSet) {
                MoveClass moveClass = moveSet.moveClass(battleKey);
                if (moveClass != MoveClass.Physical && moveClass != MoveClass.Special) continue;

                uint256 estimatedDamage = _estimateDamage(battleKey, ctx, moveSet, moveClass);
                if (estimatedDamage * 100 >= uint256(ourCurrentHp) * MIN_KO_CONFIDENCE) {
                    return true;
                }
            } catch {
                continue; // Move doesn't exist
            }
        }

        return false;
    }

    /// @notice Find a switch target that resists the opponent's types
    function _findSafeSwitch(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 opponentIndex,
        uint256 opponentMonIndex,
        RevealedMove[] memory switches
    ) internal view returns (int256) {
        Type opponentType1 = Type(ENGINE.getMonValueForBattle(battleKey, opponentIndex, opponentMonIndex, MonStateIndexName.Type1));

        for (uint256 i = 0; i < switches.length; i++) {
            uint256 switchMonIndex = uint256(switches[i].extraData);
            Type ourType1 = Type(ENGINE.getMonValueForBattle(battleKey, playerIndex, switchMonIndex, MonStateIndexName.Type1));

            // Check if we resist their type
            uint256 effectiveness = TYPE_CALC.getTypeEffectiveness(opponentType1, ourType1, 2);
            if (effectiveness <= 1) {
                // We resist or are immune - good switch
                return int256(i);
            }
        }

        return -1;
    }

    // ============ MOVE SELECTION HELPERS ============

    function _selectLead(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 opponentIndex,
        MoveDecision memory opponentMove,
        RevealedMove[] memory switches
    ) internal returns (uint128, uint240) {
        Type opponentType1 = Type(ENGINE.getMonValueForBattle(battleKey, opponentIndex, uint256(opponentMove.extraData), MonStateIndexName.Type1));
        Type[] memory selfTypes = new Type[](switches.length);
        for (uint256 i = 0; i < switches.length; i++) {
            selfTypes[i] = Type(ENGINE.getMonValueForBattle(battleKey, playerIndex, uint256(switches[i].extraData), MonStateIndexName.Type1));
        }
        int256 bestIndex = _getTypeAdvantageOrNullToDefend(opponentType1, selfTypes);
        if (bestIndex != -1) {
            return (switches[uint256(bestIndex)].moveIndex, switches[uint256(bestIndex)].extraData);
        }
        uint256 rngIndex = _getRNG(battleKey) % switches.length;
        return (switches[rngIndex].moveIndex, switches[rngIndex].extraData);
    }

    function _selectBestSwitch(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 opponentIndex,
        uint256 opponentMonIndex,
        RevealedMove[] memory switches
    ) internal returns (uint128, uint240) {
        // Try to find a resistant switch
        int256 safeSwitch = _findSafeSwitch(battleKey, playerIndex, opponentIndex, opponentMonIndex, switches);
        if (safeSwitch >= 0) {
            return (switches[uint256(safeSwitch)].moveIndex, switches[uint256(safeSwitch)].extraData);
        }
        // Random fallback
        uint256 rngIndex = _getRNG(battleKey) % switches.length;
        return (switches[rngIndex].moveIndex, switches[rngIndex].extraData);
    }

    function _findHighestDamageMove(
        bytes32 battleKey,
        uint256 attackerIndex,
        uint256 attackerMonIndex,
        uint256 defenderIndex,
        uint256,
        Type defenderType1,
        Type defenderType2,
        RevealedMove[] memory moves,
        uint128[] memory attackMoveIndices
    ) internal view returns (int256) {
        DamageCalcContext memory ctx = ENGINE.getDamageCalcContext(battleKey, attackerIndex, defenderIndex);

        int256 bestMoveIndex = -1;
        uint256 bestDamage = 0;

        for (uint256 i = 0; i < attackMoveIndices.length; i++) {
            uint256 moveArrayIndex = uint256(attackMoveIndices[i]);
            IMoveSet moveSet = ENGINE.getMoveForMonForBattle(battleKey, attackerIndex, attackerMonIndex, moves[moveArrayIndex].moveIndex);
            MoveClass moveClass = moveSet.moveClass(battleKey);

            uint256 estimatedDamage = _estimateDamage(battleKey, ctx, moveSet, moveClass);
            if (estimatedDamage > bestDamage) {
                bestDamage = estimatedDamage;
                bestMoveIndex = int256(moveArrayIndex);
            }
        }

        // Fall back to type advantage if no damage estimate available
        if (bestMoveIndex == -1 && attackMoveIndices.length > 0) {
            uint128[] memory typeAdvantagedMoves = _getTypeAdvantageAttacks(battleKey, attackerIndex, attackerMonIndex, defenderType1, defenderType2, moves, attackMoveIndices);
            if (typeAdvantagedMoves.length > 0) {
                return int256(uint256(typeAdvantagedMoves[0]));
            }
            return int256(uint256(attackMoveIndices[0]));
        }

        return bestMoveIndex;
    }

    // ============ SHARED UTILITIES ============

    function _getRNG(bytes32 battleKey) internal returns (uint256) {
        return RNG.getRNG(keccak256(abi.encode(nonceToUse++, battleKey, block.timestamp)));
    }

    function _smartRandomSelect(bytes32 battleKey, RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches) internal returns (uint128, uint240) {
        uint256 rng = _getRNG(battleKey);
        uint256 movesLen = moves.length;
        uint256 adjustedTotalMovesDenom = movesLen + 1;

        if (rng % adjustedTotalMovesDenom == 0) {
            uint256 switchOrNoOp = (rng >> 8) % 2;
            if (switchOrNoOp == 0 && noOp.length > 0) {
                return (noOp[0].moveIndex, noOp[0].extraData);
            } else if (switches.length > 0) {
                uint256 rngSwitchIndex = (rng >> 16) % switches.length;
                return (switches[rngSwitchIndex].moveIndex, switches[rngSwitchIndex].extraData);
            }
        } else if (movesLen > 0) {
            uint256 moveIdx = (rng >> 8) % movesLen;
            return (moves[moveIdx].moveIndex, moves[moveIdx].extraData);
        }
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
        for (uint256 i = 0; i < moves.length; i++) {
            MoveClass currentMoveClass = ENGINE.getMoveForMonForBattle(battleKey, playerIndex, activeMonIndex, moves[i].moveIndex).moveClass(battleKey);
            if (currentMoveClass == class1 || currentMoveClass == class2) {
                validIndices[validCount++] = uint128(i);
            }
        }
        uint128[] memory result = new uint128[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            result[i] = validIndices[i];
        }
        return result;
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
        for (uint256 i = 0; i < validAttackIndices.length; i++) {
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
        uint128[] memory result = new uint128[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            result[i] = validIndices[i];
        }
        return result;
    }

    function _getTypeAdvantageOrNullToDefend(Type attackerType, Type[] memory defenderTypes) internal view returns (int256) {
        for (uint256 i = 0; i < defenderTypes.length; i++) {
            uint256 effectiveness = TYPE_CALC.getTypeEffectiveness(attackerType, defenderTypes[i], 2);
            if (effectiveness == 0 || effectiveness == 1) {
                return int256(i);
            }
        }
        return -1;
    }
}
