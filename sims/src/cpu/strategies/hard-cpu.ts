import { Hex } from '../hex';
import { MoveClass, MonStateIndexName } from '../../../../transpiler/ts-output/Enums';
import { moveSlotLib } from '../../../../transpiler/ts-output/moves/MoveSlotLib';
import { MoveMeta } from '../../../../transpiler/ts-output/Structs';
import { SWITCH_MOVE_INDEX, NO_OP_INDEX } from '../constants';
import {
  RevealedMove,
  moveSlot,
  monCurrentHp as currentHp,
  monCurrentSpeed,
} from '../engine-view';
import { BattleView } from '../battle-view';
import { BaseCpuStrategy, CpuMove, PlayerMove, StrategyState } from '../strategy';
import {
  SEVERE_DAMAGE_PCT_HELL,
  SWITCH_THRESHOLD,
  CONFIG_SWITCH_IN_MOVE,
  CONFIG_SETUP_MOVE,
  MonConfig,
  buildDamageCalcContext,
  estimateDamage,
  computeMoveDamages,
  findKOMove,
  findBestDamageMove,
  selectLead,
  selectBestSwitch,
  tryConfiguredMove,
  clearMoveUsedBitsOnSwitchIn,
  tryPreferredMove,
  getMoveBasePower,
  hasMomentum,
} from '../heuristic-shared';
import {
  antiWallSwitch,
  evScaleDamages,
  forkMeasureIncomingDamage,
  forkMeasureMoveDamages,
  forkScoreAction,
  pickEvalOverride,
  pickSimilarDamageMove,
  WALL_DAMAGE_PCT,
} from '../heuristic-native';

/**
 * HARD CPU — best-response with foreknowledge.
 *
 * A TS-native fork of the BetterCPU decision engine, frozen into ONE fixed policy. It PEEKS at the
 * human's already-revealed move (the off-chain CPU replies after the commit) and best-responds: KO if
 * we can and survive the race, defensive-switch on a real threat, else play the best damage.
 *
 * Relative to the BetterCPU HELL best-response baseline:
 *   - drops the Hell/Tartarus/Diyu mode ladder + the Tartarus chaos roll;
 *   - measures BOTH sides by STEPPING THE SIM instead of trusting the static model alone: its own
 *     damage (forkMeasureMoveDamages: max(static, measured), accuracy-EV-scaled) and the reveal's
 *     damage to it / to each switch candidate (forkMeasureIncomingDamage, static as the miss
 *     fallback) — variable-power moves, ability procs and switch-in effects all read true;
 *   - voids a zapped opponent's reveal (ShouldSkipTurn): the telegraphed action will never execute,
 *     so the whole tree plays the free turn against the mon that actually stays in;
 *   - folds in the >=90% near-KO bypass (stay in to finish a kill instead of switching away);
 *   - ADDS an anti-wall stalemate-breaker (P5.5): pivot out of a matchup our active mon can't damage,
 *     which the threat-based defensive switch misses;
 *   - runs the Diyu free-turn setup punishment (P4.5) always-on, made safe by dropping the matchup
 *     pivot and guarding setup behind momentum + a productive matchup (see freeTurnPick) — the
 *     unguarded original stalled whole games;
 *   - persists the configured-move lane bitmap across turns (StrategyState, keyed by battle) so setup
 *     fires once per switch-in like the on-chain cpuMoveUsedBitmap, not once per turn;
 *   - default damage picks sample the 85% similar-damage band instead of always cheapest-stamina, so
 *     the policy can't be scripted move-for-move across repeat games;
 *   - an eval-veto (pickEvalOverride) strips egregious single-turn blunders: the tree's pick stands
 *     unless a forked alternative beats it by more than a KO swing (EVAL_OVERRIDE_MARGIN).
 *
 * The CPU is ALWAYS p1; the opponent is p0.
 */

const CPU_PLAYER_INDEX = 1n;
const OPP_PLAYER_INDEX = 0n;

// SWITCH priority in the Engine's priority comparison.
const SWITCH_PRIORITY = 6;

