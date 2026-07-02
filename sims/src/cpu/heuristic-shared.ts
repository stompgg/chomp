import { Hex } from './hex';
import { MoveClass, MonStateIndexName, Type } from '../../../transpiler/ts-output/Enums';
import { moveSlotLib } from '../../../transpiler/ts-output/moves/MoveSlotLib';
import { attackCalculator } from '../../../transpiler/ts-output/moves/AttackCalculator';
import { typeCalcLib } from '../../../transpiler/ts-output/types/TypeCalcLib';
import { createDefaultDamageCalcContext, createDefaultMoveMeta, DamageCalcContext, MoveMeta } from '../../../transpiler/ts-output/Structs';
import { SWITCH_MOVE_INDEX } from './constants';
import { RevealedMove, typeEffectiveness } from './engine-view';

/**
 * Idiomatic TS port of `HeuristicCPUBase.sol` — the shared scoring / decision machinery that
 * FairCPU and BetterCPU both build on. Heuristic-free candidate enumeration + readers live in
 * `engine-view.ts`; THIS module is where the actual strategy helpers live (damage estimation, KO /
 * best-damage move finders, lead selection, switch selection, per-mon-strategy helpers, the adaptive
 * Hell/Tartarus/Diyu state machine, and the random-pick / momentum utilities).
 *
 * The CPU is ALWAYS p1 (playerIndex 1n); the human opponent is p0 (0n). `e` is the LOCAL transpiled
 * engine. Solidity storage-packing / context-struct / MoveMeta-caching scaffolding is dropped per the
 * FIDELITY MANDATE — but EVERY decision branch, threshold, probability, ordering and formula is
 * reproduced exactly, each cited to its `HeuristicCPUBase.sol` source line.
 *
 * State that the Solidity contract kept in storage mappings is, in idiomatic TS, passed in / returned
 * out explicitly:
 *   - `playerState[p0]` (the adaptive mode ladder)  -> a plain `number` threaded through {@link recordResult}.
 *   - `monConfig[monIndex][key]`                     -> a {@link MonConfig} lookup the subclass owns.
 *   - `cpuMoveUsedBitmap[battleKey]`                 -> a plain `number` threaded through the configured-move helpers.
 */

const CPU_PLAYER_INDEX = 1n;
const OPP_PLAYER_INDEX = 0n;

// HeuristicCPUBase.sol:28 — moves within 15% of the best damage are "similar" (85% threshold).
export const SIMILAR_DAMAGE_THRESHOLD = 85;
// HeuristicCPUBase.sol:29 — a candidate must beat the current mon by >= 30 (matchup-score units)
// to justify switching.
export const SWITCH_THRESHOLD = 30;

// HeuristicCPUBase.sol:32-34 — per-mode severe-damage thresholds (Hell/Tartarus/Diyu ladder).
export const SEVERE_DAMAGE_PCT_HELL = 30;
export const SEVERE_DAMAGE_PCT_TARTARUS = 50;
export const SEVERE_DAMAGE_PCT_DIYU = 60;

// HeuristicCPUBase.sol:37-39 — adaptive state-machine modes.
export const MODE_HELL = 0;
export const MODE_TARTARUS = 1;
export const MODE_DIYU = 2;

// HeuristicCPUBase.sol:42-45 — per-mon strategy config keys (values stored as moveIndex+1; 0 = unset).
export const CONFIG_PREFERRED_MOVE = 0;
export const CONFIG_SWITCH_IN_MOVE = 1;
export const CONFIG_SETUP_MOVE = 2;

// ---------------------------------------------------------------------------------------------
// Adaptive state machine  (HeuristicCPUBase.sol:66-100)
// ---------------------------------------------------------------------------------------------
//
// In Solidity this is `playerState[p0]`, a packed uint256 (bits 8-9 = mode, bit 10 = diyuPriorLoss).
// Here it is a plain `number` the subclass persists per-opponent. `recordResult` is the faithful port
// of `_recordResult` (+ the `_afterTurn` guard that only records once the battle has a winner).

/** Read the current mode out of a packed playerState value. HeuristicCPUBase.sol:72 */
export function modeOf(state: number): number {
  return (state >> 8) & 0x3;
}

/** Read the diyuPriorLoss flag out of a packed playerState value. HeuristicCPUBase.sol:73 */
export function diyuPriorLossOf(state: number): boolean {
  return ((state >> 10) & 0x1) !== 0;
}

/**
 * Port of `_recordResult`: advance the Hell/Tartarus/Diyu ladder after a battle. DIYU is sticky for
 * one loss then resets to HELL; a DIYU win demotes to TARTARUS. Returns the new packed state.
 * HeuristicCPUBase.sol:70-95
 */
