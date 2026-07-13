import { Hex } from './hex';
import { MoveClass, MonStateIndexName, Type } from '../../../transpiler/ts-output/Enums';
import { moveSlotLib } from '../../../transpiler/ts-output/moves/MoveSlotLib';
import { typeCalcLib } from '../../../transpiler/ts-output/types/TypeCalcLib';
import { SWITCH_MOVE_INDEX, NO_OP_INDEX } from './constants';

/**
 * Idiomatic TS port of the SHARED on-chain CPU base (`CPU.sol`):
 *   - `_calculateValidMoves`  -> {@link calculateValidMoves}
 *   - `_sampleRNG` / `getRNG` -> {@link makeRng} (a simple injected PRNG; chain parity is NOT needed
 *      because whatever we submit is just a *legal* move; only the DISTRIBUTION of random draws must
 *      match — see the fidelity notes on each random pick).
 *   - the validation helpers (`_validateCPUMove*` / `ValidatorLogic`) -> the local engine's
 *      `validatePlayerMoveForBattle`, which runs the inline validator when `validator == 0` (the
 *      local case), so it is the faithful equivalent of `CPU._validateCPUMove`.
 *   - `_buildCPUContext` reads -> the small native readers below.
 *
 * The CPU is ALWAYS p1 (playerIndex 1n); the human opponent is p0 (0n). `e` is the LOCAL transpiled
 * engine (LocalBattleService.getEngine). This module is heuristic-free — it provides the shared
 * candidate-enumeration + readers that the OkayCPU / FairCPU / BetterCPU ports build their decisions
 * on. (`MoveMeta` caching and the inline-vs-engine validation split are gas scaffolding and are
 * intentionally dropped per the FIDELITY MANDATE.)
 */

// The CPU's player index. CPU.sol hard-codes p1 everywhere (`_buildCPUContext`, `_validateCPUMove`
// pass playerIndex 1).
const CPU_PLAYER_INDEX = 1n;
const OPP_PLAYER_INDEX = 0n;

// NUM_MOVES in CPU.sol is the engine's DEFAULT_MOVES_PER_MON (4). We read the active mon's actual
// move slots and stop at the first empty slot so <4-move mons are handled exactly like
// `_buildCPUContext` (which caps `len` at the mon's real `moves.length`).
const MAX_MOVES = 4;

export type RevealedMove = { moveIndex: number; extraData: number };

// ---------------------------------------------------------------------------------------------
// RNG
// ---------------------------------------------------------------------------------------------

/**
 * Simple deterministic PRNG (mulberry32) returning a float in [0, 1). Whatever it returns is
 * submitted as the CPU move, so there is NO chain-parity requirement — the only contract is that
 * the *distribution* of draws reproduces the Solidity `_sampleRNG(...) % N` uniform picks. A
 * Solidity `_getRNG % 6 == 5` becomes `rng() < 1/6`; a uniform pick among N candidates becomes
 * `Math.floor(rng() * N)`.
 */
export function makeRng(seed: number = (Math.random() * 0x100000000) >>> 0): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// ---------------------------------------------------------------------------------------------
// Small readers (the state CPU.sol's `_buildCPUContext` pulls off the engine)
// ---------------------------------------------------------------------------------------------

/**
 * Active mon indices [p0, p1]. The transpiled `getActiveMonIndexForBattleState` already UNPACKS to
 * a 2-element array `[p0Index, p1Index]` (it is NOT a packed byte pair in the local engine — the
 * on-chain `data.activeMonIndex` packing is hidden behind the getter), so we read it directly.
 */
export function activeMonIndices(e: any, bk: Hex): [number, number] {
  const r = e.getActiveMonIndexForBattleState(bk);
  return [Number(r[0]), Number(r[1])];
}

export function cpuActiveMonIndex(e: any, bk: Hex): number {
  return activeMonIndices(e, bk)[1];
}

export function oppActiveMonIndex(e: any, bk: Hex): number {
  return activeMonIndices(e, bk)[0];
}

export function teamSize(e: any, bk: Hex, playerIndex: bigint): number {
  return Number(e.getTeamSize(bk, playerIndex));
}

export function cpuTeamSize(e: any, bk: Hex): number {
  return teamSize(e, bk, CPU_PLAYER_INDEX);
}

