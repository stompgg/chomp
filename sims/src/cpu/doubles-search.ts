/**
 * DOUBLES SEARCH — TS port of the Rust doubles joint maximin (`strategies-rs/src/doubles.rs`,
 * search half) plus the greedy pilot it benchmarks against.
 *
 * Doubles differs from singles in three ways handled here: two active mons per side at absolute
 * slots 0-3 (side = absSlot >> 1), a move targets a SLOT via extraData's target nibble (bits
 * 12-15), and `playerSwitchForTurnFlag` is a bitmask of which absolute slots must forced-switch
 * (not the singles 0/1/2).
 *
 * Per-slot candidates: TOP-damage (move,target) options with per-target diversity (the best
 * option against EACH live enemy slot is always kept), nibble-free status/setup moves
 * (self-only / none TargetSpec), a pivot switch, and rest — bench/rest never truncated away.
 * Joint actions are the slot-candidate cartesian product; forced half-turns resolve without
 * consuming depth; terminal values are mate-distance discounted; the row prune is
 * argmax-invariant (doubles enumeration draws no rng at all).
 */
import { Hex } from './hex';
import { MoveClass, MonStateIndexName } from '../../../transpiler/ts-output/Enums';
import { moveSlotLib } from '../../../transpiler/ts-output/moves/MoveSlotLib';
import { buildDamageCalcContext, estimateDamageMeta } from './heuristic-shared';
import { koBitmap, monCurrentHp, monCurrentStamina, moveSlot, moveInputTypeOf, moveTargetSpecOf, teamSize } from './engine-view';
import { applyHypotheticalSlotMoveKeyed, disposeFork, packSide } from './forward-model';

const SWITCH = 125;
const NO_OP = 126;
const EMPTY_LANE = 0xff;
const MAX_DAMAGING = 3;
const MAX_STATUS = 2;
const WIN = 1e9;
const LOSS = -1e9;
// Linear 2-slot evaluator weights (mirrors the Rust doubles_eval).
const D_W_HP = 1.0;
const D_W_KO = 150.0;
const D_W_STAMINA = 2.0;

export interface SlotMove {
  moveIndex: number;
  extraData: number;
}
const NO_OP_MOVE: SlotMove = { moveIndex: NO_OP, extraData: 0 };
const sw = (i: number): SlotMove => ({ moveIndex: SWITCH, extraData: i });

/** The two absolute slots owned by a side (0 → [0,1], 1 → [2,3]). */
const sideSlots = (side: 0 | 1): [number, number] => (side === 0 ? [0, 1] : [2, 3]);

/** Target nibble: a bitmask with bit `absSlot` set, in extraData bits 12-15. */
const targetBits = (absSlot: number): number => 1 << (12 + absSlot);

function activeSlots(e: any, bk: Hex): number[] {
  return (e.getActiveSlots(bk) as bigint[]).map((s) => Number(s));
}

function teamSizeOf(e: any, bk: Hex, side: 0 | 1): number {
  return teamSize(e, bk, BigInt(side));
}

function monMaxHp(e: any, bk: Hex, side: 0 | 1, mon: number): number {
  return Number(e.getMonValueForBattle(bk, BigInt(side), BigInt(mon), MonStateIndexName.Hp));
}

