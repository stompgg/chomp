/**
 * SEARCH CPU — TS port of the Rust depth-limited simultaneous-move maximin search
 * (`transpiler/strategies-rs/src/search.rs`).
 *
 * At each ply both sides' candidate actions (moves + switches + rest — rest is ALWAYS a
 * candidate, the rest-bug lesson) form a matrix game; the backup is maximin (worst-case
 * opponent), leaves score through the linear evaluator. Two variants:
 *   - no-peek: full my×opp grid at the root (production commit-reveal semantics);
 *   - peek-at-root: best-respond to the revealed `playerMove` (single opponent column),
 *     maximin only deeper (arena/p1 reveal semantics).
 * Terminal wins are mate-distance discounted (faster wins / later losses score better).
 *
 * Determinism: fixed salt 0 on every hypothetical; earliest-candidate tie-break. A throwing
 * hypothetical (an unreachable/reverting line) is contained to the decision via try/catch →
 * first legal fallback. Forks are disposed depth-first (only O(depth) live at once).
 */
import { Hex } from '../hex';
import { captureBattleView, type BattleView } from '../battle-view';
import { calculateValidMoves, makeRng, type RevealedMove } from '../engine-view';
import { applyHypotheticalMoveKeyed, disposeFork, type HypotheticalMove } from '../forward-model';
import { scoreState } from '../evaluator';
import { transposeEngine } from '../../arena/transpose';
import { NO_OP_INDEX } from '../constants';
import { BaseCpuStrategy, type CpuMove, type PlayerMove, type StrategyState } from '../strategy';

const MAX_DEPTH = 3;
const MAX_ACTIONS = 8; // 4 moves + 3 switches + rest — never truncates in singles
const WIN = 1e9;
const LOSS = -1e9;
const SALT = 0n;

function hypo(m: RevealedMove | PlayerMove): HypotheticalMove {
  return { moveIndex: m.moveIndex, salt: SALT, extraData: m.extraData };
}

// Candidate enumeration draws payload targets from a NODE-LOCAL fixed-seed rng, so the tree is
// independent of visit order — that's what makes the row prune truly argmax-invariant (a shared
// stream would shift every later node's picks when a branch is skipped).
const ENUM_SEED = 0x5eed;

/** All candidate actions for the engine-perspective CPU at `key`: moves + switches + rest. */
function candidates(e: any, key: Hex): RevealedMove[] {
  const v = calculateValidMoves(e, key, makeRng(ENUM_SEED));
  return [...v.moves, ...v.switches, ...v.noOp].slice(0, MAX_ACTIONS);
}

/** Both sides' action lists given the (seat-relative) switch flag; a non-acting side is [null]. */
function actionLists(
  e: any,
  key: Hex,
  flag: number,
): { my: Array<RevealedMove | null>; opp: Array<RevealedMove | null> } {
  const my: Array<RevealedMove | null> = flag !== 0 ? candidates(e, key) : [null];
  const opp: Array<RevealedMove | null> = flag !== 1 ? candidates(transposeEngine(e), key) : [null];
  return { my: my.length ? my : [null], opp: opp.length ? opp : [null] };
}

/** Recursive maximin value of the position at `key`, CPU-perspective. */
function value(e: any, key: Hex, depth: number): number {
  const view = captureBattleView(e, key);
  const cpuAlive = view.mons.p1.filter((m) => !m.ko).length;
  const oppAlive = view.mons.p0.filter((m) => !m.ko).length;
  // Mate-distance discounting: more remaining depth = terminal reached sooner.
  if (oppAlive <= 0) return WIN + depth;
  if (cpuAlive <= 0) return LOSS - depth;
  if (depth <= 0) return scoreState(view);

  const { my, opp } = actionLists(e, key, view.switchFlag);
  let best = -Infinity;
  for (const a of my) {
    let worst = Infinity;
    for (const o of opp) {
      const child = applyHypotheticalMoveKeyed(e, key, o ? hypo(o) : null, a ? hypo(a) : null);
      const v = value(e, child, depth - 1);
      disposeFork(e, child);
      if (v < worst) worst = v;
      if (worst <= best) break; // row can no longer beat the best row — argmax-invariant prune
    }
    if (worst > best) best = worst;
  }
  return best;
}

function fallback(e: any, bk: Hex, view: BattleView, rng: () => number): CpuMove {
  if (view.switchFlag === 0) return { moveIndex: NO_OP_INDEX, extraData: 0 };
  const v = calculateValidMoves(e, bk, rng);
  const first = v.moves[0] ?? v.switches[0] ?? v.noOp[0];
  return first ?? { moveIndex: NO_OP_INDEX, extraData: 0 };
}

/** Depth-`depth` maximin search; `peek` = best-respond to the revealed move at the root. */
export class SearchCpu extends BaseCpuStrategy {
  constructor(
    readonly name: string,
    private readonly depth: number,
    private readonly peek: boolean,
  ) {
    super();
  }

  decide(view: BattleView, playerMove: PlayerMove, rng: () => number, _state: StrategyState): CpuMove {
    try {
      return this.decideInner(view, playerMove, rng);
    } catch {
      return fallback(view.engine, view.bk as Hex, view, rng);
    }
  }

  private decideInner(view: BattleView, playerMove: PlayerMove, _rng: () => number): CpuMove {
    const depth = Math.max(1, Math.min(MAX_DEPTH, this.depth));
    const e = view.engine;
    const bk = view.bk as Hex;

    // CPU passive (opp forced-switch) — nothing to choose.
    if (view.switchFlag === 0) return { moveIndex: NO_OP_INDEX, extraData: 0 };

    const { my, opp: oppFull } = actionLists(e, bk, view.switchFlag);
    // Peek-at-root: the opponent's move IS revealed → a single opponent column.
    const opp = this.peek && view.switchFlag !== 1 ? [playerMove as RevealedMove] : oppFull;

    let best: CpuMove = my[0] ?? { moveIndex: NO_OP_INDEX, extraData: 0 };
    let bestVal = -Infinity;
    for (const a of my) {
      let worst = Infinity;
      for (const o of opp) {
        const child = applyHypotheticalMoveKeyed(e, bk, o ? hypo(o) : null, a ? hypo(a) : null);
        const v = value(e, child, depth - 1);
        disposeFork(e, child);
        if (v < worst) worst = v;
        if (worst <= bestVal) break; // this action can no longer win the argmax — prune
      }
      // Strict >: ties keep the earliest candidate (moves before switches) — deterministic.
      if (worst > bestVal && a) {
        bestVal = worst;
        best = a;
      }
    }
    return best;
  }
}