export function recordResult(state: number, cpuWon: boolean): number {
  const mode = modeOf(state); // HeuristicCPUBase.sol:72
  const diyuPriorLoss = diyuPriorLossOf(state); // HeuristicCPUBase.sol:73

  let newMode: number;
  let newDiyuPriorLoss = false;

  if (mode === MODE_HELL) {
    // HeuristicCPUBase.sol:78-79 — HELL: a loss drops to TARTARUS; a win stays HELL.
    newMode = cpuWon ? MODE_HELL : MODE_TARTARUS;
  } else if (mode === MODE_TARTARUS) {
    // HeuristicCPUBase.sol:80-81 — TARTARUS: a win promotes back to HELL; a loss drops to DIYU.
    newMode = cpuWon ? MODE_HELL : MODE_DIYU;
  } else if (cpuWon) {
    // HeuristicCPUBase.sol:82-83 — DIYU win: demote to TARTARUS.
    newMode = MODE_TARTARUS;
  } else if (diyuPriorLoss) {
    // HeuristicCPUBase.sol:84-85 — DIYU second loss: reset to HELL.
    newMode = MODE_HELL;
  } else {
    // HeuristicCPUBase.sol:86-88 — DIYU first loss: stay DIYU, mark the prior-loss flag.
    newMode = MODE_DIYU;
    newDiyuPriorLoss = true;
  }

  // HeuristicCPUBase.sol:91-93 — repack mode (bits 8-9) + diyuPriorLoss (bit 10).
  return (state & ~0x700) | (newMode << 8) | (newDiyuPriorLoss ? 1 << 10 : 0);
}

// ---------------------------------------------------------------------------------------------
// Damage estimation  (HeuristicCPUBase.sol:102-182)
// ---------------------------------------------------------------------------------------------

/**
 * Port of `_buildDamageCalcContext`: assemble a DamageCalcContext for ANY attacker/defender pair
 * (not just the active mons). The local engine's `getMonStateForBattle` already normalizes the
 * CLEARED_MON_STATE_SENTINEL to 0, so the Solidity `delta == SENTINEL ? 0 : delta` guard is a no-op
 * here — the reads come back already clean. HeuristicCPUBase.sol:105-143
 */
export function buildDamageCalcContext(
  e: any,
  bk: Hex,
  attackerIndex: bigint,
  attackerMonIndex: number,
  defenderIndex: bigint,
  defenderMonIndex: number,
): DamageCalcContext {
  const attackerStats = e.getMonStatsForBattle(bk, attackerIndex, BigInt(attackerMonIndex));
  const defenderStats = e.getMonStatsForBattle(bk, defenderIndex, BigInt(defenderMonIndex));

  const ctx = createDefaultDamageCalcContext();
  ctx.attackerMonIndex = BigInt(attackerMonIndex);
  ctx.defenderMonIndex = BigInt(defenderMonIndex);

  // HeuristicCPUBase.sol:118-127 — attacker offensive stats (base + delta, sentinel-normalized).
  ctx.attackerAttack = attackerStats.attack;
  ctx.attackerAttackDelta = e.getMonStateForBattle(bk, attackerIndex, BigInt(attackerMonIndex), MonStateIndexName.Attack);
  ctx.attackerSpAtk = attackerStats.specialAttack;
  ctx.attackerSpAtkDelta = e.getMonStateForBattle(bk, attackerIndex, BigInt(attackerMonIndex), MonStateIndexName.SpecialAttack);

  // HeuristicCPUBase.sol:129-138 — defender defensive stats.
  ctx.defenderDef = defenderStats.defense;
  ctx.defenderDefDelta = e.getMonStateForBattle(bk, defenderIndex, BigInt(defenderMonIndex), MonStateIndexName.Defense);
  ctx.defenderSpDef = defenderStats.specialDefense;
  ctx.defenderSpDefDelta = e.getMonStateForBattle(bk, defenderIndex, BigInt(defenderMonIndex), MonStateIndexName.SpecialDefense);

  // HeuristicCPUBase.sol:141-142 — defender types.
  ctx.defenderType1 = defenderStats.type1;
  ctx.defenderType2 = defenderStats.type2;
  return ctx;
}

/**
 * Port of `_estimateDamage`: deterministic damage estimate for a raw move slot against a prepared
 * context. Inline slots read basePower directly; external attack moves expose `basePower(battleKey)`
 * (non-attack / non-IAttackMove moves estimate to 0). Damage uses fixed accuracy=100 (always hits),
 * volatility=0 (no variance), rng=50, critRate=0 so the estimate is stable. HeuristicCPUBase.sol:146-168
 */