/**
 * Per-mon setup-move config (the Diyu "free-turn" setup moves the free-turn + P3/P4/P6 logic uses).
 * Values follow the on-chain convention: stored as `moveIndex + 1` (0 / absent = unset). Only
 * CONFIG_SETUP_MOVE is configured; CONFIG_SWITCH_IN_MOVE / CONFIG_PREFERRED_MOVE are left unset (so
 * `tryConfiguredMove(CONFIG_SWITCH_IN_MOVE)` and `tryPreferredMove` are inert unless a caller supplies
 * more config).
 */
export const BETTER_CPU_MON_CONFIG: MonConfig = {
  1: { [CONFIG_SETUP_MOVE]: 2 }, // Inutia   -> Initialize     (slot 1)
  2: { [CONFIG_SETUP_MOVE]: 1 }, // Malalien -> Triple Think   (slot 0)
  3: { [CONFIG_SETUP_MOVE]: 2 }, // Iblivion -> Loop           (slot 1)
  6: { [CONFIG_SETUP_MOVE]: 2 }, // Pengym   -> Deadlift       (slot 1)
  7: { [CONFIG_SETUP_MOVE]: 3 }, // Embursa  -> Heat Beacon    (slot 2)
  9: { [CONFIG_SETUP_MOVE]: 3 }, // Aurox    -> Iron Wall      (slot 2)
  11: { [CONFIG_SETUP_MOVE]: 3 }, // Ekineki -> Nine Nine Nine (slot 2)
  12: { [CONFIG_SETUP_MOVE]: 1 }, // Nirvamma -> Hard Reset    (slot 0)
};

const RET = (m: RevealedMove): CpuMove => ({
  moveIndex: m.moveIndex,
  extraData: m.extraData,
});

// ---------------------------------------------------------------------------------------------
// metas — decode the active mon's four move-slot metas.
// ---------------------------------------------------------------------------------------------

/**
 * Decode the active mon's four move-slot metas exactly as `_calculateValidMoves` does. Reads the four
 * slots directly off the engine (slots past the mon's real move count read as undefined → 0n, which
 * decodes to a default all-zero meta — basePower 0, MoveClass.Physical(0) — harmless because those
 * padded slots never enter the `moves` bucket). Always-length-4 fixed array.
 */
function buildMetas(e: any, bk: Hex, activeMonIndex: number): MoveMeta[] {
  const metas: MoveMeta[] = new Array(4);
  for (let i = 0; i < 4; i++) {
    const slot = moveSlot(e, bk, CPU_PLAYER_INDEX, activeMonIndex, i) ?? 0n;
    metas[i] = moveSlotLib.decodeMeta(slot, e, bk, CPU_PLAYER_INDEX, BigInt(activeMonIndex));
  }
  return metas;
}

// ============ SPEED / PRIORITY CHECK ============

/**
 * `weGoFirst` — mirrors Engine.computePriorityPlayerIndex. Higher priority goes first; on a priority
 * tie the faster mon goes first; a speed tie or being slower returns false (play safe).
 */
function weGoFirst(
  e: any,
  bk: Hex,
  metas: MoveMeta[],
  ourMonIndex: number,
  opponentMonIndex: number,
  ourMoveIndex: number,
  opponentMoveIndex: number,
): boolean {
  // Our priority: SWITCH_PRIORITY for a switch, else the decoded meta priority.
  let ourPriority: number;
  if (ourMoveIndex >= SWITCH_MOVE_INDEX) {
    ourPriority = SWITCH_PRIORITY;
  } else {
    ourPriority = Number(metas[ourMoveIndex].priority);
  }

  // Opponent priority: SWITCH_PRIORITY for a switch, else read their raw slot.
  let oppPriority: number;
  if (opponentMoveIndex >= SWITCH_MOVE_INDEX) {
    oppPriority = SWITCH_PRIORITY;
  } else {
    const rawOppMove = e.getMoveForMonForBattle(bk, OPP_PLAYER_INDEX, BigInt(opponentMonIndex), BigInt(opponentMoveIndex));
    oppPriority = Number(moveSlotLib.priority(rawOppMove, e, bk, OPP_PLAYER_INDEX));
  }

  if (ourPriority > oppPriority) return true;
  if (ourPriority < oppPriority) return false;

  // Same priority: compare speeds (base + delta, sentinel already normalized).
  const ourSpeed = monCurrentSpeed(e, bk, CPU_PLAYER_INDEX, ourMonIndex);
  const oppSpeed = monCurrentSpeed(e, bk, OPP_PLAYER_INDEX, opponentMonIndex);

  if (ourSpeed > oppSpeed) return true;
  return false; // speed tie or slower => play it safe
}