export function oppTeamSize(e: any, bk: Hex): number {
  return teamSize(e, bk, OPP_PLAYER_INDEX);
}

export function koBitmap(e: any, bk: Hex, playerIndex: bigint): number {
  return Number(e.getKOBitmap(bk, playerIndex));
}

export function isMonKO(e: any, bk: Hex, playerIndex: bigint, monIndex: number): boolean {
  return (koBitmap(e, bk, playerIndex) & (1 << monIndex)) !== 0;
}

// Base stamina (max) of a mon — `cpuActiveMonBaseStamina` in CPUContext.
export function monBaseStamina(e: any, bk: Hex, playerIndex: bigint, monIndex: number): number {
  return Number(e.getMonValueForBattle(bk, playerIndex, BigInt(monIndex), MonStateIndexName.Stamina));
}

// staminaDelta (the engine getter already normalizes the CLEARED sentinel to 0).
export function monStaminaDelta(e: any, bk: Hex, playerIndex: bigint, monIndex: number): number {
  return Number(e.getMonStateForBattle(bk, playerIndex, BigInt(monIndex), MonStateIndexName.Stamina));
}

// Current stamina = base + delta (matches ValidatorLogic.validateSpecificMoveSelection's arithmetic).
export function monCurrentStamina(e: any, bk: Hex, playerIndex: bigint, monIndex: number): number {
  return monBaseStamina(e, bk, playerIndex, monIndex) + monStaminaDelta(e, bk, playerIndex, monIndex);
}

export function monHpDelta(e: any, bk: Hex, playerIndex: bigint, monIndex: number): number {
  return Number(e.getMonStateForBattle(bk, playerIndex, BigInt(monIndex), MonStateIndexName.Hp));
}

// Base (max) HP of a mon — the value getter, no delta.
export function monMaxHp(e: any, bk: Hex, playerIndex: bigint, monIndex: number): number {
  return Number(e.getMonValueForBattle(bk, playerIndex, BigInt(monIndex), MonStateIndexName.Hp));
}

// Current HP = base + delta (the engine getter normalizes the CLEARED sentinel to 0).
export function monCurrentHp(e: any, bk: Hex, playerIndex: bigint, monIndex: number): number {
  return monMaxHp(e, bk, playerIndex, monIndex) + monHpDelta(e, bk, playerIndex, monIndex);
}

// Current speed = base + delta (the speed-race sibling of monCurrentStamina).
export function monCurrentSpeed(e: any, bk: Hex, playerIndex: bigint, monIndex: number): number {
  const base = Number(e.getMonValueForBattle(bk, playerIndex, BigInt(monIndex), MonStateIndexName.Speed));
  const delta = Number(e.getMonStateForBattle(bk, playerIndex, BigInt(monIndex), MonStateIndexName.Speed));
  return base + delta;
}

// Mon types as [type1, type2]. type2 may be Type.None for single-type mons.
export function monTypes(e: any, bk: Hex, playerIndex: bigint, monIndex: number): [Type, Type] {
  return [
    Number(e.getMonValueForBattle(bk, playerIndex, BigInt(monIndex), MonStateIndexName.Type1)) as Type,
    Number(e.getMonValueForBattle(bk, playerIndex, BigInt(monIndex), MonStateIndexName.Type2)) as Type,
  ];
}

// Raw move slot (bigint) for a mon's move index, or undefined past the mon's real move count
// (the transpiled getter indexes `moves[i]`, returning undefined for <4-move mons).
export function moveSlot(e: any, bk: Hex, playerIndex: bigint, monIndex: number, moveIndex: number): bigint | undefined {
  return e.getMoveForMonForBattle(bk, playerIndex, BigInt(monIndex), BigInt(moveIndex));
}

export function moveClassOf(e: any, bk: Hex, slot: bigint): MoveClass {
  return moveSlotLib.moveClass(slot, e, bk) as MoveClass;
}

export function moveTypeOf(e: any, bk: Hex, slot: bigint): Type {
  return moveSlotLib.moveType(slot, e, bk) as Type;
}

// Deployed-move address → its moves.csv InputType ('none' | 'self-mon' | 'opponent-mon') — the
// off-chain replacement for the removed on-chain ExtraDataType, mirroring the Rust port's
// INPUT_TYPE_BY_ADDR. Filled by `buildTeamMon` at team-resolve time (before any game runs).
const INPUT_TYPE_BY_ADDR = new Map<bigint, string>();