export function estimateDamage(
  e: any,
  bk: Hex,
  ctx: DamageCalcContext,
  rawMoveSlot: bigint,
  moveClass: MoveClass,
): number {
  let basePower: bigint;
  if (moveSlotLib.isInline(rawMoveSlot)) {
    basePower = moveSlotLib.basePower(rawMoveSlot, bk); // HeuristicCPUBase.sol:152-153
  } else {
    // HeuristicCPUBase.sol:154-160 — external move: try IAttackMove.basePower, fall back to 0.
    basePower = externalBasePower(e, bk, rawMoveSlot);
  }
  if (basePower === 0n) return 0; // HeuristicCPUBase.sol:161

  const moveType = moveSlotLib.moveType(rawMoveSlot, e, bk) as Type; // HeuristicCPUBase.sol:163
  // HeuristicCPUBase.sol:165-166 — accuracy=100, volatility=0, rng=50, critRate=0.
  // `_calculateDamageFromContext` only invokes `.getTypeEffectiveness` on its first arg; TypeCalculator
  // delegates straight to typeCalcLib, so passing the lib is the faithful TYPE_CALC.
  const [damage] = attackCalculator._calculateDamageFromContext(
    typeCalcLib as any,
    ctx,
    basePower,
    100n,
    0n,
    moveType,
    moveClass,
    50n,
    0n,
  );
  return damage > 0n ? Number(damage) : 0; // HeuristicCPUBase.sol:167
}

/**
 * Port of `_estimateDamageMeta`: same as {@link estimateDamage} but reading basePower / moveType /
 * moveClass off a pre-decoded MoveMeta (no per-call metadata reads). HeuristicCPUBase.sol:172-182
 */
export function estimateDamageMeta(ctx: DamageCalcContext, meta: MoveMeta): number {
  if (meta.basePower === 0n) return 0; // HeuristicCPUBase.sol:177
  const [damage] = attackCalculator._calculateDamageFromContext(
    typeCalcLib as any,
    ctx,
    meta.basePower,
    100n,
    0n,
    meta.moveType,
    meta.moveClass,
    50n,
    0n,
  ); // HeuristicCPUBase.sol:178-180
  return damage > 0n ? Number(damage) : 0; // HeuristicCPUBase.sol:181
}

/**
 * Port of the `_getMoveBasePower` external branch (and the `_estimateDamage` external try/catch):
 * read `basePower(battleKey)` off an external attack move, returning 0 for moves that don't expose it.
 * HeuristicCPUBase.sol:483-492
 */
function externalBasePower(e: any, bk: Hex, rawMoveSlot: bigint): bigint {
  try {
    const move = moveSlotLib.toIMoveSet(rawMoveSlot) as any;
    if (typeof move.basePower !== 'function') return 0n;
    const bp = move.basePower(bk);
    return bp === undefined || bp === null ? 0n : BigInt(bp);
  } catch {
    return 0n; // HeuristicCPUBase.sol:157-158 / 489-490 — catch => 0
  }
}

/**
 * Port of `_getMoveBasePower`: basePower of a raw move slot, 0 for non-attack moves. Used by Diyu D4
 * free-turn detection. HeuristicCPUBase.sol:483-492
 */
export function getMoveBasePower(e: any, bk: Hex, rawMoveSlot: bigint): number {
  if (moveSlotLib.isInline(rawMoveSlot)) {
    return Number(moveSlotLib.basePower(rawMoveSlot, bk)); // HeuristicCPUBase.sol:484-485
  }
  return Number(externalBasePower(e, bk, rawMoveSlot)); // HeuristicCPUBase.sol:487-490
}

// ---------------------------------------------------------------------------------------------
// Move selection  (HeuristicCPUBase.sol:184-274)
// ---------------------------------------------------------------------------------------------

/**
 * Decode a mon's four move-slot metas (the `metas` array the damage/KO/best-move helpers index by
 * moveIndex). A missing slot (<4-move mon) or a decode failure yields a default all-zero meta
 * (basePower 0 => contributes nothing). Shared by FairCPU's loaders and the greedy easy CPU; BetterCPU
 * keeps its own `buildMetas` for strict 1:1 fidelity with its (non-catching) decode path.
 */
export function loadMonMetas(e: any, bk: Hex, playerIndex: bigint, monIndex: number): MoveMeta[] {
  const metas: MoveMeta[] = [];
  for (let i = 0; i < 4; i++) {
    const slot = e.getMoveForMonForBattle(bk, playerIndex, BigInt(monIndex), BigInt(i));
    if (slot === undefined || slot === null) {
      metas.push(createDefaultMoveMeta());
      continue;
    }
    try {
      metas.push(moveSlotLib.decodeMeta(slot, e, bk, playerIndex, BigInt(monIndex)));
    } catch {
      metas.push(createDefaultMoveMeta());
    }
  }
  return metas;
}

