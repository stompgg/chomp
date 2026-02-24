// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";
import {ICPURNG} from "../rng/ICPURNG.sol";
import {CPU} from "./CPU.sol";
import {DamageCalcContext, MonStats, RevealedMove} from "../Structs.sol";
import {ITypeCalculator} from "../types/ITypeCalculator.sol";
import {MonStateIndexName, Type, MoveClass} from "../Enums.sol";
import {IMoveSet} from "../moves/IMoveSet.sol";
import {AttackCalculator} from "../moves/AttackCalculator.sol";
import {SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, CLEARED_MON_STATE_SENTINEL} from "../Constants.sol";

/// @notice Interface for moves that expose basePower (e.g., StandardAttack)
interface IAttackMove {
    function basePower(bytes32 battleKey) external view returns (uint32);
}

/// @dev Packed params for switch evaluation to avoid stack-too-deep
struct SwitchEvalParams {
    uint256 playerIndex;
    uint256 opponentIndex;
    uint256 opponentMonIndex;
    IMoveSet oppMoveSet;
    MoveClass oppMoveClass;
}

/// @title BetterCPU v2
/// @notice Heuristic-based CPU with kill threat detection, speed awareness,
///         defensive switch materiality, and per-mon strategy customization.
contract BetterCPU is CPU {
    ITypeCalculator public immutable TYPE_CALC;

    // Damage estimation constants
    uint256 constant SIMILAR_DAMAGE_THRESHOLD = 85; // 85% — moves within 15% are "similar"
    uint256 constant SEVERE_DAMAGE_PCT = 30; // 30% of max HP = "severe" damage threshold
    uint256 constant SWITCH_THRESHOLD = 30; // 30% HP difference needed to justify switching

    // Per-mon strategy config
    uint256 constant CONFIG_PREFERRED_MOVE = 0;
    uint256 constant CONFIG_SWITCH_IN_MOVE = 1;
    uint256 constant CONFIG_UNSET = type(uint256).max;

    // Per-mon config: monIndex → configKey → configValue
    mapping(uint256 => mapping(uint256 => uint256)) public monConfig;
    // Per-battle bitmap: tracks which mons have used their switch-in move
    mapping(bytes32 => uint256) public switchInMoveUsedBitmap;

    constructor(uint256 numMoves, IEngine engine, ICPURNG rng, ITypeCalculator typeCalc) CPU(numMoves, engine, rng) {
        TYPE_CALC = typeCalc;
    }

    function setMonConfig(uint256 monIndex, uint256 key, uint256 value) external {
        monConfig[monIndex][key] = value;
    }

    // ============ CORE DECISION TREE ============

    function calculateMove(bytes32 battleKey, uint256 playerIndex, uint8 playerMoveIndex, uint240 playerExtraData)
        external
        override
        returns (uint128 moveIndex, uint240 extraData)
    {
        (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches) =
            calculateValidMoves(battleKey, playerIndex);

        uint256 opponentIndex = playerIndex ^ 1;
        uint256 turnId = ENGINE.getTurnIdForBattleState(battleKey);

        // ══════════════════════════════════════════
        // P0: Turn 0 — Lead Selection
        // ══════════════════════════════════════════
        if (turnId == 0) {
            (moveIndex, extraData) = _selectLead(battleKey, playerIndex, opponentIndex, playerExtraData, switches);
            // Clear switch-in move bit for the mon we're sending in
            switchInMoveUsedBitmap[battleKey] &= ~(1 << uint256(extraData));
            return (moveIndex, extraData);
        }

        // Cache active mon indices
        uint256[] memory activeMonIndices = ENGINE.getActiveMonIndexForBattleState(battleKey);
        uint256 activeMonIndex = activeMonIndices[playerIndex];
        uint256 opponentMonIndex = activeMonIndices[opponentIndex];

        // ══════════════════════════════════════════
        // P1: KO'd — Forced Switch
        // ══════════════════════════════════════════
        int32 isKOed =
            ENGINE.getMonStateForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.IsKnockedOut);
        if (isKOed == 1) {
            (moveIndex, extraData) =
                _selectBestSwitch(battleKey, playerIndex, opponentIndex, opponentMonIndex, playerMoveIndex, switches);
            // Clear switch-in move bit for the mon we're switching to
            switchInMoveUsedBitmap[battleKey] &= ~(1 << uint256(extraData));
            return (moveIndex, extraData);
        }

        // Resolve opponent target: if switching, target the incoming mon
        if (playerMoveIndex == SWITCH_MOVE_INDEX) {
            opponentMonIndex = uint256(playerExtraData);
        }

        // Cache damage context (us → opponent) — only valid for active mons
        DamageCalcContext memory attackCtx = ENGINE.getDamageCalcContext(battleKey, playerIndex, opponentIndex);

        // ══════════════════════════════════════════
        // P2: Can We KO the Opponent?
        // ══════════════════════════════════════════
        int256 koMoveIdx =
            _findKOMove(battleKey, playerIndex, activeMonIndex, opponentIndex, opponentMonIndex, attackCtx, moves);
        if (koMoveIdx >= 0) {
            bool opponentCanKOUs = _canOpponentKOUs(
                battleKey, playerIndex, activeMonIndex, opponentIndex, opponentMonIndex, playerMoveIndex
            );
            if (
                !opponentCanKOUs
                    || _weGoFirst(
                        battleKey,
                        playerIndex,
                        activeMonIndex,
                        opponentIndex,
                        opponentMonIndex,
                        moves[uint256(koMoveIdx)].moveIndex,
                        playerMoveIndex
                    )
            ) {
                return (moves[uint256(koMoveIdx)].moveIndex, moves[uint256(koMoveIdx)].extraData);
            }
            // else: opponent outspeeds us and can KO — fall through to P5
        }

        // ══════════════════════════════════════════
        // P3: Opponent is Switching
        // ══════════════════════════════════════════
        if (playerMoveIndex == SWITCH_MOVE_INDEX) {
            // Try switch-in move on this safe turn
            int256 switchInMove = _trySwitchInMove(battleKey, playerIndex, activeMonIndex, moves);
            if (switchInMove >= 0) {
                return (moves[uint256(switchInMove)].moveIndex, moves[uint256(switchInMove)].extraData);
            }
            if (moves.length > 0) {
                int256 bestMove = _findBestDamageMove(battleKey, playerIndex, activeMonIndex, attackCtx, moves);
                if (bestMove >= 0) {
                    return (moves[uint256(bestMove)].moveIndex, moves[uint256(bestMove)].extraData);
                }
            }
            return (noOp[0].moveIndex, noOp[0].extraData); // Rest on free turn
        }

        // ══════════════════════════════════════════
        // P4: Opponent is Resting
        // ══════════════════════════════════════════
        if (playerMoveIndex == NO_OP_MOVE_INDEX) {
            if (moves.length == 0) {
                return (noOp[0].moveIndex, noOp[0].extraData); // Both rest
            }
            // Try switch-in move on this safe turn
            int256 switchInMove = _trySwitchInMove(battleKey, playerIndex, activeMonIndex, moves);
            if (switchInMove >= 0) {
                return (moves[uint256(switchInMove)].moveIndex, moves[uint256(switchInMove)].extraData);
            }
            int256 bestMove = _findBestDamageMove(battleKey, playerIndex, activeMonIndex, attackCtx, moves);
            if (bestMove >= 0) {
                return (moves[uint256(bestMove)].moveIndex, moves[uint256(bestMove)].extraData);
            }
            return (noOp[0].moveIndex, noOp[0].extraData);
        }

        // ══════════════════════════════════════════
        // P5: Opponent Using a Move — Evaluate Defensive Switch
        // ══════════════════════════════════════════
        if (switches.length > 0) {
            (bool shouldSwitch, uint256 switchIdx) = _evaluateDefensiveSwitch(
                battleKey, playerIndex, activeMonIndex, opponentIndex, opponentMonIndex, playerMoveIndex, switches
            );
            if (shouldSwitch) {
                // Clear switch-in move bit for the mon we're switching to
                switchInMoveUsedBitmap[battleKey] &= ~(1 << uint256(switches[switchIdx].extraData));
                return (switches[switchIdx].moveIndex, switches[switchIdx].extraData);
            }
        }

        // ══════════════════════════════════════════
        // P6: Default — Best Damaging Move
        // ══════════════════════════════════════════
        if (moves.length > 0) {
            // Try switch-in move
            int256 switchInMove = _trySwitchInMove(battleKey, playerIndex, activeMonIndex, moves);
            if (switchInMove >= 0) {
                return (moves[uint256(switchInMove)].moveIndex, moves[uint256(switchInMove)].extraData);
            }

            // Check preferred move
            int256 preferredMove = _tryPreferredMove(battleKey, playerIndex, activeMonIndex, attackCtx, moves);
            if (preferredMove >= 0) {
                return (moves[uint256(preferredMove)].moveIndex, moves[uint256(preferredMove)].extraData);
            }

            int256 bestMove = _findBestDamageMove(battleKey, playerIndex, activeMonIndex, attackCtx, moves);
            if (bestMove >= 0) {
                return (moves[uint256(bestMove)].moveIndex, moves[uint256(bestMove)].extraData);
            }
        }

        // No moves left — switch if possible, else rest
        if (switches.length > 0) {
            (moveIndex, extraData) =
                _selectBestSwitch(battleKey, playerIndex, opponentIndex, opponentMonIndex, playerMoveIndex, switches);
            switchInMoveUsedBitmap[battleKey] &= ~(1 << uint256(extraData));
            return (moveIndex, extraData);
        }
        return (noOp[0].moveIndex, noOp[0].extraData);
    }

    // ============ DAMAGE ESTIMATION ============

    /// @notice Build a DamageCalcContext for any attacker/defender pair (not just active mons)
    function _buildDamageCalcContext(
        bytes32 battleKey,
        uint256 attackerIndex,
        uint256 attackerMonIndex,
        uint256 defenderIndex,
        uint256 defenderMonIndex
    ) internal view returns (DamageCalcContext memory ctx) {
        MonStats memory attackerStats = ENGINE.getMonStatsForBattle(battleKey, attackerIndex, attackerMonIndex);
        MonStats memory defenderStats = ENGINE.getMonStatsForBattle(battleKey, defenderIndex, defenderMonIndex);

        ctx.attackerMonIndex = uint8(attackerMonIndex);
        ctx.defenderMonIndex = uint8(defenderMonIndex);

        // Attacker offensive stats
        ctx.attackerAttack = attackerStats.attack;
        int32 atkDelta =
            ENGINE.getMonStateForBattle(battleKey, attackerIndex, attackerMonIndex, MonStateIndexName.Attack);
        ctx.attackerAttackDelta = atkDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : atkDelta;

        ctx.attackerSpAtk = attackerStats.specialAttack;
        int32 spAtkDelta =
            ENGINE.getMonStateForBattle(battleKey, attackerIndex, attackerMonIndex, MonStateIndexName.SpecialAttack);
        ctx.attackerSpAtkDelta = spAtkDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : spAtkDelta;

        // Defender defensive stats
        ctx.defenderDef = defenderStats.defense;
        int32 defDelta =
            ENGINE.getMonStateForBattle(battleKey, defenderIndex, defenderMonIndex, MonStateIndexName.Defense);
        ctx.defenderDefDelta = defDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : defDelta;

        ctx.defenderSpDef = defenderStats.specialDefense;
        int32 spDefDelta =
            ENGINE.getMonStateForBattle(battleKey, defenderIndex, defenderMonIndex, MonStateIndexName.SpecialDefense);
        ctx.defenderSpDefDelta = spDefDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : spDefDelta;

        // Defender types
        ctx.defenderType1 = defenderStats.type1;
        ctx.defenderType2 = defenderStats.type2;
    }

    /// @notice Estimate damage using AttackCalculator with deterministic params
    function _estimateDamage(DamageCalcContext memory ctx, bytes32 battleKey, IMoveSet moveSet, MoveClass moveClass)
        internal
        view
        returns (uint256)
    {
        uint32 basePower;
        try IAttackMove(address(moveSet)).basePower(battleKey) returns (uint32 bp) {
            basePower = bp;
        } catch {
            return 0;
        }
        if (basePower == 0) return 0;

        Type moveType = moveSet.moveType(battleKey);
        // accuracy=100 (always hits), volatility=0 (no variance), rng=50, critRate=0
        (int32 damage,) =
            AttackCalculator._calculateDamageFromContext(TYPE_CALC, ctx, basePower, 100, 0, moveType, moveClass, 50, 0);
        return damage > 0 ? uint256(uint32(damage)) : 0;
    }

    // ============ MOVE SELECTION HELPERS ============

    /// @notice Find a move that can KO the opponent (cheapest stamina among KO moves)
    function _findKOMove(
        bytes32 battleKey,
        uint256 attackerIndex,
        uint256 attackerMonIndex,
        uint256 defenderIndex,
        uint256 defenderMonIndex,
        DamageCalcContext memory ctx,
        RevealedMove[] memory moves
    ) internal view returns (int256) {
        // Get defender's remaining HP
        uint32 defenderBaseHp =
            ENGINE.getMonValueForBattle(battleKey, defenderIndex, defenderMonIndex, MonStateIndexName.Hp);
        int32 defenderHpDelta =
            ENGINE.getMonStateForBattle(battleKey, defenderIndex, defenderMonIndex, MonStateIndexName.Hp);
        int256 defenderCurrentHp = int256(uint256(defenderBaseHp)) + int256(defenderHpDelta);
        if (defenderCurrentHp <= 0) return -1;

        int256 bestMoveIndex = -1;
        uint32 bestStaminaCost = type(uint32).max;

        for (uint256 i; i < moves.length;) {
            IMoveSet moveSet =
                ENGINE.getMoveForMonForBattle(battleKey, attackerIndex, attackerMonIndex, moves[i].moveIndex);
            MoveClass moveClass = moveSet.moveClass(battleKey);
            if (moveClass != MoveClass.Physical && moveClass != MoveClass.Special) {
                unchecked { ++i; }
                continue;
            }

            uint256 estimatedDamage = _estimateDamage(ctx, battleKey, moveSet, moveClass);
            if (estimatedDamage >= uint256(defenderCurrentHp)) {
                uint32 staminaCost = moveSet.stamina(battleKey, attackerIndex, attackerMonIndex);
                if (staminaCost < bestStaminaCost) {
                    bestStaminaCost = staminaCost;
                    bestMoveIndex = int256(i);
                }
            }
            unchecked { ++i; }
        }
        return bestMoveIndex;
    }

    /// @notice Find best damaging move with stamina cost tiebreaking
    function _findBestDamageMove(
        bytes32 battleKey,
        uint256 attackerIndex,
        uint256 attackerMonIndex,
        DamageCalcContext memory ctx,
        RevealedMove[] memory moves
    ) internal view returns (int256) {
        int256 bestMoveIndex = -1;
        uint256 bestDamage = 0;
        uint32 bestStaminaCost = type(uint32).max;

        // Cache damage and stamina in memory to avoid redundant external calls
        uint256[] memory damages = new uint256[](moves.length);
        uint32[] memory costs = new uint32[](moves.length);

        // First pass: compute + cache damage and stamina
        for (uint256 i; i < moves.length;) {
            IMoveSet moveSet =
                ENGINE.getMoveForMonForBattle(battleKey, attackerIndex, attackerMonIndex, moves[i].moveIndex);
            MoveClass moveClass = moveSet.moveClass(battleKey);
            if (moveClass == MoveClass.Physical || moveClass == MoveClass.Special) {
                damages[i] = _estimateDamage(ctx, battleKey, moveSet, moveClass);
                costs[i] = moveSet.stamina(battleKey, attackerIndex, attackerMonIndex);
                if (damages[i] > bestDamage) {
                    bestDamage = damages[i];
                    bestStaminaCost = costs[i];
                    bestMoveIndex = int256(i);
                }
            }
            unchecked { ++i; }
        }

        if (bestDamage == 0) return bestMoveIndex;

        // Second pass: scan cached arrays only (cheap memory reads)
        uint256 threshold = (bestDamage * SIMILAR_DAMAGE_THRESHOLD) / 100;
        for (uint256 i; i < moves.length;) {
            if (damages[i] >= threshold && costs[i] < bestStaminaCost) {
                bestStaminaCost = costs[i];
                bestMoveIndex = int256(i);
            }
            unchecked { ++i; }
        }

        return bestMoveIndex;
    }

    // ============ LEAD SELECTION ============

    /// @notice Select lead with dual-type scoring (defensive + offensive)
    function _selectLead(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 opponentIndex,
        uint240 opponentMonExtraData,
        RevealedMove[] memory switches
    ) internal returns (uint128, uint240) {
        MonStats memory oppStats =
            ENGINE.getMonStatsForBattle(battleKey, opponentIndex, uint256(opponentMonExtraData));
        Type oppType1 = oppStats.type1;
        Type oppType2 = oppStats.type2;

        int256 bestScore = type(int256).min;
        uint256 bestIndex = 0;

        for (uint256 i; i < switches.length;) {
            MonStats memory candidateStats =
                ENGINE.getMonStatsForBattle(battleKey, playerIndex, uint256(switches[i].extraData));
            Type candType1 = candidateStats.type1;
            Type candType2 = candidateStats.type2;

            // Defensive score: how much damage do opponent's types deal to us? (lower = better for us)
            // We use basePower=10 as a reference point
            int256 defensiveScore = 0;
            defensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(oppType1, candType1, 10)));
            if (candType2 != Type.None) {
                defensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(oppType1, candType2, 10)));
            }
            if (oppType2 != Type.None) {
                defensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(oppType2, candType1, 10)));
                if (candType2 != Type.None) {
                    defensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(oppType2, candType2, 10)));
                }
            }

            // Offensive score: can we hit them super-effectively? (higher = better)
            int256 offensiveScore = 0;
            offensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(candType1, oppType1, 10)));
            if (oppType2 != Type.None) {
                offensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(candType1, oppType2, 10)));
            }
            if (candType2 != Type.None) {
                offensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(candType2, oppType1, 10)));
                if (oppType2 != Type.None) {
                    offensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(candType2, oppType2, 10)));
                }
            }

            // Combined: higher offensive minus higher defensive = better
            int256 score = offensiveScore - defensiveScore;
            if (score > bestScore) {
                bestScore = score;
                bestIndex = i;
            }
            unchecked { ++i; }
        }

        return (switches[bestIndex].moveIndex, switches[bestIndex].extraData);
    }

    // ============ SWITCH SELECTION ============

    /// @notice Select switch candidate that takes least damage from opponent's move
    function _selectBestSwitch(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 opponentIndex,
        uint256 opponentMonIndex,
        uint8 opponentMoveIndex,
        RevealedMove[] memory switches
    ) internal view returns (uint128, uint240) {
        // If opponent isn't attacking, fall back to random
        if (opponentMoveIndex >= SWITCH_MOVE_INDEX) {
            return (switches[0].moveIndex, switches[0].extraData);
        }

        // Try to estimate damage from opponent's specific move to each candidate
        IMoveSet oppMoveSet;
        MoveClass oppMoveClass;
        bool canEstimate = false;
        try ENGINE.getMoveForMonForBattle(battleKey, opponentIndex, opponentMonIndex, opponentMoveIndex) returns (
            IMoveSet ms
        ) {
            oppMoveSet = ms;
            oppMoveClass = ms.moveClass(battleKey);
            canEstimate = (oppMoveClass == MoveClass.Physical || oppMoveClass == MoveClass.Special);
        } catch {
            canEstimate = false;
        }

        if (!canEstimate) {
            return (switches[0].moveIndex, switches[0].extraData);
        }

        uint256 bestIdx = 0;
        uint256 leastDamage = type(uint256).max;

        for (uint256 i; i < switches.length;) {
            uint256 candidateMonIndex = uint256(switches[i].extraData);
            DamageCalcContext memory ctx =
                _buildDamageCalcContext(battleKey, opponentIndex, opponentMonIndex, playerIndex, candidateMonIndex);
            uint256 dmg = _estimateDamage(ctx, battleKey, oppMoveSet, oppMoveClass);
            if (dmg < leastDamage) {
                leastDamage = dmg;
                bestIdx = i;
            }
            unchecked { ++i; }
        }

        return (switches[bestIdx].moveIndex, switches[bestIdx].extraData);
    }

    // ============ SPEED / PRIORITY CHECK ============

    /// @notice Check if we go first (mirrors Engine.computePriorityPlayerIndex)
    function _weGoFirst(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 ourMonIndex,
        uint256 opponentIndex,
        uint256 opponentMonIndex,
        uint128 ourMoveIndex,
        uint8 opponentMoveIndex
    ) internal view returns (bool) {
        // Get priorities
        uint32 ourPriority;
        if (ourMoveIndex >= SWITCH_MOVE_INDEX) {
            ourPriority = 6; // SWITCH_PRIORITY
        } else {
            IMoveSet ourMove = ENGINE.getMoveForMonForBattle(battleKey, playerIndex, ourMonIndex, ourMoveIndex);
            ourPriority = ourMove.priority(battleKey, playerIndex);
        }

        uint32 oppPriority;
        if (opponentMoveIndex >= SWITCH_MOVE_INDEX) {
            oppPriority = 6;
        } else {
            IMoveSet oppMove =
                ENGINE.getMoveForMonForBattle(battleKey, opponentIndex, opponentMonIndex, opponentMoveIndex);
            oppPriority = oppMove.priority(battleKey, opponentIndex);
        }

        if (ourPriority > oppPriority) return true;
        if (ourPriority < oppPriority) return false;

        // Same priority — compare speeds
        uint32 ourBaseSpeed = ENGINE.getMonValueForBattle(battleKey, playerIndex, ourMonIndex, MonStateIndexName.Speed);
        int32 ourSpeedDelta =
            ENGINE.getMonStateForBattle(battleKey, playerIndex, ourMonIndex, MonStateIndexName.Speed);
        if (ourSpeedDelta == CLEARED_MON_STATE_SENTINEL) ourSpeedDelta = 0;
        int256 ourSpeed = int256(uint256(ourBaseSpeed)) + int256(ourSpeedDelta);

        uint32 oppBaseSpeed =
            ENGINE.getMonValueForBattle(battleKey, opponentIndex, opponentMonIndex, MonStateIndexName.Speed);
        int32 oppSpeedDelta =
            ENGINE.getMonStateForBattle(battleKey, opponentIndex, opponentMonIndex, MonStateIndexName.Speed);
        if (oppSpeedDelta == CLEARED_MON_STATE_SENTINEL) oppSpeedDelta = 0;
        int256 oppSpeed = int256(uint256(oppBaseSpeed)) + int256(oppSpeedDelta);

        if (ourSpeed > oppSpeed) return true;
        // Speed tie or slower → play it safe
        return false;
    }

    /// @notice Check if opponent's specific chosen move can KO our active mon
    function _canOpponentKOUs(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 playerMonIndex,
        uint256 opponentIndex,
        uint256 opponentMonIndex,
        uint8 opponentMoveIndex
    ) internal view returns (bool) {
        if (opponentMoveIndex >= SWITCH_MOVE_INDEX) return false;

        IMoveSet oppMoveSet;
        MoveClass oppMoveClass;
        try ENGINE.getMoveForMonForBattle(battleKey, opponentIndex, opponentMonIndex, opponentMoveIndex) returns (
            IMoveSet ms
        ) {
            oppMoveSet = ms;
            oppMoveClass = ms.moveClass(battleKey);
        } catch {
            return false;
        }

        if (oppMoveClass != MoveClass.Physical && oppMoveClass != MoveClass.Special) return false;

        DamageCalcContext memory ctx = ENGINE.getDamageCalcContext(battleKey, opponentIndex, playerIndex);
        uint256 estimatedDamage = _estimateDamage(ctx, battleKey, oppMoveSet, oppMoveClass);

        uint32 ourBaseHp = ENGINE.getMonValueForBattle(battleKey, playerIndex, playerMonIndex, MonStateIndexName.Hp);
        int32 ourHpDelta = ENGINE.getMonStateForBattle(battleKey, playerIndex, playerMonIndex, MonStateIndexName.Hp);
        int256 ourCurrentHp = int256(uint256(ourBaseHp)) + int256(ourHpDelta);

        return estimatedDamage >= uint256(ourCurrentHp);
    }

    // ============ DEFENSIVE SWITCH EVALUATION ============

    /// @notice Estimate damage % and survival for a candidate switch-in
    function _evaluateSwitchCandidate(
        bytes32 battleKey,
        SwitchEvalParams memory params,
        uint256 candidateMonIndex
    ) internal view returns (uint256 damagePct, bool survives) {
        DamageCalcContext memory ctx = _buildDamageCalcContext(
            battleKey, params.opponentIndex, params.opponentMonIndex, params.playerIndex, candidateMonIndex
        );
        uint256 dmg = _estimateDamage(ctx, battleKey, params.oppMoveSet, params.oppMoveClass);

        uint32 maxHp =
            ENGINE.getMonValueForBattle(battleKey, params.playerIndex, candidateMonIndex, MonStateIndexName.Hp);
        int32 hpDelta =
            ENGINE.getMonStateForBattle(battleKey, params.playerIndex, candidateMonIndex, MonStateIndexName.Hp);
        int256 currentHp = int256(uint256(maxHp)) + int256(hpDelta);

        damagePct = maxHp > 0 ? (dmg * 100) / uint256(maxHp) : type(uint256).max;
        survives = dmg < uint256(currentHp);
    }

    /// @notice Find the best switch candidate (least damage %)
    function _findBestSwitchCandidate(
        bytes32 battleKey,
        SwitchEvalParams memory params,
        RevealedMove[] memory switches
    ) internal view returns (uint256 bestIdx, uint256 bestDamagePct, bool bestSurvives) {
        bestDamagePct = type(uint256).max;
        for (uint256 i; i < switches.length;) {
            (uint256 damagePctToCandidate, bool candidateSurvives) =
                _evaluateSwitchCandidate(battleKey, params, uint256(switches[i].extraData));
            if (damagePctToCandidate < bestDamagePct) {
                bestDamagePct = damagePctToCandidate;
                bestIdx = i;
                bestSurvives = candidateSurvives;
            }
            unchecked { ++i; }
        }
    }

    /// @notice Evaluate whether switching is materially better than staying
    function _evaluateDefensiveSwitch(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 activeMonIndex,
        uint256 opponentIndex,
        uint256 opponentMonIndex,
        uint8 opponentMoveIndex,
        RevealedMove[] memory switches
    ) internal view returns (bool shouldSwitch, uint256 bestSwitchIdx) {
        if (opponentMoveIndex >= SWITCH_MOVE_INDEX) return (false, 0);

        IMoveSet oppMoveSet;
        MoveClass oppMoveClass;
        {
            try ENGINE.getMoveForMonForBattle(battleKey, opponentIndex, opponentMonIndex, opponentMoveIndex) returns (
                IMoveSet ms
            ) {
                oppMoveSet = ms;
                oppMoveClass = ms.moveClass(battleKey);
            } catch {
                return (false, 0);
            }
            if (oppMoveClass != MoveClass.Physical && oppMoveClass != MoveClass.Special) return (false, 0);
        }

        uint256 damagePctToUs;
        bool lethalToUs;
        {
            DamageCalcContext memory ctxToUs = ENGINE.getDamageCalcContext(battleKey, opponentIndex, playerIndex);
            uint256 damageToUs = _estimateDamage(ctxToUs, battleKey, oppMoveSet, oppMoveClass);

            uint32 ourMaxHp = ENGINE.getMonValueForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.Hp);
            int32 ourHpDelta =
                ENGINE.getMonStateForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.Hp);
            int256 ourCurrentHp = int256(uint256(ourMaxHp)) + int256(ourHpDelta);

            damagePctToUs = (damageToUs * 100) / uint256(ourMaxHp);
            lethalToUs = damageToUs >= uint256(ourCurrentHp);

            if (damagePctToUs < SEVERE_DAMAGE_PCT && !lethalToUs) return (false, 0);
        }

        uint256 bestDamagePct;
        bool bestSurvives;
        (bestSwitchIdx, bestDamagePct, bestSurvives) = _findBestSwitchCandidate(
            battleKey,
            SwitchEvalParams({
                playerIndex: playerIndex,
                opponentIndex: opponentIndex,
                opponentMonIndex: opponentMonIndex,
                oppMoveSet: oppMoveSet,
                oppMoveClass: oppMoveClass
            }),
            switches
        );

        // Materiality check
        if (lethalToUs && bestSurvives) return (true, bestSwitchIdx);
        if (damagePctToUs >= bestDamagePct + SWITCH_THRESHOLD) return (true, bestSwitchIdx);

        return (false, 0);
    }

    // ============ PER-MON STRATEGY ============

    /// @notice Try to use the switch-in move if set and not yet used this switch-in
    function _trySwitchInMove(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 activeMonIndex,
        RevealedMove[] memory moves
    ) internal returns (int256) {
        uint256 configValue = monConfig[activeMonIndex][CONFIG_SWITCH_IN_MOVE];
        // Convention: stores (moveIndex + 1), 0 = unset
        if (configValue == 0) return -1;
        uint256 targetMoveIndex = configValue - 1;

        // Check if already used this switch-in
        if ((switchInMoveUsedBitmap[battleKey] & (1 << activeMonIndex)) != 0) return -1;

        // Find the move in the moves array
        for (uint256 i; i < moves.length;) {
            if (moves[i].moveIndex == targetMoveIndex) {
                // Mark as used
                switchInMoveUsedBitmap[battleKey] |= (1 << activeMonIndex);
                return int256(i);
            }
            unchecked { ++i; }
        }
        return -1;
    }

    /// @notice Try to use the preferred move if set and within damage threshold of best
    function _tryPreferredMove(
        bytes32 battleKey,
        uint256 attackerIndex,
        uint256 attackerMonIndex,
        DamageCalcContext memory ctx,
        RevealedMove[] memory moves
    ) internal view returns (int256) {
        uint256 configValue = monConfig[attackerMonIndex][CONFIG_PREFERRED_MOVE];
        // Convention: store (moveIndex + 1), 0 = unset
        if (configValue == 0) return -1;
        uint256 targetMoveIndex = configValue - 1;

        // Find the preferred move and the best move
        int256 preferredIdx = -1;
        uint256 preferredDamage = 0;
        uint256 bestDamage = 0;

        for (uint256 i; i < moves.length;) {
            IMoveSet moveSet =
                ENGINE.getMoveForMonForBattle(battleKey, attackerIndex, attackerMonIndex, moves[i].moveIndex);
            MoveClass moveClass = moveSet.moveClass(battleKey);
            if (moveClass != MoveClass.Physical && moveClass != MoveClass.Special) {
                unchecked { ++i; }
                continue;
            }

            uint256 dmg = _estimateDamage(ctx, battleKey, moveSet, moveClass);
            if (dmg > bestDamage) bestDamage = dmg;

            if (moves[i].moveIndex == targetMoveIndex) {
                preferredIdx = int256(i);
                preferredDamage = dmg;
            }
            unchecked { ++i; }
        }

        if (preferredIdx < 0) return -1;
        if (bestDamage == 0) return preferredIdx; // No damage reference, just use preferred

        // Check if preferred move is within threshold
        if (preferredDamage * 100 >= bestDamage * SIMILAR_DAMAGE_THRESHOLD) {
            return preferredIdx;
        }
        return -1;
    }

    // ============ UTILITY ============

    function _getRNG(bytes32 battleKey) internal returns (uint256) {
        return RNG.getRNG(keccak256(abi.encode(nonceToUse++, battleKey, block.timestamp)));
    }
}
