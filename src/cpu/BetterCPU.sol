// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {CLEARED_MON_STATE_SENTINEL, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX} from "../Constants.sol";
import {MonStateIndexName, MoveClass, Type} from "../Enums.sol";
import {IEngine} from "../IEngine.sol";
import {CPUContext, DamageCalcContext, MoveMeta, RevealedMove} from "../Structs.sol";
import {MoveSlotLib} from "../moves/MoveSlotLib.sol";
import {ICPURNG} from "../rng/ICPURNG.sol";
import {ITypeCalculator} from "../types/ITypeCalculator.sol";
import {HeuristicCPUBase} from "./HeuristicCPUBase.sol";

/// @dev Packed params for switch evaluation to avoid stack-too-deep
struct SwitchEvalParams {
    uint256 playerIndex;
    uint256 opponentIndex;
    uint256 opponentMonIndex;
    uint256 oppMoveSlot;
    MoveClass oppMoveClass;
}

/// @title BetterCPU v2
/// @notice Heuristic-based CPU with kill threat detection, speed awareness,
///         defensive switch materiality, and per-mon strategy customization.
contract BetterCPU is HeuristicCPUBase {
    constructor(uint256 numMoves, IEngine engine, ICPURNG rng, ITypeCalculator typeCalc)
        HeuristicCPUBase(numMoves, engine, rng, typeCalc)
    {}

    // ============ CORE DECISION TREE ============

    function calculateMove(CPUContext memory ctx, uint8 playerMoveIndex, uint16 playerExtraData)
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

        // Tartarus 1/10 chaos roll: bypass the heuristic and pick uniformly across valid options.
        if (mode == MODE_TARTARUS) {
            uint256 rng = _getRNG(battleKey);
            if (rng % 10 == 0) {
                return _pickRandomValidOption(rng, noOp, moves, switches);
            }
        }

        // ══════════════════════════════════════════
        // P0: Turn 0 — Lead Selection
        // ══════════════════════════════════════════
        if (ctx.turnId == 0) {
            (moveIndex, extraData) = _selectLead(battleKey, playerExtraData, switches, aggressive);
            _clearMoveUsedBitsOnSwitchIn(battleKey, uint256(extraData));
            return (moveIndex, extraData);
        }

        uint256 activeMonIndex = ctx.p1ActiveMonIndex;
        uint256 opponentMonIndex = ctx.p0ActiveMonIndex;

        // ══════════════════════════════════════════
        // P1: KO'd — Forced Switch
        // ══════════════════════════════════════════
        if (ctx.cpuActiveMonKnockedOut) {
            (moveIndex, extraData) = _selectBestSwitch(battleKey, opponentMonIndex, playerMoveIndex, switches, aggressive);
            _clearMoveUsedBitsOnSwitchIn(battleKey, uint256(extraData));
            return (moveIndex, extraData);
        }

        // metas[] is now pre-built by `_calculateValidMoves` and reused here.

        // Resolve opponent target: if switching, target the incoming mon
        if (playerMoveIndex == SWITCH_MOVE_INDEX) {
            opponentMonIndex = uint256(playerExtraData);
        }

        // Cache damage context (us → opponent) — only valid for active mons
        DamageCalcContext memory attackCtx = ENGINE.getDamageCalcContext(battleKey, 1, 0);
        // Compute outgoing damages once and reuse across P2/P3/P4/P6/D3/D4.
        uint256[] memory damages = _computeMoveDamages(attackCtx, metas, moves);

        // ══════════════════════════════════════════
        // P2: Can We KO the Opponent?
        // ══════════════════════════════════════════
        int256 koMoveIdx = _findKOMove(battleKey, opponentMonIndex, metas, moves, damages);
        if (koMoveIdx >= 0) {
            bool opponentCanKOUs = _canOpponentKOUs(ctx, activeMonIndex, opponentMonIndex, playerMoveIndex);
            if (
                !opponentCanKOUs
                    || _weGoFirst(
                        ctx, metas, activeMonIndex, opponentMonIndex,
                        moves[uint256(koMoveIdx)].moveIndex, playerMoveIndex
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
            int256 switchInMove = _tryConfiguredMove(battleKey, activeMonIndex, moves, CONFIG_SWITCH_IN_MOVE, 0);
            if (switchInMove >= 0) {
                return (moves[uint256(switchInMove)].moveIndex, moves[uint256(switchInMove)].extraData);
            }
            if (moves.length > 0) {
                int256 bestMove = _findBestDamageMove(metas, moves, damages);
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
            int256 switchInMove = _tryConfiguredMove(battleKey, activeMonIndex, moves, CONFIG_SWITCH_IN_MOVE, 0);
            if (switchInMove >= 0) {
                return (moves[uint256(switchInMove)].moveIndex, moves[uint256(switchInMove)].extraData);
            }
            int256 bestMove = _findBestDamageMove(metas, moves, damages);
            if (bestMove >= 0) {
                return (moves[uint256(bestMove)].moveIndex, moves[uint256(bestMove)].extraData);
            }
            return (noOp[0].moveIndex, noOp[0].extraData);
        }

        // ══════════════════════════════════════════
        // P4.5: Diyu D4 free-turn — opp revealed a 0-power Self/Other move (setup, heal, hazard)
        // ══════════════════════════════════════════
        if (diyu && _isFreeTurnReveal(battleKey, opponentMonIndex, playerMoveIndex)) {
            (bool picked, uint128 freeM, uint16 freeE) = _diyuFreeTurnPick(ctx, metas, moves, switches, damages);
            if (picked) return (freeM, freeE);
        }

        // ══════════════════════════════════════════
        // P5: Opponent Using a Move — Evaluate Defensive Switch
        // ══════════════════════════════════════════
        if (switches.length > 0) {
            uint256 severeDamagePct = diyu
                ? SEVERE_DAMAGE_PCT_DIYU
                : (aggressive ? SEVERE_DAMAGE_PCT_TARTARUS : SEVERE_DAMAGE_PCT_HELL);
            // D3 KO-bypass: in Diyu, if our best move would KO opp (within ±10%) and we outspeed,
            // stay in for the kill regardless of incoming damage.
            bool koBypassFires = diyu
                && moves.length > 0
                && _checkKOBypass(ctx, battleKey, activeMonIndex, opponentMonIndex, metas, moves, damages, playerMoveIndex);
            (bool shouldSwitch, uint256 switchIdx) = _evaluateDefensiveSwitch(
                ctx, activeMonIndex, opponentMonIndex, playerMoveIndex, switches, severeDamagePct, koBypassFires
            );
            if (shouldSwitch) {
                _clearMoveUsedBitsOnSwitchIn(battleKey, uint256(switches[switchIdx].extraData));
                return (switches[switchIdx].moveIndex, switches[switchIdx].extraData);
            }
        }

        // ══════════════════════════════════════════
        // P6: Default — Best Damaging Move
        // ══════════════════════════════════════════
        if (moves.length > 0) {
            // Try switch-in move
            int256 switchInMove = _tryConfiguredMove(battleKey, activeMonIndex, moves, CONFIG_SWITCH_IN_MOVE, 0);
            if (switchInMove >= 0) {
                return (moves[uint256(switchInMove)].moveIndex, moves[uint256(switchInMove)].extraData);
            }

            // Check preferred move
            int256 preferredMove = _tryPreferredMove(activeMonIndex, attackCtx, metas, moves);
            if (preferredMove >= 0) {
                return (moves[uint256(preferredMove)].moveIndex, moves[uint256(preferredMove)].extraData);
            }

            int256 bestMove = _findBestDamageMove(metas, moves, damages);
            if (bestMove >= 0) {
                return (moves[uint256(bestMove)].moveIndex, moves[uint256(bestMove)].extraData);
            }
        }

        // No moves left — switch if possible, else rest. Stuck-out-of-moves is not a revenge
        // scenario; pass aggressive=false to keep the safest sponge.
        if (switches.length > 0) {
            (moveIndex, extraData) = _selectBestSwitch(battleKey, opponentMonIndex, playerMoveIndex, switches, false);
            _clearMoveUsedBitsOnSwitchIn(battleKey, uint256(extraData));
            return (moveIndex, extraData);
        }
        return (noOp[0].moveIndex, noOp[0].extraData);
    }

    // ============ SPEED / PRIORITY CHECK ============

    /// @notice Check if we go first (mirrors Engine.computePriorityPlayerIndex)
    function _weGoFirst(
        CPUContext memory cpuCtx,
        MoveMeta[4] memory metas,
        uint256 ourMonIndex,
        uint256 opponentMonIndex,
        uint128 ourMoveIndex,
        uint8 opponentMoveIndex
    ) internal view returns (bool) {
        bytes32 battleKey = cpuCtx.battleKey;
        // Get priorities — our priority comes from the pre-decoded metadata array.
        uint32 ourPriority;
        if (ourMoveIndex >= SWITCH_MOVE_INDEX) {
            ourPriority = 6; // SWITCH_PRIORITY
        } else {
            ourPriority = metas[ourMoveIndex].priority;
        }

        uint32 oppPriority;
        if (opponentMoveIndex >= SWITCH_MOVE_INDEX) {
            oppPriority = 6;
        } else {
            uint256 rawOppMove = ENGINE.getMoveForMonForBattle(battleKey, 0, opponentMonIndex, opponentMoveIndex);
            oppPriority = MoveSlotLib.priority(rawOppMove, ENGINE, battleKey, 0);
        }

        if (ourPriority > oppPriority) return true;
        if (ourPriority < oppPriority) return false;

        // Same priority — compare speeds
        uint32 ourBaseSpeed = ENGINE.getMonValueForBattle(battleKey, 1, ourMonIndex, MonStateIndexName.Speed);
        int32 ourSpeedDelta = ENGINE.getMonStateForBattle(battleKey, 1, ourMonIndex, MonStateIndexName.Speed);
        if (ourSpeedDelta == CLEARED_MON_STATE_SENTINEL) ourSpeedDelta = 0;
        int256 ourSpeed = int256(uint256(ourBaseSpeed)) + int256(ourSpeedDelta);

        uint32 oppBaseSpeed = ENGINE.getMonValueForBattle(battleKey, 0, opponentMonIndex, MonStateIndexName.Speed);
        int32 oppSpeedDelta = ENGINE.getMonStateForBattle(battleKey, 0, opponentMonIndex, MonStateIndexName.Speed);
        if (oppSpeedDelta == CLEARED_MON_STATE_SENTINEL) oppSpeedDelta = 0;
        int256 oppSpeed = int256(uint256(oppBaseSpeed)) + int256(oppSpeedDelta);

        if (ourSpeed > oppSpeed) return true;
        // Speed tie or slower → play it safe
        return false;
    }

    /// @notice Check if opponent's specific chosen move can KO our active mon
    function _canOpponentKOUs(
        CPUContext memory cpuCtx,
        uint256 playerMonIndex,
        uint256 opponentMonIndex,
        uint8 opponentMoveIndex
    ) internal view returns (bool) {
        if (opponentMoveIndex >= SWITCH_MOVE_INDEX) return false;

        bytes32 battleKey = cpuCtx.battleKey;
        uint256 oppMoveSlot;
        MoveClass oppMoveClass;
        try ENGINE.getMoveForMonForBattle(battleKey, 0, opponentMonIndex, opponentMoveIndex) returns (uint256 msRaw) {
            oppMoveSlot = msRaw;
            oppMoveClass = MoveSlotLib.moveClass(msRaw, ENGINE, battleKey);
        } catch {
            return false;
        }

        if (oppMoveClass != MoveClass.Physical && oppMoveClass != MoveClass.Special) return false;

        DamageCalcContext memory ctx = ENGINE.getDamageCalcContext(battleKey, 0, 1);
        uint256 estimatedDamage = _estimateDamage(ctx, battleKey, oppMoveSlot, oppMoveClass);

        uint32 ourBaseHp = ENGINE.getMonValueForBattle(battleKey, 1, playerMonIndex, MonStateIndexName.Hp);
        int32 ourHpDelta = ENGINE.getMonStateForBattle(battleKey, 1, playerMonIndex, MonStateIndexName.Hp);
        int256 ourCurrentHp = int256(uint256(ourBaseHp)) + int256(ourHpDelta);

        return estimatedDamage >= uint256(ourCurrentHp);
    }

    // ============ DEFENSIVE SWITCH EVALUATION ============

    /// @notice Diyu D3 KO-bypass check. True if our best damaging move would deal at least 90%
    ///         of opp's current HP and we outspeed — in which case we stay in for the kill
    ///         rather than swap out under heavy incoming damage.
    function _checkKOBypass(
        CPUContext memory ctx,
        bytes32 battleKey,
        uint256 activeMonIndex,
        uint256 opponentMonIndex,
        MoveMeta[4] memory metas,
        RevealedMove[] memory moves,
        uint256[] memory damages,
        uint8 playerMoveIndex
    ) internal view returns (bool) {
        int256 bestIdx = _findBestDamageMove(metas, moves, damages);
        if (bestIdx < 0) return false;

        uint256 bestDmg = damages[uint256(bestIdx)];
        if (bestDmg == 0) return false;

        uint32 oppMaxHp = ENGINE.getMonValueForBattle(battleKey, 0, opponentMonIndex, MonStateIndexName.Hp);
        int32 oppHpDelta = ENGINE.getMonStateForBattle(battleKey, 0, opponentMonIndex, MonStateIndexName.Hp);
        int256 oppCurrentHp = int256(uint256(oppMaxHp)) + int256(oppHpDelta);
        if (oppCurrentHp <= 0) return false;

        // ±10% tolerance: bestDmg >= 90% of opp current HP
        if (bestDmg * 10 < uint256(oppCurrentHp) * 9) return false;

        return _weGoFirst(
            ctx, metas, activeMonIndex, opponentMonIndex,
            moves[uint256(bestIdx)].moveIndex, playerMoveIndex
        );
    }

    /// @notice Estimate damage % and survival for a candidate switch-in, packed into one uint256
    ///         (damagePct in upper 248 bits, survives flag in bit 0). Packing keeps the caller's
    ///         loop stack footprint within via-IR limits while still returning both values.
    function _evaluateSwitchCandidate(bytes32 battleKey, SwitchEvalParams memory params, uint256 candidateMonIndex)
        internal
        view
        returns (uint256 packed)
    {
        DamageCalcContext memory ctx = _buildDamageCalcContext(
            battleKey, params.opponentIndex, params.opponentMonIndex, params.playerIndex, candidateMonIndex
        );
        uint256 dmg = _estimateDamage(ctx, battleKey, params.oppMoveSlot, params.oppMoveClass);

        uint32 maxHp =
            ENGINE.getMonValueForBattle(battleKey, params.playerIndex, candidateMonIndex, MonStateIndexName.Hp);
        int32 hpDelta =
            ENGINE.getMonStateForBattle(battleKey, params.playerIndex, candidateMonIndex, MonStateIndexName.Hp);
        int256 currentHp = int256(uint256(maxHp)) + int256(hpDelta);

        uint256 damagePct = maxHp > 0 ? (dmg * 100) / uint256(maxHp) : type(uint256).max >> 8;
        uint256 survivesBit = dmg < uint256(currentHp) ? 1 : 0;
        packed = (damagePct << 8) | survivesBit;
    }

    /// @notice Find the best switch candidate (least damage %)
    function _findBestSwitchCandidate(bytes32 battleKey, SwitchEvalParams memory params, RevealedMove[] memory switches)
        internal
        view
        returns (uint256 bestIdx, uint256 bestDamagePct, bool bestSurvives)
    {
        bestDamagePct = type(uint256).max;
        for (uint256 i; i < switches.length;) {
            uint256 packed = _evaluateSwitchCandidate(battleKey, params, uint256(switches[i].extraData));
            uint256 dmgPct = packed >> 8;
            if (dmgPct < bestDamagePct) {
                bestDamagePct = dmgPct;
                bestIdx = i;
                bestSurvives = (packed & 1) != 0;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Evaluate whether switching is materially better than staying. `severeDamagePct` is
    ///         the per-mode threshold (Hell/Tartarus/Diyu) — incoming damage below this is ignored
    ///         unless lethal. `koBypassFires` short-circuits the switch entirely (Diyu D3): we're
    ///         about to KO the opponent and outspeed, so it's worth eating the hit.
    function _evaluateDefensiveSwitch(
        CPUContext memory cpuCtx,
        uint256 activeMonIndex,
        uint256 opponentMonIndex,
        uint8 opponentMoveIndex,
        RevealedMove[] memory switches,
        uint256 severeDamagePct,
        bool koBypassFires
    ) internal view returns (bool shouldSwitch, uint256 bestSwitchIdx) {
        if (koBypassFires) return (false, 0);
        if (opponentMoveIndex >= SWITCH_MOVE_INDEX) return (false, 0);

        bytes32 battleKey = cpuCtx.battleKey;
        uint256 oppMoveSlot;
        MoveClass oppMoveClass;
        {
            try ENGINE.getMoveForMonForBattle(battleKey, 0, opponentMonIndex, opponentMoveIndex) returns (
                uint256 msRaw
            ) {
                oppMoveSlot = msRaw;
                oppMoveClass = MoveSlotLib.moveClass(msRaw, ENGINE, battleKey);
            } catch {
                return (false, 0);
            }
            if (oppMoveClass != MoveClass.Physical && oppMoveClass != MoveClass.Special) return (false, 0);
        }

        uint256 damagePctToUs;
        bool lethalToUs;
        {
            DamageCalcContext memory ctxToUs = ENGINE.getDamageCalcContext(battleKey, 0, 1);
            uint256 damageToUs = _estimateDamage(ctxToUs, battleKey, oppMoveSlot, oppMoveClass);

            uint32 ourMaxHp = ENGINE.getMonValueForBattle(battleKey, 1, activeMonIndex, MonStateIndexName.Hp);
            int32 ourHpDelta = ENGINE.getMonStateForBattle(battleKey, 1, activeMonIndex, MonStateIndexName.Hp);
            int256 ourCurrentHp = int256(uint256(ourMaxHp)) + int256(ourHpDelta);

            damagePctToUs = (damageToUs * 100) / uint256(ourMaxHp);
            lethalToUs = damageToUs >= uint256(ourCurrentHp);

            if (damagePctToUs < severeDamagePct && !lethalToUs) return (false, 0);
        }

        uint256 bestDamagePct;
        bool bestSurvives;
        (bestSwitchIdx, bestDamagePct, bestSurvives) = _findBestSwitchCandidate(
            battleKey,
            SwitchEvalParams({
                playerIndex: 1,
                opponentIndex: 0,
                opponentMonIndex: opponentMonIndex,
                oppMoveSlot: oppMoveSlot,
                oppMoveClass: oppMoveClass
            }),
            switches
        );

        // Materiality check
        if (lethalToUs && bestSurvives) return (true, bestSwitchIdx);
        if (damagePctToUs >= bestDamagePct + SWITCH_THRESHOLD) return (true, bestSwitchIdx);

        return (false, 0);
    }

    // ============ FREE-TURN DETECTION (Diyu) ============

    /// @notice Detect a "free turn" — opponent revealed a 0-power Self/Other move (setup, heal,
    ///         hazard). Diyu D4 trigger gate.
    function _isFreeTurnReveal(bytes32 battleKey, uint256 opponentMonIndex, uint8 playerMoveIndex)
        internal view returns (bool)
    {
        if (playerMoveIndex >= SWITCH_MOVE_INDEX) return false;
        try ENGINE.getMoveForMonForBattle(battleKey, 0, opponentMonIndex, playerMoveIndex) returns (uint256 slot) {
            MoveClass oppClass = MoveSlotLib.moveClass(slot, ENGINE, battleKey);
            if (oppClass != MoveClass.Other && oppClass != MoveClass.Self) return false;
            return _getMoveBasePower(slot, battleKey) == 0;
        } catch {
            return false;
        }
    }

    /// @notice Diyu D4 decision tree. Returns (picked, moveIndex, extraData). When `picked` is
    ///         false the caller should fall through to P5. Order: switch-in → 2HKO damage →
    ///         (momentum ? setup : matchup switch) → best damage fallback.
    function _diyuFreeTurnPick(
        CPUContext memory ctx,
        MoveMeta[4] memory metas,
        RevealedMove[] memory moves,
        RevealedMove[] memory switches,
        uint256[] memory damages
    ) internal returns (bool picked, uint128 moveIndex, uint16 extraData) {
        bytes32 battleKey = ctx.battleKey;
        uint256 activeMonIndex = ctx.p1ActiveMonIndex;
        uint256 opponentMonIndex = ctx.p0ActiveMonIndex;

        int256 switchInMove = _tryConfiguredMove(battleKey, activeMonIndex, moves, CONFIG_SWITCH_IN_MOVE, 0);
        if (switchInMove >= 0) {
            RevealedMove memory m = moves[uint256(switchInMove)];
            return (true, m.moveIndex, m.extraData);
        }

        int256 bestIdx = _findBestDamageMove(metas, moves, damages);
        if (bestIdx >= 0) {
            uint256 bestDmg = damages[uint256(bestIdx)];
            uint32 oppMaxHp = ENGINE.getMonValueForBattle(battleKey, 0, opponentMonIndex, MonStateIndexName.Hp);
            int32 oppHpDelta = ENGINE.getMonStateForBattle(battleKey, 0, opponentMonIndex, MonStateIndexName.Hp);
            int256 oppCurrentHp = int256(uint256(oppMaxHp)) + int256(oppHpDelta);
            // 2HKO uses opp current HP (not max), so a damaged opp is easier to finish.
            if (oppCurrentHp > 0 && bestDmg * 2 >= uint256(oppCurrentHp)) {
                RevealedMove memory m = moves[uint256(bestIdx)];
                return (true, m.moveIndex, m.extraData);
            }
        }

        if (_hasMomentum(ctx, battleKey)) {
            int256 setupMove = _tryConfiguredMove(battleKey, activeMonIndex, moves, CONFIG_SETUP_MOVE, 8);
            if (setupMove >= 0) {
                RevealedMove memory m = moves[uint256(setupMove)];
                return (true, m.moveIndex, m.extraData);
            }
        } else if (switches.length > 0) {
            int256 swIdx = _tryFreeTurnMatchupSwitch(battleKey, activeMonIndex, opponentMonIndex, switches);
            if (swIdx >= 0) {
                RevealedMove memory s = switches[uint256(swIdx)];
                _clearMoveUsedBitsOnSwitchIn(battleKey, uint256(s.extraData));
                return (true, s.moveIndex, s.extraData);
            }
        }

        if (bestIdx >= 0) {
            RevealedMove memory m = moves[uint256(bestIdx)];
            return (true, m.moveIndex, m.extraData);
        }

        return (false, 0, 0);
    }
}