/**
 * Port of `_computeMoveDamages`: outgoing damage for every Physical/Special move in `moves`, indexed
 * parallel to `moves` (non-damaging moves => 0). Built once per turn and threaded through the KO /
 * best-damage finders. `metas[moveIndex]` is the decoded MoveMeta for each of the active mon's 4 move
 * slots. HeuristicCPUBase.sol:188-203
 */
export function computeMoveDamages(ctx: DamageCalcContext, metas: MoveMeta[], moves: RevealedMove[]): number[] {
  const damages = new Array<number>(moves.length).fill(0);
  for (let i = 0; i < moves.length; i++) {
    const meta = metas[moves[i].moveIndex];
    // HeuristicCPUBase.sol:196 — only Physical / Special moves deal damage.
    if (meta.moveClass === MoveClass.Physical || meta.moveClass === MoveClass.Special) {
      damages[i] = estimateDamageMeta(ctx, meta);
    }
  }
  return damages;
}

/**
 * Port of `_findKOMove`: index INTO `moves` of the cheapest-stamina move that KOs the opponent's
 * defender, or -1 if none (or the defender is already at <=0 HP). Damages are pre-computed by
 * {@link computeMoveDamages}. HeuristicCPUBase.sol:207-235
 */
export function findKOMove(
  e: any,
  bk: Hex,
  defenderMonIndex: number,
  metas: MoveMeta[],
  moves: RevealedMove[],
  damages: number[],
): number {
  // HeuristicCPUBase.sol:214-216 — defender CURRENT hp = base + delta (opponent is p0).
  const defenderBaseHp = Number(e.getMonValueForBattle(bk, OPP_PLAYER_INDEX, BigInt(defenderMonIndex), MonStateIndexName.Hp));
  const defenderHpDelta = Number(e.getMonStateForBattle(bk, OPP_PLAYER_INDEX, BigInt(defenderMonIndex), MonStateIndexName.Hp));
  const defenderCurrentHp = defenderBaseHp + defenderHpDelta;
  if (defenderCurrentHp <= 0) return -1; // HeuristicCPUBase.sol:217

  let bestMoveIndex = -1;
  let bestStaminaCost = Number.MAX_SAFE_INTEGER;

  for (let i = 0; i < moves.length; i++) {
    // HeuristicCPUBase.sol:223-228 — among KO-capable moves, keep the cheapest stamina.
    if (damages[i] >= defenderCurrentHp) {
      const stamina = Number(metas[moves[i].moveIndex].stamina);
      if (stamina < bestStaminaCost) {
        bestStaminaCost = stamina;
        bestMoveIndex = i;
      }
    }
  }
  return bestMoveIndex;
}

/**
 * Port of `_findBestDamageMove`: index INTO `moves` of the best damaging move, then a cheapest-stamina
 * tiebreak across all moves within 85% of that best damage. -1 if no move deals damage. Damages
 * pre-computed. HeuristicCPUBase.sol:238-274
 */
export function findBestDamageMove(metas: MoveMeta[], moves: RevealedMove[], damages: number[]): number {
  let bestMoveIndex = -1;
  let bestDamage = 0;
  let bestStaminaCost = Number.MAX_SAFE_INTEGER;

  // HeuristicCPUBase.sol:247-256 — first pass: strictly-greatest damage.
  for (let i = 0; i < moves.length; i++) {
    if (damages[i] > bestDamage) {
      bestDamage = damages[i];
      bestStaminaCost = Number(metas[moves[i].moveIndex].stamina);
      bestMoveIndex = i;
    }
  }

  if (bestDamage === 0) return bestMoveIndex; // HeuristicCPUBase.sol:258

  // HeuristicCPUBase.sol:261-271 — cheapest-stamina tiebreak among moves within 85% of best damage.
  const threshold = Math.floor((bestDamage * SIMILAR_DAMAGE_THRESHOLD) / 100);
  for (let i = 0; i < moves.length; i++) {
    const stamina = Number(metas[moves[i].moveIndex].stamina);
    if (damages[i] >= threshold && stamina < bestStaminaCost) {
      bestStaminaCost = stamina;
      bestMoveIndex = i;
    }
  }
  return bestMoveIndex;
}

// ---------------------------------------------------------------------------------------------
// Lead selection  (HeuristicCPUBase.sol:276-356)
// ---------------------------------------------------------------------------------------------