/**
 * `canOpponentKOUs`: does the opponent's specific chosen move KO our active mon? `damageToUs` is the
 * pre-hoisted max(static, sim-measured) reveal damage — 0 for a switch/rest/harmless move, and real
 * for damaging utility moves the static class gate can't price.
 */
function canOpponentKOUs(
  e: any,
  bk: Hex,
  playerMonIndex: number,
  opponentMoveIndex: number,
  damageToUs: number,
): boolean {
  if (opponentMoveIndex >= SWITCH_MOVE_INDEX) return false;
  return damageToUs > 0 && damageToUs >= currentHp(e, bk, CPU_PLAYER_INDEX, playerMonIndex);
}

// ============ DEFENSIVE SWITCH EVALUATION ============

/**
 * `checkKOBypass`: true if our best damaging move would deal at least 90% of the opponent's CURRENT HP
 * (±10% tolerance) AND we outspeed — in which case we stay in for the kill rather than swap out under
 * heavy incoming damage.
 */
function checkKOBypass(
  e: any,
  bk: Hex,
  metas: MoveMeta[],
  activeMonIndex: number,
  opponentMonIndex: number,
  moves: RevealedMove[],
  damages: number[],
  playerMoveIndex: number,
): boolean {
  const bestIdx = findBestDamageMove(metas, moves, damages);
  if (bestIdx < 0) return false;

  const bestDmg = damages[bestIdx];
  if (bestDmg === 0) return false;

  const oppCurrentHp = currentHp(e, bk, OPP_PLAYER_INDEX, opponentMonIndex);
  if (oppCurrentHp <= 0) return false;

  // ±10% tolerance: bestDmg >= 90% of opp current HP (bestDmg*10 >= oppHp*9).
  if (bestDmg * 10 < oppCurrentHp * 9) return false;

  return weGoFirst(e, bk, metas, activeMonIndex, opponentMonIndex, moves[bestIdx].moveIndex, playerMoveIndex);
}

/**
 * `findBestSwitchCandidate`: among the switch candidates, find the one taking the LEAST damage % from
 * the opponent's move, returning its index, damage %, and a survives flag.
 */
function findBestSwitchCandidate(
  e: any,
  bk: Hex,
  opponentMonIndex: number,
  opponentMoveIndex: number,
  opponentExtraData: number,
  oppMoveSlot: bigint | undefined,
  oppMoveClass: MoveClass | undefined,
  switches: RevealedMove[],
  salt: bigint,
): { bestIdx: number; bestDamagePct: number; bestSurvives: boolean } {
  let bestIdx = 0;
  let bestDamagePct = Number.MAX_SAFE_INTEGER;
  let bestSurvives = false;

  for (let i = 0; i < switches.length; i++) {
    const candidateMonIndex = switches[i].extraData;
    // opp (active) attacking the candidate: static estimate when readable, raised by the sim-measured
    // entry damage (switch-in procs, variable-power moves the static model reads as 0).
    const canEstimate =
      oppMoveSlot !== undefined && (oppMoveClass === MoveClass.Physical || oppMoveClass === MoveClass.Special);
    const ctx = buildDamageCalcContext(e, bk, OPP_PLAYER_INDEX, opponentMonIndex, CPU_PLAYER_INDEX, candidateMonIndex);
    const dmg = Math.max(
      canEstimate ? estimateDamage(e, bk, ctx, oppMoveSlot!, oppMoveClass!) : 0,
      forkMeasureIncomingDamage(e, bk, opponentMoveIndex, opponentExtraData, candidateMonIndex, salt),
    );

    const maxHp = Number(e.getMonValueForBattle(bk, CPU_PLAYER_INDEX, BigInt(candidateMonIndex), MonStateIndexName.Hp));
    const curHp = currentHp(e, bk, CPU_PLAYER_INDEX, candidateMonIndex);

    // packed damagePct + survives bit; maxHp==0 => a huge sentinel pct.
    const damagePct = maxHp > 0 ? Math.floor((dmg * 100) / maxHp) : Number.MAX_SAFE_INTEGER;
    const survives = dmg < curHp;

    if (damagePct < bestDamagePct) {
      bestDamagePct = damagePct;
      bestIdx = i;
      bestSurvives = survives;
    }
  }
  return { bestIdx, bestDamagePct, bestSurvives };
}