/** Every affordable damaging (move, target-slot) for `myMon` on `side`, with estimated damage. */
function damagingOptions(e: any, bk: Hex, side: 0 | 1, myMon: number): Array<{ sm: SlotMove; dmg: number }> {
  const oppSide = (1 - side) as 0 | 1;
  const slots = activeSlots(e, bk);
  const oppKo = koBitmap(e, bk, BigInt(oppSide));

  const targets: Array<{ abs: number; mon: number }> = [];
  for (const abs of sideSlots(oppSide)) {
    const mon = slots[abs];
    if (mon !== EMPTY_LANE && (oppKo & (1 << mon)) === 0) targets.push({ abs, mon });
  }
  if (targets.length === 0) return [];

  const stamina = monCurrentStamina(e, bk, BigInt(side), myMon);
  const metas: Array<{ mi: number; meta: any }> = [];
  for (let mi = 0; mi < 4; mi++) {
    const slot = moveSlot(e, bk, BigInt(side), myMon, mi);
    if (slot === undefined) break;
    metas.push({ mi, meta: moveSlotLib.decodeMeta(slot, e, bk, BigInt(side), BigInt(myMon)) });
  }

  const options: Array<{ sm: SlotMove; dmg: number }> = [];
  for (const t of targets) {
    const ctx = buildDamageCalcContext(e, bk, BigInt(side), myMon, BigInt(oppSide), t.mon);
    for (const { mi, meta } of metas) {
      if (Number(meta.stamina) > stamina) continue;
      const cls = Number(meta.moveClass);
      if (cls !== Number(MoveClass.Physical) && cls !== Number(MoveClass.Special)) continue;
      const dmg = estimateDamageMeta(ctx, meta);
      if (dmg > 0) options.push({ sm: { moveIndex: mi, extraData: targetBits(t.abs) }, dmg });
    }
  }
  return options;
}

/** All legal bench targets for a slot: non-KO roster mons not held by either of the side's slots. */
function legalBenches(teamSize: number, ko: number, slots: number[], absSlot: number): number[] {
  const side = absSlot >> 1;
  const allyAbs = side * 2 + (1 - (absSlot & 1));
  const out: number[] = [];
  for (let i = 0; i < teamSize; i++) {
    if ((ko & (1 << i)) === 0 && i !== slots[allyAbs] && i !== slots[absSlot]) out.push(i);
  }
  return out;
}

function firstLegalBench(teamSize: number, ko: number, slots: number[], absSlot: number): number {
  const b = legalBenches(teamSize, ko, slots, absSlot);
  return b.length ? b[0] : -1;
}

/** Per-slot candidates on a normal turn (see module doc). Empty lane → rest only. */
function slotCandidates(e: any, bk: Hex, side: 0 | 1, absSlot: number, slots: number[], teamSize: number): SlotMove[] {
  const myMon = slots[absSlot];
  if (myMon === EMPTY_LANE) return [NO_OP_MOVE];

  const dmg = damagingOptions(e, bk, side, myMon).sort((a, b) => b.dmg - a.dmg);
  // Best option per distinct target first (≤2 live slots), then next-best overall.
  const out: SlotMove[] = [];
  const seenTargets = new Set<number>();
  for (const o of dmg) {
    if (!seenTargets.has(o.sm.extraData)) {
      seenTargets.add(o.sm.extraData);
      out.push(o.sm);
    }
  }
  for (const o of dmg) {
    if (out.length >= MAX_DAMAGING) break;
    if (!out.some((s) => s.moveIndex === o.sm.moveIndex && s.extraData === o.sm.extraData)) out.push(o.sm);
  }
  out.length = Math.min(out.length, MAX_DAMAGING);

  // Status/setup moves (non-damaging class, affordable, nibble-free targeting): extraData 0.
  const stamina = monCurrentStamina(e, bk, BigInt(side), myMon);
  let nStatus = 0;
  for (let mi = 0; mi < 4 && nStatus < MAX_STATUS; mi++) {
    const slot = moveSlot(e, bk, BigInt(side), myMon, mi);
    if (slot === undefined) break;
    if (moveSlotLib.isInline(slot)) continue; // inline words are standard attacks
    const meta = moveSlotLib.decodeMeta(slot, e, bk, BigInt(side), BigInt(myMon));
    const cls = Number(meta.moveClass);
    if (cls === Number(MoveClass.Physical) || cls === Number(MoveClass.Special)) continue;
    if (Number(meta.stamina) > stamina) continue;
    const spec = moveTargetSpecOf(slot);
    if ((spec === 'self-only' || spec === 'none') && moveInputTypeOf(slot) === 'none') {
      out.push({ moveIndex: mi, extraData: 0 });
      nStatus++;
    }
  }

  const bench = firstLegalBench(teamSize, koBitmap(e, bk, BigInt(side)), slots, absSlot);
  if (bench >= 0) out.push(sw(bench));
  out.push(NO_OP_MOVE);
  return out;
}