/**
 * Port of `_offensiveMatchupScore`: SUM of type-effectiveness (scale 10) for every candidate-type ×
 * opponent-type pair (candidate offense vs opponent defense). Single-type mons (`Type.None` second
 * type) contribute only their real type. HeuristicCPUBase.sol:280-294
 */
export function offensiveMatchupScore(candType1: Type, candType2: Type, oppType1: Type, oppType2: Type): number {
  let score = typeEffectiveness(candType1, oppType1, 10); // HeuristicCPUBase.sol:283
  if (oppType2 !== Type.None) {
    score += typeEffectiveness(candType1, oppType2, 10); // HeuristicCPUBase.sol:285
  }
  if (candType2 !== Type.None) {
    score += typeEffectiveness(candType2, oppType1, 10); // HeuristicCPUBase.sol:288
    if (oppType2 !== Type.None) {
      score += typeEffectiveness(candType2, oppType2, 10); // HeuristicCPUBase.sol:290
    }
  }
  return score;
}

/**
 * Defensive matchup: SUM of type-effectiveness (scale 10) for every opponent-type × candidate-type
 * pair (opponent offense vs candidate defense). This is the inline `defensiveScore` block inside
 * `_selectLead`. HeuristicCPUBase.sol:319-328
 */
export function defensiveMatchupScore(oppType1: Type, oppType2: Type, candType1: Type, candType2: Type): number {
  let score = typeEffectiveness(oppType1, candType1, 10); // HeuristicCPUBase.sol:319
  if (candType2 !== Type.None) {
    score += typeEffectiveness(oppType1, candType2, 10); // HeuristicCPUBase.sol:321
  }
  if (oppType2 !== Type.None) {
    score += typeEffectiveness(oppType2, candType1, 10); // HeuristicCPUBase.sol:324
    if (candType2 !== Type.None) {
      score += typeEffectiveness(oppType2, candType2, 10); // HeuristicCPUBase.sol:326
    }
  }
  return score;
}

/**
 * Port of `_selectLead`: dual-type-scored lead pick among the turn-0 `switches`. `aggressive` weights
 * offense more heavily (`3*off - def` vs balanced `off - def`), producing offensive leads in
 * TARTARUS/DIYU vs balanced/defensive in HELL. Returns the chosen switch RevealedMove.
 * HeuristicCPUBase.sol:298-356
 */
export function selectLead(
  e: any,
  bk: Hex,
  opponentMonExtraData: number,
  switches: RevealedMove[],
  aggressive: boolean,
): RevealedMove {
  // HeuristicCPUBase.sol:304-306 — opponent's chosen lead types.
  const oppStats = e.getMonStatsForBattle(bk, OPP_PLAYER_INDEX, BigInt(opponentMonExtraData));
  const oppType1 = oppStats.type1 as Type;
  const oppType2 = oppStats.type2 as Type;

  let bestScore = -Infinity; // HeuristicCPUBase.sol:308 — type(int256).min
  let bestIndex = 0;

  for (let i = 0; i < switches.length; i++) {
    const candStats = e.getMonStatsForBattle(bk, CPU_PLAYER_INDEX, BigInt(switches[i].extraData));
    const candType1 = candStats.type1 as Type;
    const candType2 = candStats.type2 as Type;

    const defensiveScore = defensiveMatchupScore(oppType1, oppType2, candType1, candType2); // HeuristicCPUBase.sol:318-328
    const offensiveScore = offensiveMatchupScore(candType1, candType2, oppType1, oppType2); // HeuristicCPUBase.sol:330-340

    // HeuristicCPUBase.sol:342-344 — aggressive triples offense weight.
    const score = aggressive ? 3 * offensiveScore - defensiveScore : offensiveScore - defensiveScore;

    if (score > bestScore) {
      // HeuristicCPUBase.sol:346-349 — strict >, so ties keep the first (lowest index).
      bestScore = score;
      bestIndex = i;
    }
  }
  return switches[bestIndex]; // HeuristicCPUBase.sol:355
}

// ---------------------------------------------------------------------------------------------
// Switch selection  (HeuristicCPUBase.sol:358-427)
// ---------------------------------------------------------------------------------------------

/**
 * Port of `_selectBestSwitch`. Non-aggressive (HELL): the safest sponge — least estimated damage from
 * the opponent's revealed move (falls back to `switches[0]` if the opponent is switching, or the
 * revealed move isn't a readable Physical/Special attack). Aggressive (TARTARUS/DIYU revenge): the
 * best offensive matchup against the opponent's active mon. Returns the chosen switch RevealedMove.
 * HeuristicCPUBase.sol:363-427
 */