export function registerMoveInputType(addr: bigint, inputType: string): void {
  INPUT_TYPE_BY_ADDR.set(addr, inputType);
}

/** InputType of an EXTERNAL move word (address = low 160 bits); 'none' for unknown moves. */
export function moveInputTypeOf(slot: bigint): string {
  return INPUT_TYPE_BY_ADDR.get(slot & ((1n << 160n) - 1n)) ?? 'none';
}

// Deployed-move address → its moves.csv TargetSpec (self-only / none / opponent-slot / …) —
// the client-facing target domain; nibble-free specs (self-only/none) need no target bits.
const TARGET_SPEC_BY_ADDR = new Map<bigint, string>();

export function registerMoveTargetSpec(addr: bigint, targetSpec: string): void {
  TARGET_SPEC_BY_ADDR.set(addr, targetSpec);
}

/** TargetSpec of an EXTERNAL move word; 'any-other-slot' (the blank default) for unknown moves. */
export function moveTargetSpecOf(slot: bigint): string {
  return TARGET_SPEC_BY_ADDR.get(slot & ((1n << 160n) - 1n)) ?? 'any-other-slot';
}

// The opponent's (p0's) revealed move this turn — BetterCPU peeks at this. { moveIndex, extraData }
// with the on-chain packing decoded (low 7 bits = move index; bit 7 = isRealTurn).
export function opponentRevealedMove(e: any, bk: Hex): RevealedMove {
  const d = e.getMoveDecisionForBattleState(bk, OPP_PLAYER_INDEX);
  return { moveIndex: Number(d.packedMoveIndex) & 0x7f, extraData: Number(d.extraData) };
}

// ---------------------------------------------------------------------------------------------
// Type effectiveness primitive — the SAME scaled value the Solidity CPUs compare against.
//
// This is the RAW single-pair primitive `TYPE_CALC.getTypeEffectiveness(attack, defType, scale)`.
// Subclasses MUST compose it exactly as their Solidity counterpart does — there is deliberately NO
// "combined dual-type" helper here, because the Solidity CPUs compose differently per use-site and
// baking one rule in would be an invented heuristic:
//   - OkayCPU.sol:192-196 — move-vs-defender at scale 2: `eff = f(attack, defType1, 2)`, then if
//     defType2 != None `eff *= f(attack, defType2, 2)` (a RAW PRODUCT, no division), comparing
//     `eff > 2` (super-effective) and `eff == 0 || eff == 1` (immune/resist).
//   - HeuristicCPUBase `_offensiveMatchupScore` (scale 10) — a SUM across the type pairs.
// With scale=2 the primitive returns 0 (immune) / 1 (0.5x) / 2 (1x) / 4 (2x); with scale=10 it
// returns 0 / 5 / 10 / 20. Use whatever scale + composition the specific Solidity CPU uses.
// ---------------------------------------------------------------------------------------------

/**
 * `TYPE_CALC.getTypeEffectiveness(attackType, defenderType, scale)` — TypeCalculator.sol delegates
 * straight to TypeCalcLib, so calling the lib directly is the faithful equivalent.
 */
export function typeEffectiveness(attack: Type, defenderType: Type, scale: number): number {
  return Number(typeCalcLib.getTypeEffectiveness(attack, defenderType, BigInt(scale)));
}

// ---------------------------------------------------------------------------------------------
// calculateValidMoves — faithful port of CPU._calculateValidMoves
// ---------------------------------------------------------------------------------------------

function validate(e: any, bk: Hex, moveIndex: number, extraData: number): boolean {
  // Faithful equivalent of CPU._validateCPUMove: the local engine runs the inline validator
  // (validator == 0) for p1.
  return e.validatePlayerMoveForBattle(bk, BigInt(moveIndex), CPU_PLAYER_INDEX, BigInt(extraData)) as boolean;
}

/**
 * Port of `CPU._calculateValidMoves`. Returns the three candidate buckets the subclass heuristics
 * consume. `rng` is only consulted to pick the extraData TARGET for Self/Opponent-index moves (the
 * same place CPU.sol calls `_sampleRNG(...) % count`); pass one if you want deterministic targets.
 *
 * CPU.sol:58-169
 */