/**
 * `evaluateDefensiveSwitch`. `severeDamagePct` is the damage threshold below which incoming damage is
 * ignored unless lethal. `koBypassFires` short-circuits (about to KO + outspeed => eat the hit). Takes
 * the pre-hoisted opp-threat computation (oppMoveSlot / oppMoveClass / ctxToUs / damageToUs) so they
 * aren't recomputed against P2. Returns `{ shouldSwitch, switchIdx }`.
 */
function evaluateDefensiveSwitch(
  e: any,
  bk: Hex,
  activeMonIndex: number,
  opponentMonIndex: number,
  opponentMoveIndex: number,
  opponentExtraData: number,
  switches: RevealedMove[],
  severeDamagePct: number,
  koBypassFires: boolean,
  oppMoveSlot: bigint | undefined,
  oppMoveClass: MoveClass | undefined,
  damageToUs: number,
  salt: bigint,
): { shouldSwitch: boolean; switchIdx: number } {
  if (koBypassFires) return { shouldSwitch: false, switchIdx: 0 };
  if (opponentMoveIndex >= SWITCH_MOVE_INDEX) return { shouldSwitch: false, switchIdx: 0 };

  // No threat estimated OR measured => never switch defensively.
  if (damageToUs <= 0) return { shouldSwitch: false, switchIdx: 0 };

  // damage % to our active mon + lethality; bail if not severe and not lethal.
  const ourMaxHp = Number(e.getMonValueForBattle(bk, CPU_PLAYER_INDEX, BigInt(activeMonIndex), MonStateIndexName.Hp));
  const ourCurHp = currentHp(e, bk, CPU_PLAYER_INDEX, activeMonIndex);

  const damagePctToUs = Math.floor((damageToUs * 100) / ourMaxHp);
  const lethalToUs = damageToUs >= ourCurHp;

  if (damagePctToUs < severeDamagePct && !lethalToUs) return { shouldSwitch: false, switchIdx: 0 };

  // Find the safest switch-in.
  const { bestIdx, bestDamagePct, bestSurvives } = findBestSwitchCandidate(
    e, bk, opponentMonIndex, opponentMoveIndex, opponentExtraData, oppMoveSlot, oppMoveClass, switches, salt,
  );

  // Materiality check.
  if (lethalToUs && bestSurvives) return { shouldSwitch: true, switchIdx: bestIdx };
  if (damagePctToUs >= bestDamagePct + SWITCH_THRESHOLD) return { shouldSwitch: true, switchIdx: bestIdx };
  return { shouldSwitch: false, switchIdx: 0 };
}

// ============ FREE-TURN DETECTION ============

/**
 * `isFreeTurnReveal`: opponent revealed a 0-power Self/Other move (setup, heal, hazard) — the
 * free-turn punishment trigger gate.
 */
function isFreeTurnReveal(e: any, bk: Hex, opponentMonIndex: number, playerMoveIndex: number): boolean {
  if (playerMoveIndex >= SWITCH_MOVE_INDEX) return false;
  try {
    const slot = e.getMoveForMonForBattle(bk, OPP_PLAYER_INDEX, BigInt(opponentMonIndex), BigInt(playerMoveIndex));
    const oppClass = moveSlotLib.moveClass(slot, e, bk) as MoveClass;
    // Only Other / Self moves qualify.
    if (oppClass !== MoveClass.Other && oppClass !== MoveClass.Self) return false;
    return getMoveBasePower(e, bk, slot) === 0;
  } catch {
    return false;
  }
}