export function selectBestSwitch(
  e: any,
  bk: Hex,
  opponentMonIndex: number,
  opponentMoveIndex: number,
  switches: RevealedMove[],
  aggressive: boolean,
): RevealedMove {
  if (aggressive) {
    // HeuristicCPUBase.sol:370-388 — best offensive matchup vs the opponent's active mon.
    const oppStats = e.getMonStatsForBattle(bk, OPP_PLAYER_INDEX, BigInt(opponentMonIndex));
    const oppType1 = oppStats.type1 as Type;
    const oppType2 = oppStats.type2 as Type;

    let bestScore = -Infinity;
    let bestIdx = 0;
    for (let i = 0; i < switches.length; i++) {
      const candStats = e.getMonStatsForBattle(bk, CPU_PLAYER_INDEX, BigInt(switches[i].extraData));
      const score = offensiveMatchupScore(candStats.type1 as Type, candStats.type2 as Type, oppType1, oppType2);
      if (score > bestScore) {
        bestScore = score;
        bestIdx = i;
      }
    }
    return switches[bestIdx];
  }

  // HeuristicCPUBase.sol:391-393 — opponent is switching (no readable attack): default to switches[0].
  if (opponentMoveIndex >= SWITCH_MOVE_INDEX) {
    return switches[0];
  }

  // HeuristicCPUBase.sol:395-404 — read the opponent's revealed move; only Physical/Special are estimable.
  let oppMoveSlot: bigint;
  let oppMoveClass: MoveClass;
  let canEstimate = false;
  try {
    oppMoveSlot = e.getMoveForMonForBattle(bk, OPP_PLAYER_INDEX, BigInt(opponentMonIndex), BigInt(opponentMoveIndex));
    oppMoveClass = moveSlotLib.moveClass(oppMoveSlot, e, bk) as MoveClass;
    canEstimate = oppMoveClass === MoveClass.Physical || oppMoveClass === MoveClass.Special;
  } catch {
    canEstimate = false;
  }

  if (!canEstimate) {
    return switches[0]; // HeuristicCPUBase.sol:406-408
  }

  // HeuristicCPUBase.sol:410-426 — pick the candidate that takes the LEAST damage from that move.
  let bestIdx = 0;
  let leastDamage = Number.MAX_SAFE_INTEGER;
  for (let i = 0; i < switches.length; i++) {
    const candidateMonIndex = switches[i].extraData;
    const ctx = buildDamageCalcContext(e, bk, OPP_PLAYER_INDEX, opponentMonIndex, CPU_PLAYER_INDEX, candidateMonIndex);
    const dmg = estimateDamage(e, bk, ctx, oppMoveSlot!, oppMoveClass!);
    if (dmg < leastDamage) {
      leastDamage = dmg;
      bestIdx = i;
    }
  }
  return switches[bestIdx];
}

// ---------------------------------------------------------------------------------------------
// Per-mon strategy  (HeuristicCPUBase.sol:429-600)
// ---------------------------------------------------------------------------------------------

/**
 * Per-mon strategy config — the TS stand-in for `monConfig[monIndex][configKey]`. Values follow the
 * Solidity convention: stored as `moveIndex + 1`, with `0`/absent meaning unset.
 */
export type MonConfig = { [monIndex: number]: { [configKey: number]: number } };

function readConfig(config: MonConfig, monIndex: number, key: number): number {
  return config[monIndex]?.[key] ?? 0;
}

/**
 * Port of `_tryConfiguredMove`: try to play a per-mon configured move (switch-in or setup), marking
 * the corresponding lane bit in `usedBitmap`. Returns `{ index, usedBitmap }` where `index` is the
 * position INTO `moves`, or -1 if unconfigured / already used this switch-in / absent from `moves`.
 * The (possibly mutated) bitmap is returned so the caller can persist it (no in-place storage).
 * HeuristicCPUBase.sol:434-458
 */
export function tryConfiguredMove(
  config: MonConfig,
  usedBitmap: number,
  activeMonIndex: number,
  moves: RevealedMove[],
  configKey: number,
  laneBitOffset: number,
): { index: number; usedBitmap: number } {
  const configValue = readConfig(config, activeMonIndex, configKey); // HeuristicCPUBase.sol:441
  if (configValue === 0) return { index: -1, usedBitmap }; // HeuristicCPUBase.sol:442
  const targetMoveIndex = configValue - 1; // HeuristicCPUBase.sol:443

  const laneBit = 1 << (activeMonIndex + laneBitOffset); // HeuristicCPUBase.sol:445
  if ((usedBitmap & laneBit) !== 0) return { index: -1, usedBitmap }; // HeuristicCPUBase.sol:446 — already used

  for (let i = 0; i < moves.length; i++) {
    if (moves[i].moveIndex === targetMoveIndex) {
      // HeuristicCPUBase.sol:450-451 — mark the lane bit and return the position.
      return { index: i, usedBitmap: usedBitmap | laneBit };
    }
  }
  return { index: -1, usedBitmap }; // HeuristicCPUBase.sol:457
}