export function calculateValidMoves(
  e: any,
  bk: Hex,
  rng: () => number = makeRng(),
): { noOp: RevealedMove[]; moves: RevealedMove[]; switches: RevealedMove[] } {
  const tId = Number(e.getTurnIdForBattleState(bk));
  const p1TeamSize = cpuTeamSize(e, bk);

  // CPU.sol:68-75 — turn 0: every team slot is an (unvalidated) switch-in choice.
  if (tId === 0) {
    const switches: RevealedMove[] = [];
    for (let i = 0; i < p1TeamSize; i++) {
      switches.push({ moveIndex: SWITCH_MOVE_INDEX, extraData: i });
    }
    return { noOp: [], moves: [], switches };
  }

  const activeMonIndex = cpuActiveMonIndex(e, bk);

  // CPU.sol:80-91 — collect valid switch targets (i != active, validated).
  const validSwitchIndices: number[] = [];
  for (let i = 0; i < p1TeamSize; i++) {
    if (i !== activeMonIndex && validate(e, bk, SWITCH_MOVE_INDEX, i)) {
      validSwitchIndices.push(i);
    }
  }

  const validSwitchesArray: RevealedMove[] = validSwitchIndices.map((i) => ({
    moveIndex: SWITCH_MOVE_INDEX,
    extraData: i,
  }));

  // CPU.sol:93-103 — a p1 forced-switch turn (playerSwitchForTurnFlag === 1) returns ONLY valid switches.
  if (Number(e.getBattleContext(bk).playerSwitchForTurnFlag) === 1) {
    return { noOp: [], moves: [], switches: validSwitchesArray };
  }

  // CPU.sol:108-152 — enumerate valid moves. For each move slot pick a valid extraData target the
  // way _calculateValidMoves does (random among the legal targets), then validate.
  const moves: RevealedMove[] = [];
  for (let i = 0; i < MAX_MOVES; i++) {
    const slot = moveSlot(e, bk, CPU_PLAYER_INDEX, activeMonIndex, i);
    if (slot === undefined) break; // <4-move mon: stop at the real move count (mirrors len cap)

    let extraDataToUse = 0;

    if (!moveSlotLib.isInline(slot)) {
      // The engine dropped the on-chain ExtraDataType getter; consult the off-chain InputType
      // (moves.csv) instead, a uniform pick like the old CPU._calculateValidMoves (Rust-port parity).
      const it = moveInputTypeOf(slot);

      if (it === 'self-mon') {
        // Needs a self switch target; skip the move if there are none.
        if (validSwitchIndices.length === 0) continue;
        const r = Math.floor(rng() * validSwitchIndices.length);
        extraDataToUse = validSwitchIndices[r];
      } else if (it === 'opponent-mon') {
        // Build non-KO opponent targets; skip the move if there are none.
        const opponentTeamSize = oppTeamSize(e, bk);
        const oppKO = koBitmap(e, bk, OPP_PLAYER_INDEX);
        const validTargets: number[] = [];
        for (let j = 0; j < opponentTeamSize; j++) {
          if ((oppKO & (1 << j)) === 0) validTargets.push(j);
        }
        if (validTargets.length === 0) continue;
        const r = Math.floor(rng() * validTargets.length);
        extraDataToUse = validTargets[r];
      }
      // 'none' / inline moves fall through with extraData 0.
    }

    // CPU.sol:149-151 — validate the candidate (stamina + move-specific) and keep it if legal.
    if (validate(e, bk, i, extraDataToUse)) {
      moves.push({ moveIndex: i, extraData: extraDataToUse });
    }
  }

  // CPU.sol:164-165 — a single no-op is always offered on a non-forced-switch turn.
  const noOp: RevealedMove[] = [{ moveIndex: NO_OP_INDEX, extraData: 0 }];

  return { noOp, moves, switches: validSwitchesArray };
}

// Uniform pick among a candidate list (the shape every subclass uses for "pick one of N"). Returns
// undefined for an empty list so callers can fall back the way the Solidity CPUs do.
export function pickUniform<T>(arr: T[], rng: () => number): T | undefined {
  if (arr.length === 0) return undefined;
  return arr[Math.floor(rng() * arr.length)];
}
