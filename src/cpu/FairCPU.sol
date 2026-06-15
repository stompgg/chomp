// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {CLEARED_MON_STATE_SENTINEL, SWITCH_MOVE_INDEX} from "../Constants.sol";
import {MonStateIndexName, MoveClass, Type} from "../Enums.sol";
import {IEngine} from "../IEngine.sol";
import {DamageCalcContext, MonStats, MoveMeta, RevealedMove} from "../Structs.sol";
import {MoveSlotLib} from "../moves/MoveSlotLib.sol";
import {ICPURNG} from "../rng/ICPURNG.sol";
import {ITypeCalculator} from "../types/ITypeCalculator.sol";
import {HeuristicCPUBase} from "./HeuristicCPUBase.sol";

/// @title FairCPU
/// @notice A heuristic CPU that does not peek at the player's current-turn revealed move.
///         All branches that BetterCPU keys on `playerMoveIndex`/`playerExtraData` are either
///         deleted (opp-switching, opp-resting, Diyu free-turn) or replaced with worst-case-
///         over-opp-pool variants (KO threat, defensive switch, lead selection).
contract FairCPU is HeuristicCPUBase {
    uint32 constant SWITCH_PRIORITY = 6;

    constructor(uint256 numMoves, IEngine engine, ICPURNG rng, ITypeCalculator typeCalc)
        HeuristicCPUBase(numMoves, engine, rng, typeCalc)
    {}

    // ============ CORE DECISION TREE ============

    function calculateMove(CPUContext memory ctx, uint8, /*playerMoveIndex*/ uint16 /*playerExtraData*/ )
        external
        override
        returns (uint128 moveIndex, uint16 extraData)
    {
        (
            RevealedMove[] memory noOp,
            RevealedMove[] memory moves,
            RevealedMove[] memory switches,
            MoveMeta[4] memory metas
        ) = _calculateValidMoves(ctx);

        bytes32 battleKey = ctx.battleKey;

        uint8 mode = uint8((playerState[ctx.p0] >> 8) & 0x3);
        bool aggressive = (mode == MODE_TARTARUS || mode == MODE_DIYU);
        bool diyu = (mode == MODE_DIYU);

        // Tartarus 1/10 chaos roll — same as BetterCPU.
        if (mode == MODE_TARTARUS) {
            uint256 rng = _getRNG(battleKey);
            if (rng % 10 == 0) {
                return _pickRandomValidOption(rng, noOp, moves, switches);
            }
        }

        // P0: Turn 0 — strict-fair lead (no peek at opp's chosen lead).
        if (ctx.turnId == 0) {
            (moveIndex, extraData) = _selectLeadFair(battleKey, ctx.p0TeamSize, ctx.p0KOBitmap, switches, aggressive);
            _clearMoveUsedBitsOnSwitchIn(battleKey, uint256(extraData));
            return (moveIndex, extraData);
        }

        uint256 activeMonIndex = ctx.p1ActiveMonIndex;
        // Fair view of opponent: their currently visible active mon. Never read playerExtraData.
        uint256 opponentMonIndex = ctx.p0ActiveMonIndex;

        // P1: KO'd — forced switch using worst-case sponge / best-matchup logic.
        if (ctx.cpuActiveMonKnockedOut) {
            (moveIndex, extraData) =
                _selectBestSwitchFair(battleKey, opponentMonIndex, switches, aggressive);
            _clearMoveUsedBitsOnSwitchIn(battleKey, uint256(extraData));
            return (moveIndex, extraData);
        }

        // Build opp's move metas once per turn — the unavoidable cost of fairness.
        MoveMeta[4] memory oppMetas = _loadOppMoveMetas(battleKey, opponentMonIndex);

        // Cache damage context (us → opponent) for our outgoing damages.
        DamageCalcContext memory attackCtx = ENGINE.getDamageCalcContext(battleKey, 1, 0);
        uint256[] memory damages = _computeMoveDamages(attackCtx, metas, moves);

        // Cache damage context (opp → us) for worst-case incoming damage (reused by P2 and P5).
        DamageCalcContext memory defendCtx = ENGINE.getDamageCalcContext(battleKey, 0, 1);
        uint256 worstIncomingDmg = _maxPoolDamage(defendCtx, oppMetas);

        // P2: Can we KO the opponent? Use raw-speed compare + opp max-priority to decide stay-in.
        int256 koMoveIdx = _findKOMove(battleKey, opponentMonIndex, metas, moves, damages);
        if (koMoveIdx >= 0) {
            bool opponentCanKOUs =
                _fairThreatensKO(battleKey, activeMonIndex, worstIncomingDmg);
            if (
                !opponentCanKOUs
                    || _fairWeGoFirst(
                        battleKey, metas, oppMetas, activeMonIndex, opponentMonIndex,
                        moves[uint256(koMoveIdx)].moveIndex
                    )
            ) {
                return (moves[uint256(koMoveIdx)].moveIndex, moves[uint256(koMoveIdx)].extraData);
            }
            // else: opp wins the race and threatens KO — fall through to P5.
        }

        // (No P3 opp-switching branch — would require peeking at playerMoveIndex.)
        // (No P4 opp-resting branch — same reason.)
        // (No P4.5 Diyu free-turn — same reason.)

        // P5: Defensive switch under worst-case incoming damage.
        if (switches.length > 0) {
            uint256 severeDamagePct = diyu
                ? SEVERE_DAMAGE_PCT_DIYU
                : (aggressive ? SEVERE_DAMAGE_PCT_TARTARUS : SEVERE_DAMAGE_PCT_HELL);
            // D3 KO-bypass (fair): in Diyu, if our best move would KO opp (≥90%) and we win the
            // raw-speed race (or have a strictly higher priority than opp's pool max), stay in.
            bool koBypassFires = diyu
                && moves.length > 0
                && _checkKOBypassFair(
                    battleKey, metas, oppMetas, activeMonIndex, opponentMonIndex, moves, damages
                );
            (bool shouldSwitch, uint256 switchIdx) = _evaluateDefensiveSwitchFair(
                battleKey, activeMonIndex, opponentMonIndex, oppMetas,
                worstIncomingDmg, switches, severeDamagePct, koBypassFires
            );
            if (shouldSwitch) {
                _clearMoveUsedBitsOnSwitchIn(battleKey, uint256(switches[switchIdx].extraData));
                return (switches[switchIdx].moveIndex, switches[switchIdx].extraData);
            }
        }

        // P6: Default — configured switch-in / preferred / best damage.
        if (moves.length > 0) {
            int256 switchInMove = _tryConfiguredMove(battleKey, activeMonIndex, moves, CONFIG_SWITCH_IN_MOVE, 0);
            if (switchInMove >= 0) {
                return (moves[uint256(switchInMove)].moveIndex, moves[uint256(switchInMove)].extraData);
            }

            int256 preferredMove = _tryPreferredMove(activeMonIndex, attackCtx, metas, moves);
            if (preferredMove >= 0) {
                return (moves[uint256(preferredMove)].moveIndex, moves[uint256(preferredMove)].extraData);
            }

            int256 bestMove = _findBestDamageMove(metas, moves, damages);
            if (bestMove >= 0) {
                return (moves[uint256(bestMove)].moveIndex, moves[uint256(bestMove)].extraData);
            }
        }

        // Stuck out of moves — switch (safest sponge, non-aggressive) or rest.
        if (switches.length > 0) {
            (moveIndex, extraData) = _selectBestSwitchFair(battleKey, opponentMonIndex, switches, false);
            _clearMoveUsedBitsOnSwitchIn(battleKey, uint256(extraData));
            return (moveIndex, extraData);
        }
        return (noOp[0].moveIndex, noOp[0].extraData);
    }

    // ============ OPP-POOL ANALYSIS ============

    /// @notice Decode all 4 of opp's move metas. Called once per fair turn; threaded as a
    ///         param to helpers so no helper re-fetches.
    function _loadOppMoveMetas(bytes32 battleKey, uint256 opponentMonIndex)
        internal
        view
        returns (MoveMeta[4] memory oppMetas)
    {
        for (uint256 i; i < 4;) {
            try ENGINE.getMoveForMonForBattle(battleKey, 0, opponentMonIndex, uint8(i)) returns (uint256 slot) {
                // Zero lane = the mon has no move at this index (fixed-lane team storage returns 0
                // instead of reverting like the old dynamic array did) — keep the default-zero meta.
                if (slot != 0) {
                    oppMetas[i] = MoveSlotLib.decodeMeta(slot, ENGINE, battleKey, 0, opponentMonIndex);
                }
            } catch {
                // Leave default-zero meta — basePower == 0 means it contributes nothing to damage.
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Max damage opp could deal to a defender given pre-computed `defendCtx` and metas.
    function _maxPoolDamage(DamageCalcContext memory defendCtx, MoveMeta[4] memory oppMetas)
        internal
        view
        returns (uint256 maxDmg)
    {
        for (uint256 i; i < 4;) {
            MoveMeta memory meta = oppMetas[i];
            if (meta.moveClass == MoveClass.Physical || meta.moveClass == MoveClass.Special) {
                uint256 dmg = _estimateDamageMeta(defendCtx, meta);
                if (dmg > maxDmg) maxDmg = dmg;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Max priority across opp's move pool. Used in fair speed-race compare.
    function _maxPoolPriority(MoveMeta[4] memory oppMetas) internal pure returns (uint32 maxPrio) {
        for (uint256 i; i < 4;) {
            // basePower==0 with class Self/Other still has a valid priority and can be played.
            // Include all slots that decoded (priority is 0 for default-zero meta entries, which
            // is the correct pessimistic floor).
            uint32 p = oppMetas[i].priority;
            if (p > maxPrio) maxPrio = p;
            unchecked {
                ++i;
            }
        }
    }

    // ============ FAIR KO / SPEED CHECKS ============

    /// @notice Worst-case threat check: is opp's max-pool damage ≥ our current HP?
    function _fairThreatensKO(bytes32 battleKey, uint256 playerMonIndex, uint256 worstIncomingDmg)
        internal
        view
        returns (bool)
    {
        uint32 ourBaseHp = ENGINE.getMonValueForBattle(battleKey, 1, playerMonIndex, MonStateIndexName.Hp);
        int32 ourHpDelta = ENGINE.getMonStateForBattle(battleKey, 1, playerMonIndex, MonStateIndexName.Hp);
        int256 ourCurrentHp = int256(uint256(ourBaseHp)) + int256(ourHpDelta);
        return ourCurrentHp > 0 && worstIncomingDmg >= uint256(ourCurrentHp);
    }

    /// @notice Speed-race compare under fair info. Our priority comes from the move we plan to
    ///         play. Opp's priority is the max across their pool (pessimistic — assume they pick
    ///         whichever move would let them outrun us).
    function _fairWeGoFirst(
        bytes32 battleKey,
        MoveMeta[4] memory metas,
        MoveMeta[4] memory oppMetas,
        uint256 ourMonIndex,
        uint256 opponentMonIndex,
        uint128 ourMoveIndex
    ) internal view returns (bool) {
        uint32 ourPriority = ourMoveIndex >= SWITCH_MOVE_INDEX ? SWITCH_PRIORITY : metas[ourMoveIndex].priority;
        uint32 oppPriorityMax = _maxPoolPriority(oppMetas);

        if (ourPriority > oppPriorityMax) return true;
        if (ourPriority < oppPriorityMax) return false;

        uint32 ourBaseSpeed = ENGINE.getMonValueForBattle(battleKey, 1, ourMonIndex, MonStateIndexName.Speed);
        int32 ourSpeedDelta = ENGINE.getMonStateForBattle(battleKey, 1, ourMonIndex, MonStateIndexName.Speed);
        if (ourSpeedDelta == CLEARED_MON_STATE_SENTINEL) ourSpeedDelta = 0;
        int256 ourSpeed = int256(uint256(ourBaseSpeed)) + int256(ourSpeedDelta);

        uint32 oppBaseSpeed = ENGINE.getMonValueForBattle(battleKey, 0, opponentMonIndex, MonStateIndexName.Speed);
        int32 oppSpeedDelta = ENGINE.getMonStateForBattle(battleKey, 0, opponentMonIndex, MonStateIndexName.Speed);
        if (oppSpeedDelta == CLEARED_MON_STATE_SENTINEL) oppSpeedDelta = 0;
        int256 oppSpeed = int256(uint256(oppBaseSpeed)) + int256(oppSpeedDelta);

        if (ourSpeed > oppSpeed) return true;
        return false; // Speed tie or slower → play it safe
    }

    /// @notice Diyu D3 KO-bypass under fair info. Same shape as BetterCPU's but uses
    ///         `_fairWeGoFirst` for the priority/speed race.
    function _checkKOBypassFair(
        bytes32 battleKey,
        MoveMeta[4] memory metas,
        MoveMeta[4] memory oppMetas,
        uint256 activeMonIndex,
        uint256 opponentMonIndex,
        RevealedMove[] memory moves,
        uint256[] memory damages
    ) internal view returns (bool) {
        int256 bestIdx = _findBestDamageMove(metas, moves, damages);
        if (bestIdx < 0) return false;

        uint256 bestDmg = damages[uint256(bestIdx)];
        if (bestDmg == 0) return false;

        uint32 oppMaxHp = ENGINE.getMonValueForBattle(battleKey, 0, opponentMonIndex, MonStateIndexName.Hp);
        int32 oppHpDelta = ENGINE.getMonStateForBattle(battleKey, 0, opponentMonIndex, MonStateIndexName.Hp);
        int256 oppCurrentHp = int256(uint256(oppMaxHp)) + int256(oppHpDelta);
        if (oppCurrentHp <= 0) return false;

        if (bestDmg * 10 < uint256(oppCurrentHp) * 9) return false;

        return _fairWeGoFirst(
            battleKey, metas, oppMetas, activeMonIndex, opponentMonIndex, moves[uint256(bestIdx)].moveIndex
        );
    }

    // ============ FAIR DEFENSIVE SWITCH ============

    /// @notice Evaluate every switch candidate against opp's worst-case-over-pool damage.
    ///         Switch when: (a) staying in is lethal AND a candidate survives worst-case, OR
    ///         (b) staying-in damage exceeds best candidate's by ≥ SWITCH_THRESHOLD.
    function _evaluateDefensiveSwitchFair(
        bytes32 battleKey,
        uint256 activeMonIndex,
        uint256 opponentMonIndex,
        MoveMeta[4] memory oppMetas,
        uint256 worstIncomingDmgToActive,
        RevealedMove[] memory switches,
        uint256 severeDamagePct,
        bool koBypassFires
    ) internal view returns (bool shouldSwitch, uint256 bestSwitchIdx) {
        if (koBypassFires) return (false, 0);

        uint256 damagePctToUs;
        bool lethalToUs;
        {
            uint32 ourMaxHp = ENGINE.getMonValueForBattle(battleKey, 1, activeMonIndex, MonStateIndexName.Hp);
            int32 ourHpDelta = ENGINE.getMonStateForBattle(battleKey, 1, activeMonIndex, MonStateIndexName.Hp);
            int256 ourCurrentHp = int256(uint256(ourMaxHp)) + int256(ourHpDelta);

            damagePctToUs = ourMaxHp > 0 ? (worstIncomingDmgToActive * 100) / uint256(ourMaxHp) : 0;
            lethalToUs = worstIncomingDmgToActive >= uint256(ourCurrentHp);

            if (damagePctToUs < severeDamagePct && !lethalToUs) return (false, 0);
        }

        uint256 bestDamagePct = type(uint256).max;
        bool bestSurvives = false;

        for (uint256 i; i < switches.length;) {
            uint256 candidateMonIndex = uint256(switches[i].extraData);
            DamageCalcContext memory ctx =
                _buildDamageCalcContext(battleKey, 0, opponentMonIndex, 1, candidateMonIndex);
            uint256 candWorst = _maxPoolDamage(ctx, oppMetas);

            uint32 maxHp = ENGINE.getMonValueForBattle(battleKey, 1, candidateMonIndex, MonStateIndexName.Hp);
            int32 hpDelta = ENGINE.getMonStateForBattle(battleKey, 1, candidateMonIndex, MonStateIndexName.Hp);
            int256 currentHp = int256(uint256(maxHp)) + int256(hpDelta);

            uint256 dmgPct = maxHp > 0 ? (candWorst * 100) / uint256(maxHp) : type(uint256).max >> 8;
            bool survives = candWorst < uint256(currentHp);

            if (dmgPct < bestDamagePct) {
                bestDamagePct = dmgPct;
                bestSwitchIdx = i;
                bestSurvives = survives;
            }
            unchecked {
                ++i;
            }
        }

        if (lethalToUs && bestSurvives) return (true, bestSwitchIdx);
        if (damagePctToUs >= bestDamagePct + SWITCH_THRESHOLD) return (true, bestSwitchIdx);

        return (false, 0);
    }

    // ============ FAIR SWITCH SELECTION ============

    /// @notice Forced-switch selection under fair info. Aggressive mode = best offensive matchup
    ///         (same as base). Non-aggressive = best worst-case sponge across opp's pool.
    function _selectBestSwitchFair(
        bytes32 battleKey,
        uint256 opponentMonIndex,
        RevealedMove[] memory switches,
        bool aggressive
    ) internal view returns (uint128, uint16) {
        if (aggressive) {
            MonStats memory oppStats = ENGINE.getMonStatsForBattle(battleKey, 0, opponentMonIndex);
            Type oppType1 = oppStats.type1;
            Type oppType2 = oppStats.type2;

            int256 bestScore = type(int256).min;
            uint256 bestIdx = 0;
            for (uint256 i; i < switches.length;) {
                MonStats memory candStats = ENGINE.getMonStatsForBattle(battleKey, 1, uint256(switches[i].extraData));
                int256 score = _offensiveMatchupScore(candStats.type1, candStats.type2, oppType1, oppType2);
                if (score > bestScore) {
                    bestScore = score;
                    bestIdx = i;
                }
                unchecked {
                    ++i;
                }
            }
            return (switches[bestIdx].moveIndex, switches[bestIdx].extraData);
        }

        // Non-aggressive: best worst-case sponge.
        MoveMeta[4] memory oppMetas = _loadOppMoveMetas(battleKey, opponentMonIndex);
        uint256 bestIdx2 = 0;
        uint256 leastWorst = type(uint256).max;
        for (uint256 i; i < switches.length;) {
            uint256 candidateMonIndex = uint256(switches[i].extraData);
            DamageCalcContext memory ctx =
                _buildDamageCalcContext(battleKey, 0, opponentMonIndex, 1, candidateMonIndex);
            uint256 candWorst = _maxPoolDamage(ctx, oppMetas);
            if (candWorst < leastWorst) {
                leastWorst = candWorst;
                bestIdx2 = i;
            }
            unchecked {
                ++i;
            }
        }
        return (switches[bestIdx2].moveIndex, switches[bestIdx2].extraData);
    }

    // ============ STRICT-FAIR LEAD SELECTION ============

    /// @notice Turn-0 lead: score each candidate against opp's full living team and aggregate.
    ///         No peek at opp's revealed lead. Aggregation uses the same offensive/defensive
    ///         scoring as base `_selectLead`, summed over all non-KO opp mons.
    function _selectLeadFair(
        bytes32 battleKey,
        uint8 oppTeamSize,
        uint8 oppKOBitmap,
        RevealedMove[] memory switches,
        bool aggressive
    ) internal view returns (uint128, uint16) {
        int256 bestScore = type(int256).min;
        uint256 bestIndex = 0;

        for (uint256 i; i < switches.length;) {
            MonStats memory candStats = ENGINE.getMonStatsForBattle(battleKey, 1, uint256(switches[i].extraData));
            int256 score = _scoreCandidateAgainstTeam(
                battleKey, candStats.type1, candStats.type2, oppTeamSize, oppKOBitmap, aggressive
            );
            if (score > bestScore) {
                bestScore = score;
                bestIndex = i;
            }
            unchecked {
                ++i;
            }
        }

        return (switches[bestIndex].moveIndex, switches[bestIndex].extraData);
    }

    /// @notice Sum offensive-minus-defensive scoring across every non-KO opp mon.
    function _scoreCandidateAgainstTeam(
        bytes32 battleKey,
        Type candType1,
        Type candType2,
        uint8 oppTeamSize,
        uint8 oppKOBitmap,
        bool aggressive
    ) internal view returns (int256 total) {
        for (uint256 j; j < oppTeamSize;) {
            if ((oppKOBitmap & (uint256(1) << j)) == 0) {
                MonStats memory oppStats = ENGINE.getMonStatsForBattle(battleKey, 0, j);
                Type oppType1 = oppStats.type1;
                Type oppType2 = oppStats.type2;

                int256 defensiveScore = int256(uint256(TYPE_CALC.getTypeEffectiveness(oppType1, candType1, 10)));
                if (candType2 != Type.None) {
                    defensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(oppType1, candType2, 10)));
                }
                if (oppType2 != Type.None) {
                    defensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(oppType2, candType1, 10)));
                    if (candType2 != Type.None) {
                        defensiveScore +=
                            int256(uint256(TYPE_CALC.getTypeEffectiveness(oppType2, candType2, 10)));
                    }
                }

                int256 offensiveScore = _offensiveMatchupScore(candType1, candType2, oppType1, oppType2);

                total += aggressive ? (3 * offensiveScore - defensiveScore) : (offensiveScore - defensiveScore);
            }
            unchecked {
                ++j;
            }
        }
    }
}