/**
 * Port of `_clearMoveUsedBitsOnSwitchIn`: clear move-used bits on mon re-entry. The switch-in lane
 * (bit `monIdx`) clears unconditionally; the setup lane (bit `monIdx + 8`) clears only when current
 * HP is strictly above 50% — a low-HP re-entry shouldn't waste a turn setting up. Returns the new
 * bitmap. HeuristicCPUBase.sol:463-479
 */
export function clearMoveUsedBitsOnSwitchIn(e: any, bk: Hex, usedBitmap: number, monIdx: number): number {
  const setupBit = 1 << (monIdx + 8); // HeuristicCPUBase.sol:465
  let newBitmap = usedBitmap & ~(1 << monIdx); // HeuristicCPUBase.sol:466 — switch-in lane clears unconditionally

  // HeuristicCPUBase.sol:469-476 — only consult HP if the setup lane bit is actually set.
  if ((usedBitmap & setupBit) !== 0) {
    const maxHp = Number(e.getMonValueForBattle(bk, CPU_PLAYER_INDEX, BigInt(monIdx), MonStateIndexName.Hp));
    const hpDelta = Number(e.getMonStateForBattle(bk, CPU_PLAYER_INDEX, BigInt(monIdx), MonStateIndexName.Hp));
    const currentHp = maxHp + hpDelta;
    // HeuristicCPUBase.sol:473-475 — strictly above 50% (currentHp*2 > maxHp) clears the setup lane.
    if (currentHp * 2 > maxHp) {
      newBitmap &= ~setupBit;
    }
  }
  return newBitmap;
}

/**
 * Port of `_tryPreferredMove`: use the per-mon CONFIG_PREFERRED_MOVE if set AND within 85% of the best
 * damaging move's damage. Returns the position INTO `moves`, or -1 if unconfigured / preferred not
 * present / below the threshold. (If no move deals damage, the preferred move is used as-is.)
 * HeuristicCPUBase.sol:555-600
 */
export function tryPreferredMove(
  config: MonConfig,
  activeMonIndex: number,
  ctx: DamageCalcContext,
  metas: MoveMeta[],
  moves: RevealedMove[],
): number {
  const configValue = readConfig(config, activeMonIndex, CONFIG_PREFERRED_MOVE); // HeuristicCPUBase.sol:561
  if (configValue === 0) return -1; // HeuristicCPUBase.sol:563
  const targetMoveIndex = configValue - 1; // HeuristicCPUBase.sol:564

  let preferredIdx = -1;
  let preferredDamage = 0;
  let bestDamage = 0;

  for (let i = 0; i < moves.length; i++) {
    const meta = metas[moves[i].moveIndex];
    // HeuristicCPUBase.sol:573-578 — skip non-damaging classes.
    if (meta.moveClass !== MoveClass.Physical && meta.moveClass !== MoveClass.Special) {
      continue;
    }
    const dmg = estimateDamageMeta(ctx, meta); // HeuristicCPUBase.sol:580
    if (dmg > bestDamage) bestDamage = dmg; // HeuristicCPUBase.sol:581
    if (moves[i].moveIndex === targetMoveIndex) {
      preferredIdx = i; // HeuristicCPUBase.sol:584-585
      preferredDamage = dmg;
    }
  }

  if (preferredIdx < 0) return -1; // HeuristicCPUBase.sol:592
  if (bestDamage === 0) return preferredIdx; // HeuristicCPUBase.sol:593 — no damage reference

  // HeuristicCPUBase.sol:596-598 — preferred is "good enough" if within 85% of best damage.
  if (preferredDamage * 100 >= bestDamage * SIMILAR_DAMAGE_THRESHOLD) {
    return preferredIdx;
  }
  return -1;
}

/**
 * Port of `_tryFreeTurnMatchupSwitch`: pick a switch candidate whose offensive matchup against the
 * opponent's active mon beats the current mon's by >= SWITCH_THRESHOLD. Returns the position INTO
 * `switches`, or -1 when no candidate clears the bar (caller falls through to the best-damage
 * default). HeuristicCPUBase.sol:519-552
 */