/**
 * `freeTurnPick` (free-turn punishment decision tree). Order: configured switch-in move -> 2HKO damage
 * move -> guarded configured setup move. Returns `{ picked, move, moveUsedBitmap }`; when `picked` is
 * false the caller falls through to P5.
 *
 * Two deliberate departures from the Diyu original keep this safe to run always-on (the old always-on
 * version stalled whole games): the free-turn matchup PIVOT is dropped (trading tempo on every
 * telegraphed free turn is what steered games into stalemates; a true wall is P5.5's job), and the
 * setup branch only fires when the active mon can actually damage the opponent — setting up in front
 * of something we can't hurt converts the free turn into a stall of our own.
 */
function freeTurnPick(
  view: BattleView,
  config: MonConfig,
  moveUsedBitmap: number,
  metas: MoveMeta[],
  moves: RevealedMove[],
  damages: number[],
): { picked: boolean; move?: RevealedMove; moveUsedBitmap: number } {
  const e = view.engine;
  const bk = view.bk as Hex;
  const activeMonIndex = view.cpuActive;
  const opponentMonIndex = view.oppActive;

  // Configured switch-in move on this safe turn.
  let res = tryConfiguredMove(config, moveUsedBitmap, activeMonIndex, moves, CONFIG_SWITCH_IN_MOVE, 0);
  moveUsedBitmap = res.usedBitmap;
  if (res.index >= 0) return { picked: true, move: moves[res.index], moveUsedBitmap };

  const bestIdx = findBestDamageMove(metas, moves, damages);
  const bestDmg = bestIdx >= 0 ? damages[bestIdx] : 0;
  const oppCurrentHp = currentHp(e, bk, OPP_PLAYER_INDEX, opponentMonIndex);
  // 2HKO uses opp CURRENT HP (a damaged opp is easier to finish).
  if (bestIdx >= 0 && oppCurrentHp > 0 && bestDmg * 2 >= oppCurrentHp) {
    return { picked: true, move: moves[bestIdx], moveUsedBitmap };
  }

  // Setup only with momentum AND a matchup we can actually make progress in.
  const productive = oppCurrentHp > 0 && bestDmg * 100 >= oppCurrentHp * WALL_DAMAGE_PCT;
  if (
    productive &&
    hasMomentum(e, bk, view.mons.p1.length, view.cpuKO, view.mons.p0.length, view.oppKO, view.oppActive, view.mons.p1[view.cpuActive].stamina)
  ) {
    res = tryConfiguredMove(config, moveUsedBitmap, activeMonIndex, moves, CONFIG_SETUP_MOVE, 8);
    moveUsedBitmap = res.usedBitmap;
    if (res.index >= 0) return { picked: true, move: moves[res.index], moveUsedBitmap };
  }

  // No best-damage flail — fall through to P5/P6.
  return { picked: false, moveUsedBitmap };
}

// ---------------------------------------------------------------------------------------------
// HardCpu — one fixed deterministic best-response + setup-punishment policy.
// ---------------------------------------------------------------------------------------------

export class HardCpu extends BaseCpuStrategy {
  readonly name = 'Hard (best-response + setup punishment)';