/** Joint (slot0, slot1) actions for a side on a normal turn. */
function sideJoint(e: any, bk: Hex, side: 0 | 1): Array<[SlotMove, SlotMove]> {
  const [a0, a1] = sideSlots(side);
  const slots = activeSlots(e, bk);
  const ts = teamSizeOf(e, bk, side);
  const c0 = slotCandidates(e, bk, side, a0, slots, ts);
  const c1 = slotCandidates(e, bk, side, a1, slots, ts);
  const out: Array<[SlotMove, SlotMove]> = [];
  for (const m0 of c0) for (const m1 of c1) out.push([m0, m1]);
  return out;
}

/** Fork one slot-turn from `bk`: `mine` = cpuSide's joint, `theirs` = the opponent's. */
function forkJoint(e: any, bk: Hex, cpuSide: 0 | 1, mine: [SlotMove, SlotMove], theirs: [SlotMove, SlotMove]): Hex {
  const myWord = packSide(mine[0].moveIndex, mine[0].extraData, mine[1].moveIndex, mine[1].extraData, 0n);
  const thWord = packSide(theirs[0].moveIndex, theirs[0].extraData, theirs[1].moveIndex, theirs[1].extraData, 0n);
  const [s0, s1] = cpuSide === 0 ? [myWord, thWord] : [thWord, myWord];
  return applyHypotheticalSlotMoveKeyed(e, bk, s0, s1);
}

/** Σ hp% over a side's whole roster. */
function sideRosterHp(e: any, bk: Hex, side: 0 | 1, teamSize: number): number {
  let sum = 0;
  for (let i = 0; i < teamSize; i++) {
    const mhp = monMaxHp(e, bk, side, i);
    if (mhp <= 0) continue;
    sum = sum + (Math.max(0, monCurrentHp(e, bk, BigInt(side), i)) * 100) / mhp;
  }
  return sum;
}

function sideActiveStamina(e: any, bk: Hex, side: 0 | 1, slots: number[]): number {
  let sum = 0;
  for (const abs of sideSlots(side)) {
    const mon = slots[abs];
    if (mon !== EMPTY_LANE) sum += monCurrentStamina(e, bk, BigInt(side), mon);
  }
  return sum;
}

const popcount = (b: number): number => {
  let c = 0;
  for (let x = b; x; x &= x - 1) c++;
  return c;
};

/** Linear 2-slot position value, `cpuSide`-perspective (higher = better). */
function doublesEval(e: any, bk: Hex, cpuSide: 0 | 1): number {
  const oppSide = (1 - cpuSide) as 0 | 1;
  const hp = sideRosterHp(e, bk, cpuSide, teamSizeOf(e, bk, cpuSide)) - sideRosterHp(e, bk, oppSide, teamSizeOf(e, bk, oppSide));
  const ko = popcount(koBitmap(e, bk, BigInt(oppSide))) - popcount(koBitmap(e, bk, BigInt(cpuSide)));
  const slots = activeSlots(e, bk);
  const stam = sideActiveStamina(e, bk, cpuSide, slots) - sideActiveStamina(e, bk, oppSide, slots);
  return D_W_HP * hp + D_W_KO * ko + D_W_STAMINA * stam;
}

/** Terminal value if a side is fully KO'd (mate-distance discounted), else null. */
function terminal(e: any, bk: Hex, cpuSide: 0 | 1, depth: number): number | null {
  const oppSide = (1 - cpuSide) as 0 | 1;
  if (popcount(koBitmap(e, bk, BigInt(oppSide))) >= teamSizeOf(e, bk, oppSide)) return WIN + depth;
  if (popcount(koBitmap(e, bk, BigInt(cpuSide))) >= teamSizeOf(e, bk, cpuSide)) return LOSS - depth;
  return null;
}

