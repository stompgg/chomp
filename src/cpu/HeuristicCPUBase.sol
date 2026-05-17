// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {CLEARED_MON_STATE_SENTINEL, SWITCH_MOVE_INDEX} from "../Constants.sol";
import {MonStateIndexName, MoveClass, Type} from "../Enums.sol";
import {IEngine} from "../IEngine.sol";
import {CPUContext, DamageCalcContext, MonStats, MoveMeta, RevealedMove} from "../Structs.sol";
import {AttackCalculator} from "../moves/AttackCalculator.sol";
import {MoveSlotLib} from "../moves/MoveSlotLib.sol";
import {ICPURNG} from "../rng/ICPURNG.sol";
import {ITypeCalculator} from "../types/ITypeCalculator.sol";
import {CPU} from "./CPU.sol";

/// @notice Interface for moves that expose basePower (e.g., StandardAttack)
interface IAttackMove {
    function basePower(bytes32 battleKey) external view returns (uint32);
}

/// @title HeuristicCPUBase
/// @notice Shared strategy helpers and adaptive-mode state for heuristic CPUs.
///         Sub-contracts add their own `calculateMove` that composes these helpers.
///         BetterCPU layers foreknowledge-driven branches on top; FairCPU substitutes
///         worst-case-over-opp-pool variants and ignores the current-turn reveal.
abstract contract HeuristicCPUBase is CPU {
    ITypeCalculator public immutable TYPE_CALC;

    // Damage estimation constants
    uint256 constant SIMILAR_DAMAGE_THRESHOLD = 85; // 85% — moves within 15% are "similar"
    uint256 constant SWITCH_THRESHOLD = 30; // 30% HP difference needed to justify switching

    // Per-mode severe-damage thresholds (Hell/Tartarus/Diyu ladder). See STRONG_CPU.md.
    uint256 constant SEVERE_DAMAGE_PCT_HELL = 30;
    uint256 constant SEVERE_DAMAGE_PCT_TARTARUS = 50;
    uint256 constant SEVERE_DAMAGE_PCT_DIYU = 60;

    // Mode constants for the adaptive state machine
    uint8 constant MODE_HELL = 0;
    uint8 constant MODE_TARTARUS = 1;
    uint8 constant MODE_DIYU = 2;

    // Per-mon strategy config
    uint256 public constant CONFIG_PREFERRED_MOVE = 0;
    uint256 public constant CONFIG_SWITCH_IN_MOVE = 1;
    uint256 public constant CONFIG_SETUP_MOVE = 2;
    uint256 constant CONFIG_UNSET = type(uint256).max;

    // Per-mon config: monIndex → configKey → configValue
    mapping(uint256 => mapping(uint256 => uint256)) public monConfig;
    // Per-battle bitmap: bits 0-7 track switch-in move use per monIndex,
    //                    bits 8-15 track setup move use per monIndex.
    mapping(bytes32 => uint256) public cpuMoveUsedBitmap;

    // Per-human packed state controlling mode escalation.
    //   bits  8-9  : mode (0 HELL, 1 TARTARUS, 2 DIYU)
    //   bit  10    : diyuPriorLoss (CPU has lost once already in current DIYU stint)
    mapping(address => uint256) public playerState;

    constructor(uint256 numMoves, IEngine engine, ICPURNG rng, ITypeCalculator typeCalc) CPU(numMoves, engine, rng) {
        TYPE_CALC = typeCalc;
    }

    function setMonConfig(uint256 monIndex, uint256 key, uint256 value) external {
        monConfig[monIndex][key] = value;
    }

    // ============ ADAPTIVE STATE MACHINE ============

    /// @notice Update playerState[p0] based on battle outcome — Hell/Tartarus/Diyu ladder.
    ///         DIYU is sticky for one loss then resets; a DIYU win demotes to TARTARUS.
    function _recordResult(address p0, bool cpuWon) internal {
        uint256 state = playerState[p0];
        uint8 mode = uint8((state >> 8) & 0x3);
        bool diyuPriorLoss = ((state >> 10) & 0x1) != 0;

        uint8 newMode;
        bool newDiyuPriorLoss = false;

        if (mode == MODE_HELL) {
            newMode = cpuWon ? MODE_HELL : MODE_TARTARUS;
        } else if (mode == MODE_TARTARUS) {
            newMode = cpuWon ? MODE_HELL : MODE_DIYU;
        } else if (cpuWon) {
            newMode = MODE_TARTARUS;
        } else if (diyuPriorLoss) {
            newMode = MODE_HELL;
        } else {
            newMode = MODE_DIYU;
            newDiyuPriorLoss = true;
        }

        uint256 newState = (state & ~uint256(0x700))
            | (uint256(newMode) << 8)
            | (newDiyuPriorLoss ? (uint256(1) << 10) : 0);
        if (newState != state) playerState[p0] = newState;
    }

    function _afterTurn(bytes32, address p0, address winner) internal override {
        if (winner == address(0)) return; // battle ongoing
        _recordResult(p0, winner == address(this)); // CPU is p1
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
    function _estimateDamage(DamageCalcContext memory ctx, bytes32 battleKey, uint256 rawMoveSlot, MoveClass moveClass)
        internal
        view
        returns (uint256)
    {
        uint32 basePower;
        if (MoveSlotLib.isInline(rawMoveSlot)) {
            basePower = MoveSlotLib.basePower(rawMoveSlot, battleKey);
        } else {
            try IAttackMove(address(uint160(rawMoveSlot))).basePower(battleKey) returns (uint32 bp) {
                basePower = bp;
            } catch {
                return 0;
            }
        }
        if (basePower == 0) return 0;

        Type moveType = MoveSlotLib.moveType(rawMoveSlot, ENGINE, battleKey);
        // accuracy=100 (always hits), volatility=0 (no variance), rng=50, critRate=0
        (int32 damage,) =
            AttackCalculator._calculateDamageFromContext(TYPE_CALC, ctx, basePower, 100, 0, moveType, moveClass, 50, 0);
        return damage > 0 ? uint256(uint32(damage)) : 0;
    }

    /// @notice Variant of _estimateDamage that reads basePower / moveType / moveClass from a
    ///         pre-decoded MoveMeta — no metadata external calls in the hot path.
    function _estimateDamageMeta(DamageCalcContext memory ctx, MoveMeta memory meta)
        internal
        view
        returns (uint256)
    {
        if (meta.basePower == 0) return 0;
        (int32 damage,) = AttackCalculator._calculateDamageFromContext(
            TYPE_CALC, ctx, meta.basePower, 100, 0, meta.moveType, meta.moveClass, 50, 0
        );
        return damage > 0 ? uint256(uint32(damage)) : 0;
    }

    // ============ MOVE SELECTION HELPERS ============

    /// @notice Compute outgoing damage for every Physical/Special move. Built once per turn and
    ///         threaded through `_findKOMove` / `_findBestDamageMove` so they don't recompute.
    function _computeMoveDamages(
        DamageCalcContext memory ctx,
        MoveMeta[4] memory metas,
        RevealedMove[] memory moves
    ) internal view returns (uint256[] memory damages) {
        damages = new uint256[](moves.length);
        for (uint256 i; i < moves.length;) {
            MoveMeta memory meta = metas[moves[i].moveIndex];
            if (meta.moveClass == MoveClass.Physical || meta.moveClass == MoveClass.Special) {
                damages[i] = _estimateDamageMeta(ctx, meta);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Find a move that can KO the opponent (cheapest stamina among KO moves).
    ///         Damages are pre-computed by the caller via `_computeMoveDamages`.
    function _findKOMove(
        bytes32 battleKey,
        uint256 defenderMonIndex,
        MoveMeta[4] memory metas,
        RevealedMove[] memory moves,
        uint256[] memory damages
    ) internal view returns (int256) {
        uint32 defenderBaseHp = ENGINE.getMonValueForBattle(battleKey, 0, defenderMonIndex, MonStateIndexName.Hp);
        int32 defenderHpDelta = ENGINE.getMonStateForBattle(battleKey, 0, defenderMonIndex, MonStateIndexName.Hp);
        int256 defenderCurrentHp = int256(uint256(defenderBaseHp)) + int256(defenderHpDelta);
        if (defenderCurrentHp <= 0) return -1;

        int256 bestMoveIndex = -1;
        uint32 bestStaminaCost = type(uint32).max;

        for (uint256 i; i < moves.length;) {
            if (damages[i] >= uint256(defenderCurrentHp)) {
                uint32 stamina = metas[moves[i].moveIndex].stamina;
                if (stamina < bestStaminaCost) {
                    bestStaminaCost = stamina;
                    bestMoveIndex = int256(i);
                }
            }
            unchecked {
                ++i;
            }
        }
        return bestMoveIndex;
    }

    /// @notice Find best damaging move with stamina cost tiebreaking. Damages pre-computed.
    function _findBestDamageMove(
        MoveMeta[4] memory metas,
        RevealedMove[] memory moves,
        uint256[] memory damages
    ) internal pure returns (int256) {
        int256 bestMoveIndex = -1;
        uint256 bestDamage = 0;
        uint32 bestStaminaCost = type(uint32).max;

        for (uint256 i; i < moves.length;) {
            if (damages[i] > bestDamage) {
                bestDamage = damages[i];
                bestStaminaCost = metas[moves[i].moveIndex].stamina;
                bestMoveIndex = int256(i);
            }
            unchecked {
                ++i;
            }
        }

        if (bestDamage == 0) return bestMoveIndex;

        // Cheapest-stamina tiebreak within 85% of best damage.
        uint256 threshold = (bestDamage * SIMILAR_DAMAGE_THRESHOLD) / 100;
        for (uint256 i; i < moves.length;) {
            uint32 stamina = metas[moves[i].moveIndex].stamina;
            if (damages[i] >= threshold && stamina < bestStaminaCost) {
                bestStaminaCost = stamina;
                bestMoveIndex = int256(i);
            }
            unchecked {
                ++i;
            }
        }

        return bestMoveIndex;
    }

    // ============ LEAD SELECTION ============

    /// @notice Sum of type-effectiveness for both type pairs (candidate offense vs opponent defense).
    ///         Used by aggressive lead scoring, the Tartarus revenge-KO selector, and Diyu D1.
    function _offensiveMatchupScore(Type candType1, Type candType2, Type oppType1, Type oppType2)
        internal view returns (int256)
    {
        int256 score = int256(uint256(TYPE_CALC.getTypeEffectiveness(candType1, oppType1, 10)));
        if (oppType2 != Type.None) {
            score += int256(uint256(TYPE_CALC.getTypeEffectiveness(candType1, oppType2, 10)));
        }
        if (candType2 != Type.None) {
            score += int256(uint256(TYPE_CALC.getTypeEffectiveness(candType2, oppType1, 10)));
            if (oppType2 != Type.None) {
                score += int256(uint256(TYPE_CALC.getTypeEffectiveness(candType2, oppType2, 10)));
            }
        }
        return score;
    }

    /// @notice Select lead with dual-type scoring. `aggressive` weights offense more heavily,
    ///         producing offensive leads in TARTARUS/DIYU vs balanced/defensive in HELL.
    function _selectLead(
        bytes32 battleKey,
        uint16 opponentMonExtraData,
        RevealedMove[] memory switches,
        bool aggressive
    ) internal view returns (uint128, uint16) {
        MonStats memory oppStats = ENGINE.getMonStatsForBattle(battleKey, 0, uint256(opponentMonExtraData));
        Type oppType1 = oppStats.type1;
        Type oppType2 = oppStats.type2;

        int256 bestScore = type(int256).min;
        uint256 bestIndex = 0;

        for (uint256 i; i < switches.length;) {
            int256 score;
            {
                MonStats memory candStats = ENGINE.getMonStatsForBattle(battleKey, 1, uint256(switches[i].extraData));
                Type candType1 = candStats.type1;
                Type candType2 = candStats.type2;

                // Defensive: opp types attacking candidate.
                int256 defensiveScore = int256(uint256(TYPE_CALC.getTypeEffectiveness(oppType1, candType1, 10)));
                if (candType2 != Type.None) {
                    defensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(oppType1, candType2, 10)));
                }
                if (oppType2 != Type.None) {
                    defensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(oppType2, candType1, 10)));
                    if (candType2 != Type.None) {
                        defensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(oppType2, candType2, 10)));
                    }
                }

                // Offensive: candidate types attacking opp.
                int256 offensiveScore = int256(uint256(TYPE_CALC.getTypeEffectiveness(candType1, oppType1, 10)));
                if (oppType2 != Type.None) {
                    offensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(candType1, oppType2, 10)));
                }
                if (candType2 != Type.None) {
                    offensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(candType2, oppType1, 10)));
                    if (oppType2 != Type.None) {
                        offensiveScore += int256(uint256(TYPE_CALC.getTypeEffectiveness(candType2, oppType2, 10)));
                    }
                }

                score = aggressive
                    ? (3 * offensiveScore - defensiveScore)
                    : (offensiveScore - defensiveScore);
            }
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

    // ============ SWITCH SELECTION ============

    /// @notice Pick a switch candidate. In non-aggressive (HELL) mode, the safest sponge — least
    ///         damage taken from opp's revealed move. In aggressive mode (TARTARUS/DIYU revenge),
    ///         the best offensive matchup against the opponent's active mon.
    function _selectBestSwitch(
        bytes32 battleKey,
        uint256 opponentMonIndex,
        uint8 opponentMoveIndex,
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

        if (opponentMoveIndex >= SWITCH_MOVE_INDEX) {
            return (switches[0].moveIndex, switches[0].extraData);
        }

        uint256 oppMoveSlot;
        MoveClass oppMoveClass;
        bool canEstimate = false;
        try ENGINE.getMoveForMonForBattle(battleKey, 0, opponentMonIndex, opponentMoveIndex) returns (uint256 msRaw) {
            oppMoveSlot = msRaw;
            oppMoveClass = MoveSlotLib.moveClass(msRaw, ENGINE, battleKey);
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
            DamageCalcContext memory ctx = _buildDamageCalcContext(battleKey, 0, opponentMonIndex, 1, candidateMonIndex);
            uint256 dmg = _estimateDamage(ctx, battleKey, oppMoveSlot, oppMoveClass);
            if (dmg < leastDamage) {
                leastDamage = dmg;
                bestIdx = i;
            }
            unchecked {
                ++i;
            }
        }

        return (switches[bestIdx].moveIndex, switches[bestIdx].extraData);
    }

    // ============ PER-MON STRATEGY ============

    /// @notice Try to play a per-mon configured move (switch-in or setup), marking the
    ///         corresponding `cpuMoveUsedBitmap` lane bit. Returns -1 if unconfigured, already
    ///         used this switch-in, or absent from the available `moves`.
    function _tryConfiguredMove(
        bytes32 battleKey,
        uint256 activeMonIndex,
        RevealedMove[] memory moves,
        uint256 configKey,
        uint256 laneBitOffset
    ) internal returns (int256) {
        uint256 configValue = monConfig[activeMonIndex][configKey];
        if (configValue == 0) return -1;
        uint256 targetMoveIndex = configValue - 1;

        uint256 laneBit = uint256(1) << (activeMonIndex + laneBitOffset);
        if ((cpuMoveUsedBitmap[battleKey] & laneBit) != 0) return -1;

        for (uint256 i; i < moves.length;) {
            if (moves[i].moveIndex == targetMoveIndex) {
                cpuMoveUsedBitmap[battleKey] |= laneBit;
                return int256(i);
            }
            unchecked {
                ++i;
            }
        }
        return -1;
    }

    /// @notice Clear move-used bits on mon re-entry. Switch-in lane clears unconditionally;
    ///         setup lane clears only when current HP is strictly above 50% — a low-HP re-entry
    ///         shouldn't waste a turn setting up.
    function _clearMoveUsedBitsOnSwitchIn(bytes32 battleKey, uint256 monIdx) internal {
        uint256 bitmap = cpuMoveUsedBitmap[battleKey];
        uint256 setupBit = uint256(1) << (monIdx + 8);
        uint256 newBitmap = bitmap & ~(uint256(1) << monIdx);

        // Only fetch HP if the setup lane bit is actually set (skips two external calls per turn-0).
        if ((bitmap & setupBit) != 0) {
            uint32 maxHp = ENGINE.getMonValueForBattle(battleKey, 1, monIdx, MonStateIndexName.Hp);
            int32 hpDelta = ENGINE.getMonStateForBattle(battleKey, 1, monIdx, MonStateIndexName.Hp);
            int256 currentHp = int256(uint256(maxHp)) + int256(hpDelta);
            if (currentHp * 2 > int256(uint256(maxHp))) {
                newBitmap &= ~setupBit;
            }
        }

        if (newBitmap != bitmap) cpuMoveUsedBitmap[battleKey] = newBitmap;
    }

    /// @notice Extract basePower from a move slot, falling back to 0 for non-attack moves or
    ///         contracts that don't implement IAttackMove. Used by Diyu D4 free-turn detection.
    function _getMoveBasePower(uint256 rawMoveSlot, bytes32 battleKey) internal view returns (uint32) {
        if (MoveSlotLib.isInline(rawMoveSlot)) {
            return MoveSlotLib.basePower(rawMoveSlot, battleKey);
        }
        try IAttackMove(address(uint160(rawMoveSlot))).basePower(battleKey) returns (uint32 bp) {
            return bp;
        } catch {
            return 0;
        }
    }

    function _popcount8(uint8 bitmap) internal pure returns (uint256 count) {
        for (uint256 i; i < 8;) {
            if ((bitmap >> i) & 1 == 1) ++count;
            unchecked { ++i; }
        }
    }

    /// @notice Momentum check for Diyu D4 step 4. CPU has momentum if more mons alive, or — on
    ///         a tie — its active mon has at least as much stamina as the opponent's.
    function _hasMomentum(CPUContext memory ctx, bytes32 battleKey) internal view returns (bool) {
        uint256 ourAlive = ctx.p1TeamSize - _popcount8(ctx.p1KOBitmap);
        uint256 theirAlive = ctx.p0TeamSize - _popcount8(ctx.p0KOBitmap);
        if (ourAlive > theirAlive) return true;
        if (ourAlive < theirAlive) return false;

        int256 ourStam = int256(uint256(ctx.cpuActiveMonBaseStamina)) + int256(ctx.cpuActiveMonStaminaDelta);
        uint32 theirBase = ENGINE.getMonValueForBattle(battleKey, 0, ctx.p0ActiveMonIndex, MonStateIndexName.Stamina);
        int32 theirDelta = ENGINE.getMonStateForBattle(battleKey, 0, ctx.p0ActiveMonIndex, MonStateIndexName.Stamina);
        int256 theirStam = int256(uint256(theirBase)) + int256(theirDelta);
        return ourStam >= theirStam;
    }

    /// @notice Pick a switch candidate whose offensive matchup against the opponent's active
    ///         mon exceeds the current mon's by ≥ SWITCH_THRESHOLD. Returns -1 when no
    ///         candidate clears the bar (caller falls through to best-damage default).
    function _tryFreeTurnMatchupSwitch(
        bytes32 battleKey,
        uint256 activeMonIndex,
        uint256 opponentMonIndex,
        RevealedMove[] memory switches
    ) internal view returns (int256) {
        MonStats memory oppStats = ENGINE.getMonStatsForBattle(battleKey, 0, opponentMonIndex);
        int256 currentScore;
        {
            MonStats memory ourStats = ENGINE.getMonStatsForBattle(battleKey, 1, activeMonIndex);
            currentScore =
                _offensiveMatchupScore(ourStats.type1, ourStats.type2, oppStats.type1, oppStats.type2);
        }

        int256 bestScore = currentScore;
        int256 bestIdx = -1;
        for (uint256 i; i < switches.length;) {
            MonStats memory candStats = ENGINE.getMonStatsForBattle(battleKey, 1, uint256(switches[i].extraData));
            int256 score =
                _offensiveMatchupScore(candStats.type1, candStats.type2, oppStats.type1, oppStats.type2);
            if (score > bestScore) {
                bestScore = score;
                bestIdx = int256(i);
            }
            unchecked {
                ++i;
            }
        }

        if (bestIdx >= 0 && bestScore >= currentScore + int256(SWITCH_THRESHOLD)) {
            return bestIdx;
        }
        return -1;
    }

    /// @notice Try to use the preferred move if set and within damage threshold of best
    function _tryPreferredMove(
        uint256 activeMonIndex,
        DamageCalcContext memory ctx,
        MoveMeta[4] memory metas,
        RevealedMove[] memory moves
    ) internal view returns (int256) {
        uint256 configValue = monConfig[activeMonIndex][CONFIG_PREFERRED_MOVE];
        // Convention: store (moveIndex + 1), 0 = unset
        if (configValue == 0) return -1;
        uint256 targetMoveIndex = configValue - 1;

        // Find the preferred move and the best move
        int256 preferredIdx = -1;
        uint256 preferredDamage = 0;
        uint256 bestDamage = 0;

        for (uint256 i; i < moves.length;) {
            MoveMeta memory meta = metas[moves[i].moveIndex];
            if (meta.moveClass != MoveClass.Physical && meta.moveClass != MoveClass.Special) {
                unchecked {
                    ++i;
                }
                continue;
            }

            uint256 dmg = _estimateDamageMeta(ctx, meta);
            if (dmg > bestDamage) bestDamage = dmg;

            if (moves[i].moveIndex == targetMoveIndex) {
                preferredIdx = int256(i);
                preferredDamage = dmg;
            }
            unchecked {
                ++i;
            }
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
        return _sampleRNG(keccak256(abi.encode(nonceToUse++, battleKey, block.timestamp)));
    }

    /// @notice Pick uniformly across `noOp ++ moves ++ switches`. The Tartarus chaos roll uses
    ///         the high bits of `rng` for the index so the 1/10 trigger and the index don't
    ///         share entropy. `_calculateValidMoves` already filters by context, so the union
    ///         is the valid action set.
    function _pickRandomValidOption(
        uint256 rng,
        RevealedMove[] memory noOp,
        RevealedMove[] memory moves,
        RevealedMove[] memory switches
    ) internal pure returns (uint128, uint16) {
        uint256 total = noOp.length + moves.length + switches.length;
        uint256 idx = (rng >> 8) % total;
        if (idx < noOp.length) return (noOp[idx].moveIndex, noOp[idx].extraData);
        idx -= noOp.length;
        if (idx < moves.length) return (moves[idx].moveIndex, moves[idx].extraData);
        idx -= moves.length;
        return (switches[idx].moveIndex, switches[idx].extraData);
    }
}