  override decide(view: BattleView, pm: PlayerMove, rng: () => number, state: StrategyState): CpuMove {
    const e = view.engine;
    const bk = view.bk as Hex;

    // PEEK at the player's revealed move (we reply after the commit).
    let playerMoveIndex = pm.moveIndex;
    const playerExtraData = pm.extraData;

    // Configured-move lane bits persist across turns per battle (the on-chain cpuMoveUsedBitmap
    // semantics) so a setup move fires once per switch-in, not once per free turn. Every return goes
    // through DONE to write the bitmap back.
    const bitmaps = (state['moveUsedBitmap'] ??= {}) as Record<string, number>;
    let moveUsedBitmap = bitmaps[bk] ?? 0;
    const DONE = (m: RevealedMove, phase: string): CpuMove => {
      bitmaps[bk] = moveUsedBitmap;
      state['lastPhase'] = phase; // decision-phase trace (read by the arena analyzer)
      return RET(m);
    };
    // Single fixed policy: HELL severe-damage threshold, no mode branch.
    const severeDamagePct = SEVERE_DAMAGE_PCT_HELL;

    // Enumerate valid options (the shared candidate buckets), and decode the active mon's metas.
    const { noOp, moves, switches } = this.validMoves(e, bk, rng);
    const metas = buildMetas(e, bk, view.cpuActive);

    // ── P0: Turn 0 — Lead Selection ── (a restarted/replayed battle reuses its key: reset the bitmap)
    if (Number(e.getTurnIdForBattleState(bk)) === 0) {
      moveUsedBitmap = 0;
      const lead = selectLead(e, bk, playerExtraData, switches, false);
      moveUsedBitmap = clearMoveUsedBitsOnSwitchIn(e, bk, moveUsedBitmap, lead.extraData);
      return DONE(lead, 'P0-lead');
    }

    const activeMonIndex = view.cpuActive;
    let opponentMonIndex = view.oppActive;

    // A zapped opponent (ShouldSkipTurn) loses its revealed action entirely — switch included. The
    // reveal is VOID: treat it as a rest so the whole tree plays the free turn against the mon that
    // actually stays in, instead of best-responding to a move that will never execute.
    if (view.mons.p0[view.oppActive].skipTurn) {
      playerMoveIndex = NO_OP_INDEX;
    }

    // ── P1: KO'd / Swap-Out Effect — Forced Switch ── (with no valid target — sole survivor already
    // active — the engine accepts a rest)
    if (view.switchFlag === 1 || view.mons.p1[view.cpuActive].ko) {
      if (switches.length === 0) return DONE({ moveIndex: NO_OP_INDEX, extraData: 0 }, 'P1-forced-switch');
      const sw = selectBestSwitch(e, bk, opponentMonIndex, playerMoveIndex, switches, false);
      moveUsedBitmap = clearMoveUsedBitsOnSwitchIn(e, bk, moveUsedBitmap, sw.extraData);
      return DONE(sw, 'P1-forced-switch');
    }

    // If the opponent is switching, target the incoming mon.
    if (playerMoveIndex === SWITCH_MOVE_INDEX) {
      opponentMonIndex = playerExtraData;
    }

    // Outgoing damage = max(static model, sim-measured). The static estimate keeps the always-hit
    // floor (a fork's fixed-salt accuracy roll can miss); the fork measurement sees everything the
    // model can't — variable-power moves, ability procs, the actual post-switch defender. The static
    // context getter always builds against CURRENT actives, so on a revealed switch rebuild against
    // the INCOMING defender.
    const attackCtx =
      playerMoveIndex === SWITCH_MOVE_INDEX
        ? buildDamageCalcContext(e, bk, CPU_PLAYER_INDEX, activeMonIndex, OPP_PLAYER_INDEX, opponentMonIndex)
        : e.getDamageCalcContext(bk, CPU_PLAYER_INDEX, OPP_PLAYER_INDEX);
    const staticDamages = computeMoveDamages(attackCtx, metas, moves);
    const saltSeed = BigInt(Number(e.getTurnIdForBattleState(bk)) + 1);
    const measured = forkMeasureMoveDamages(e, bk, playerMoveIndex, playerExtraData, moves, saltSeed);
    const damages = evScaleDamages(
      e, bk, activeMonIndex, moves,
      staticDamages.map((s, i) => Math.max(s, measured.damages[i])),
    );

    // Eval-veto wrapper for every decision from here down: the tree's pick stands unless a forked
    // alternative clearly beats it (EVAL_OVERRIDE_MARGIN). Move forks reuse the measurement scores;
    // only switches/rest fork extra. Overrides surface as "<phase>>eval" in the decision trace.
    const ARB = (m: RevealedMove, phase: string): CpuMove => {
      const better = pickEvalOverride(
        e, bk, playerMoveIndex, playerExtraData, m, moves, measured.scores, switches, noOp, saltSeed,
      );
      if (better === null) return DONE(m, phase);
      if (better.moveIndex === SWITCH_MOVE_INDEX) {
        moveUsedBitmap = clearMoveUsedBitsOnSwitchIn(e, bk, moveUsedBitmap, better.extraData);
      }
      return DONE(better, `${phase}>eval`);
    };

    // Hoist the opp-threat computation ONCE: read the opp's revealed move slot + class, build the
    // opp->us damage context, and estimate damage-to-our-active. P2 (canOpponentKOUs) and P5
    // (evaluateDefensiveSwitch) both consume these instead of recomputing the same numbers.
    let oppMoveSlot: bigint | undefined;
    let oppMoveClass: MoveClass | undefined;
    let damageToUs = 0;
    if (playerMoveIndex < SWITCH_MOVE_INDEX) {
      try {
        oppMoveSlot = e.getMoveForMonForBattle(bk, OPP_PLAYER_INDEX, BigInt(opponentMonIndex), BigInt(playerMoveIndex));
        oppMoveClass = moveSlotLib.moveClass(oppMoveSlot!, e, bk) as MoveClass;
        if (oppMoveClass === MoveClass.Physical || oppMoveClass === MoveClass.Special) {
          const ctxToUs = e.getDamageCalcContext(bk, OPP_PLAYER_INDEX, CPU_PLAYER_INDEX);
          damageToUs = estimateDamage(e, bk, ctxToUs, oppMoveSlot!, oppMoveClass);
        }
      } catch {
        oppMoveSlot = undefined;
        oppMoveClass = undefined;
      }
      // True reveal damage from the sim — prices what the static model can't (variable-power moves
      // it reads as 0, our own ability mitigation it overestimates). The static estimate stays as
      // the floor only when the fork measures nothing (a fixed-salt roll can miss).
      const measuredToUs = forkMeasureIncomingDamage(e, bk, playerMoveIndex, playerExtraData, null, saltSeed);
      if (measuredToUs > 0) damageToUs = measuredToUs;
    }

    // ── P2: Can We KO the Opponent? ──
    const koMoveIdx = findKOMove(e, bk, opponentMonIndex, metas, moves, damages);
    if (koMoveIdx >= 0) {
      const opponentCanKOUs = canOpponentKOUs(e, bk, activeMonIndex, playerMoveIndex, damageToUs);
      if (
        !opponentCanKOUs ||
        weGoFirst(e, bk, metas, activeMonIndex, opponentMonIndex, moves[koMoveIdx].moveIndex, playerMoveIndex)
      ) {
        return ARB(moves[koMoveIdx], 'P2-ko');
      }
      // else: opponent outspeeds us and can KO — fall through to P5.
    }

    // ── P3: Opponent is Switching ── A telegraphed free turn: same guarded punish tree as P4.5
    // (configured switch-in -> 2HKO -> momentum+productive setup), then band damage, then rest.
    if (playerMoveIndex === SWITCH_MOVE_INDEX) {
      const fr = freeTurnPick(view, BETTER_CPU_MON_CONFIG, moveUsedBitmap, metas, moves, damages);
      moveUsedBitmap = fr.moveUsedBitmap;
      if (fr.picked) return ARB(fr.move!, 'P3-opp-switching');
      if (moves.length > 0) {
        const bestMove = pickSimilarDamageMove(damages, rng);
        if (bestMove >= 0) return ARB(moves[bestMove], 'P3-opp-switching');
      }
      return ARB(noOp[0], 'P3-opp-switching'); // rest on free turn
    }

    // ── P4: Opponent is Resting ── (same free-turn punish as P3)
    if (playerMoveIndex === NO_OP_INDEX) {
      if (moves.length === 0) return ARB(noOp[0], 'P4-opp-resting'); // both rest
      const fr = freeTurnPick(view, BETTER_CPU_MON_CONFIG, moveUsedBitmap, metas, moves, damages);
      moveUsedBitmap = fr.moveUsedBitmap;
      if (fr.picked) return ARB(fr.move!, 'P4-opp-resting');
      const bestMove = pickSimilarDamageMove(damages, rng);
      if (bestMove >= 0) return ARB(moves[bestMove], 'P4-opp-resting');
      return ARB(noOp[0], 'P4-opp-resting');
    }

    // ── P4.5: Free-turn setup-punishment — the opponent telegraphed a 0-power Self/Other move.
    // Safe always-on via freeTurnPick's guards (no pivot branch; setup needs momentum + progress).
    if (isFreeTurnReveal(e, bk, opponentMonIndex, playerMoveIndex)) {
      const fr = freeTurnPick(view, BETTER_CPU_MON_CONFIG, moveUsedBitmap, metas, moves, damages);
      if (fr.picked) {
        moveUsedBitmap = fr.moveUsedBitmap;
        return ARB(fr.move!, 'P4.5-free-turn');
      }
      moveUsedBitmap = fr.moveUsedBitmap;
    }

    // ── P5: Opponent Using a Move — Evaluate Defensive Switch ──
    if (switches.length > 0) {
      // KO-bypass (ALWAYS-ON): best move near-KOs (±10%) and we outspeed => stay in.
      const koBypassFires =
        moves.length > 0 &&
        checkKOBypass(e, bk, metas, activeMonIndex, opponentMonIndex, moves, damages, playerMoveIndex);
      const { shouldSwitch, switchIdx } = evaluateDefensiveSwitch(
        e, bk, activeMonIndex, opponentMonIndex, playerMoveIndex, playerExtraData, switches, severeDamagePct,
        koBypassFires, oppMoveSlot, oppMoveClass, damageToUs, saltSeed,
      );
      if (shouldSwitch) {
        // The switch costs our turn, and the damage-% thresholds above never weighed our own offense.
        // Cross-check: only switch if the fork says it leaves a better position than staying and
        // hitting (the stay score was already paid for by the damage measurement).
        const stayIdx = findBestDamageMove(metas, moves, damages);
        const swScore = forkScoreAction(e, bk, playerMoveIndex, playerExtraData, switches[switchIdx], saltSeed);
        if (stayIdx < 0 || swScore >= measured.scores[stayIdx]) {
          moveUsedBitmap = clearMoveUsedBitsOnSwitchIn(e, bk, moveUsedBitmap, switches[switchIdx].extraData);
          return ARB(switches[switchIdx], 'P5-defensive-switch');
        }
        return ARB(moves[stayIdx], 'P5-stay-and-hit');
      }
    }

    // ── P5.5: Anti-wall stalemate-breaker — pivot out of a dead matchup (we can't progress + a bench
    // mon matches up strictly better). Catches the flail-at-a-wall the threat-based P5 misses. ──
    if (switches.length > 0) {
      const antiWallIdx = antiWallSwitch(view, metas, moves, damages, switches, {
        revealIdx: playerMoveIndex,
        revealExtra: playerExtraData,
        salt: saltSeed,
      });
      if (antiWallIdx >= 0) {
        moveUsedBitmap = clearMoveUsedBitsOnSwitchIn(e, bk, moveUsedBitmap, switches[antiWallIdx].extraData);
        return ARB(switches[antiWallIdx], 'P5.5-anti-wall');
      }
    }

    // ── P6: Default — Best Damaging Move (sampled from the similar-damage band) ──
    if (moves.length > 0) {
      const r = tryConfiguredMove(BETTER_CPU_MON_CONFIG, moveUsedBitmap, activeMonIndex, moves, CONFIG_SWITCH_IN_MOVE, 0);
      moveUsedBitmap = r.usedBitmap;
      if (r.index >= 0) return ARB(moves[r.index], 'P6-default');

      const preferredMove = tryPreferredMove(BETTER_CPU_MON_CONFIG, activeMonIndex, attackCtx, metas, moves);
      if (preferredMove >= 0) return ARB(moves[preferredMove], 'P6-default');

      const bestMove = pickSimilarDamageMove(damages, rng);
      if (bestMove >= 0) return ARB(moves[bestMove], 'P6-default');
    }

    // Stuck fallback — no damaging option left. The tree has no opinion here, so take the best
    // forked position outright: move scores are already measured; switches/rest fork now.
    let fbBest: RevealedMove = noOp[0] ?? { moveIndex: NO_OP_INDEX, extraData: 0 };
    let fbScore = -Infinity;
    const fbConsider = (m: RevealedMove, s: number) => {
      if (s > fbScore) {
        fbScore = s;
        fbBest = m;
      }
    };
    for (let i = 0; i < moves.length; i++) fbConsider(moves[i], measured.scores[i]);
    for (const m of [...switches, ...noOp]) {
      fbConsider(m, forkScoreAction(e, bk, playerMoveIndex, playerExtraData, m, saltSeed));
    }
    if (fbBest.moveIndex === SWITCH_MOVE_INDEX) {
      moveUsedBitmap = clearMoveUsedBitsOnSwitchIn(e, bk, moveUsedBitmap, fbBest.extraData);
    }
    return DONE(fbBest, 'fallback');
  }
}