export function tryFreeTurnMatchupSwitch(
  e: any,
  bk: Hex,
  activeMonIndex: number,
  opponentMonIndex: number,
  switches: RevealedMove[],
): number {
  const oppStats = e.getMonStatsForBattle(bk, OPP_PLAYER_INDEX, BigInt(opponentMonIndex));
  const oppType1 = oppStats.type1 as Type;
  const oppType2 = oppStats.type2 as Type;

  // HeuristicCPUBase.sol:527-531 — current mon's offensive matchup is the bar to beat.
  const ourStats = e.getMonStatsForBattle(bk, CPU_PLAYER_INDEX, BigInt(activeMonIndex));
  const currentScore = offensiveMatchupScore(ourStats.type1 as Type, ourStats.type2 as Type, oppType1, oppType2);

  let bestScore = currentScore; // HeuristicCPUBase.sol:533
  let bestIdx = -1;
  for (let i = 0; i < switches.length; i++) {
    const candStats = e.getMonStatsForBattle(bk, CPU_PLAYER_INDEX, BigInt(switches[i].extraData));
    const score = offensiveMatchupScore(candStats.type1 as Type, candStats.type2 as Type, oppType1, oppType2);
    if (score > bestScore) {
      bestScore = score;
      bestIdx = i;
    }
  }

  // HeuristicCPUBase.sol:548-550 — require a >= SWITCH_THRESHOLD improvement over current.
  if (bestIdx >= 0 && bestScore >= currentScore + SWITCH_THRESHOLD) {
    return bestIdx;
  }
  return -1;
}

// ---------------------------------------------------------------------------------------------
// Utility  (HeuristicCPUBase.sol:494-625)
// ---------------------------------------------------------------------------------------------

/** Port of `_popcount8`: count set bits in an 8-bit bitmap. HeuristicCPUBase.sol:494-499 */
export function popcount8(bitmap: number): number {
  let count = 0;
  for (let i = 0; i < 8; i++) {
    if (((bitmap >> i) & 1) === 1) count++;
  }
  return count;
}

/**
 * Port of `_hasMomentum` (Diyu D4 step 4): the CPU has momentum if it has MORE mons alive, or — on a
 * tie — its active mon has at least as much stamina as the opponent's active mon. `cpuActiveCurrentStamina`
 * is the CPU active mon's current (base + delta) stamina the caller already has on hand (e.g. off the
 * shared BattleView). HeuristicCPUBase.sol:503-514
 */
export function hasMomentum(
  e: any,
  bk: Hex,
  p1TeamSize: number,
  p1KOBitmap: number,
  p0TeamSize: number,
  p0KOBitmap: number,
  p0ActiveMonIndex: number,
  cpuActiveCurrentStamina: number,
): boolean {
  const ourAlive = p1TeamSize - popcount8(p1KOBitmap); // HeuristicCPUBase.sol:504
  const theirAlive = p0TeamSize - popcount8(p0KOBitmap); // HeuristicCPUBase.sol:505
  if (ourAlive > theirAlive) return true; // HeuristicCPUBase.sol:506
  if (ourAlive < theirAlive) return false; // HeuristicCPUBase.sol:507

  // HeuristicCPUBase.sol:509-513 — tie: compare active-mon stamina (>= ours wins the tie).
  const ourStam = cpuActiveCurrentStamina;
  const theirBase = Number(e.getMonValueForBattle(bk, OPP_PLAYER_INDEX, BigInt(p0ActiveMonIndex), MonStateIndexName.Stamina));
  const theirDelta = Number(e.getMonStateForBattle(bk, OPP_PLAYER_INDEX, BigInt(p0ActiveMonIndex), MonStateIndexName.Stamina));
  const theirStam = theirBase + theirDelta;
  return ourStam >= theirStam;
}

/**
 * Port of `_pickRandomValidOption`: pick uniformly across `noOp ++ moves ++ switches` (the valid
 * action set `_calculateValidMoves` already produced). The Solidity uses the high bits of one rng word
 * for the index so a separate trigger roll and this index don't share entropy — replicated here as a
 * single fresh uniform draw over the union. HeuristicCPUBase.sol:612-625
 */
export function pickRandomValidOption(
  rng: () => number,
  noOp: RevealedMove[],
  moves: RevealedMove[],
  switches: RevealedMove[],
): RevealedMove {
  const total = noOp.length + moves.length + switches.length; // HeuristicCPUBase.sol:618
  let idx = Math.floor(rng() * total); // HeuristicCPUBase.sol:619 — (rng >> 8) % total, uniform over [0,total)
  if (idx < noOp.length) return noOp[idx]; // HeuristicCPUBase.sol:620
  idx -= noOp.length; // HeuristicCPUBase.sol:621
  if (idx < moves.length) return moves[idx]; // HeuristicCPUBase.sol:622
  idx -= moves.length; // HeuristicCPUBase.sol:623
  return switches[idx]; // HeuristicCPUBase.sol:624
}