/** A side's deterministic forced-switch resolution (first-legal bench per masked slot). */
function forcedJointModel(e: any, bk: Hex, side: 0 | 1, mask: number, slots: number[]): [SlotMove, SlotMove] {
  const ts = teamSizeOf(e, bk, side);
  const ko = koBitmap(e, bk, BigInt(side));
  const pick = (abs: number): SlotMove => {
    if ((mask & (1 << abs)) === 0) return NO_OP_MOVE;
    const b = firstLegalBench(ts, ko, slots, abs);
    return b >= 0 ? sw(b) : NO_OP_MOVE;
  };
  const [a0, a1] = sideSlots(side);
  return [pick(a0), pick(a1)];
}

const isNoOpJoint = (j: [SlotMove, SlotMove]): boolean =>
  j[0].moveIndex === NO_OP && j[1].moveIndex === NO_OP;

/** Recursive joint maximin value at `bk`, cpuSide-perspective. Forced half-turns don't consume depth. */
function searchValue(e: any, bk: Hex, cpuSide: 0 | 1, depth: number): number {
  const t = terminal(e, bk, cpuSide, depth);
  if (t !== null) return t;
  if (depth <= 0) return doublesEval(e, bk, cpuSide);

  const flag = Number(e.getBattleContext(bk).playerSwitchForTurnFlag);
  if (flag !== 2) {
    const mask = flag & 0x0f;
    const slots = activeSlots(e, bk);
    const mine = forcedJointModel(e, bk, cpuSide, mask, slots);
    const theirs = forcedJointModel(e, bk, (1 - cpuSide) as 0 | 1, mask, slots);
    if (isNoOpJoint(mine) && isNoOpJoint(theirs)) return doublesEval(e, bk, cpuSide); // no resolution — don't loop
    const child = forkJoint(e, bk, cpuSide, mine, theirs);
    const v = searchValue(e, child, cpuSide, depth);
    disposeFork(e, child);
    return v;
  }

  const my = sideJoint(e, bk, cpuSide);
  const opp = sideJoint(e, bk, (1 - cpuSide) as 0 | 1);
  let best = -Infinity;
  for (const mine of my) {
    let worst = Infinity;
    for (const theirs of opp) {
      const child = forkJoint(e, bk, cpuSide, mine, theirs);
      const v = searchValue(e, child, cpuSide, depth - 1);
      disposeFork(e, child);
      if (v < worst) worst = v;
      if (worst <= best) break; // argmax-invariant row prune (enumeration is rng-free)
    }
    if (worst > best) best = worst;
  }
  return best;
}

/** Pick `cpuSide`'s two slot moves by depth-`depth` joint maximin (turn 0 → searched leads;
 *  forced-switch → enumerated bench combos; normal → joint maximin). */
export function searchSideMoves(e: any, bk: Hex, cpuSide: 0 | 1, depth: number): [SlotMove, SlotMove] {
  const [a0, a1] = sideSlots(cpuSide);

  // Turn 0: SEARCH the lead pair — maximin over both sides' send-ins.
  if (Number(e.getTurnIdForBattleState(bk)) === 0) {
    const leadPairs = (n: number): Array<[SlotMove, SlotMove]> => {
      const v: Array<[SlotMove, SlotMove]> = [];
      for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) if (i !== j) v.push([sw(i), sw(j)]);
      return v;
    };
    const my = leadPairs(teamSizeOf(e, bk, cpuSide));
    const opp = leadPairs(teamSizeOf(e, bk, (1 - cpuSide) as 0 | 1));
    let best: [SlotMove, SlotMove] = [sw(0), sw(1)];
    let bestVal = -Infinity;
    for (const mine of my) {
      let worst = Infinity;
      for (const theirs of opp) {
        const child = forkJoint(e, bk, cpuSide, mine, theirs);
        const v = searchValue(e, child, cpuSide, Math.max(0, depth - 1));
        disposeFork(e, child);
        if (v < worst) worst = v;
        if (worst <= bestVal) break;
      }
      if (worst > bestVal) {
        bestVal = worst;
        best = mine;
      }
    }
    return best;
  }

  const flag = Number(e.getBattleContext(bk).playerSwitchForTurnFlag);
  if (flag !== 2) {
    // Forced-switch turn: enumerate my legal bench combos; opponent modeled first-legal.
    const mask = flag & 0x0f;
    const slots = activeSlots(e, bk);
    const ts = teamSizeOf(e, bk, cpuSide);
    const ko = koBitmap(e, bk, BigInt(cpuSide));
    const m0 = (mask & (1 << a0)) !== 0;
    const m1 = (mask & (1 << a1)) !== 0;
    if (!m0 && !m1) return [NO_OP_MOVE, NO_OP_MOVE]; // only the opponent is forced

    const b0 = m0 ? legalBenches(ts, ko, slots, a0) : [];
    const b1 = m1 ? legalBenches(ts, ko, slots, a1) : [];
    const combos: Array<[SlotMove, SlotMove]> = [];
    if (m0 && m1) {
      for (const x of b0) for (const y of b1) if (x !== y) combos.push([sw(x), sw(y)]);
    } else if (m0) {
      for (const x of b0) combos.push([sw(x), NO_OP_MOVE]);
    } else {
      for (const y of b1) combos.push([NO_OP_MOVE, sw(y)]);
    }
    if (combos.length === 0) combos.push([NO_OP_MOVE, NO_OP_MOVE]);

    const theirs = forcedJointModel(e, bk, (1 - cpuSide) as 0 | 1, mask, slots);
    let best = combos[0];
    let bestVal = -Infinity;
    for (const mine of combos) {
      const child = forkJoint(e, bk, cpuSide, mine, theirs);
      const v = searchValue(e, child, cpuSide, depth); // forced turns don't consume depth
      disposeFork(e, child);
      if (v > bestVal) {
        bestVal = v;
        best = mine;
      }
    }
    return best;
  }

  // Normal turn: joint maximin with the row prune.
  const my = sideJoint(e, bk, cpuSide);
  const opp = sideJoint(e, bk, (1 - cpuSide) as 0 | 1);
  let best: [SlotMove, SlotMove] = my[0] ?? [NO_OP_MOVE, NO_OP_MOVE];
  let bestVal = -Infinity;
  for (const mine of my) {
    let worst = Infinity;
    for (const theirs of opp) {
      const child = forkJoint(e, bk, cpuSide, mine, theirs);
      const v = searchValue(e, child, cpuSide, Math.max(0, depth - 1));
      disposeFork(e, child);
      if (v < worst) worst = v;
      if (worst <= bestVal) break;
    }
    if (worst > bestVal) {
      bestVal = worst;
      best = mine;
    }
  }
  return best;
}

/** The epsilon-greedy "Hard" doubles pilot (opt_prob = 1: always the best damaging option) —
 *  the baseline the search benchmarks against, mirroring the Rust `pick_side_moves`. */
export function greedySideMoves(e: any, bk: Hex, side: 0 | 1): [SlotMove, SlotMove] {
  const [a0, a1] = sideSlots(side);
  if (Number(e.getTurnIdForBattleState(bk)) === 0) return [sw(0), sw(1)];

  const flag = Number(e.getBattleContext(bk).playerSwitchForTurnFlag);
  const slots = activeSlots(e, bk);
  const ts = teamSizeOf(e, bk, side);
  if (flag !== 2) {
    return forcedJointModel(e, bk, side, flag & 0x0f, slots);
  }
  const pick = (abs: number): SlotMove => {
    const myMon = slots[abs];
    if (myMon === EMPTY_LANE) return NO_OP_MOVE;
    const options = damagingOptions(e, bk, side, myMon);
    if (options.length === 0) return NO_OP_MOVE;
    let best = options[0];
    for (const o of options) if (o.dmg > best.dmg) best = o;
    return best.sm;
  };
  void ts;
  return [pick(a0), pick(a1)];
}
