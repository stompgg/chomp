import { Hex } from './hex';
import { BattleView } from './battle-view';
import { RevealedMove, calculateValidMoves, pickUniform } from './engine-view';

/**
 * CPU STRATEGY FRAMEWORK — the interface + minimal base class every strategy implements.
 *
 * Every strategy — the difficulty heuristics, personas, and the eval/search tier — implements
 * {@link CpuStrategy}. Strategies read state through the free functions in `engine-view` /
 * `heuristic-shared` / `heuristic-native` and the read-once {@link BattleView} snapshot they're
 * handed — there is no fat wrapper surface; import the helper you need directly.
 *
 * The CPU is ALWAYS p1; the human opponent is p0. The `view` carries `.engine` / `.bk` for the readers
 * not projected onto it.
 */

/** The human (p0) move the CPU is responding to this turn. */
export interface PlayerMove {
  moveIndex: number;
  extraData: number;
}

/** What every strategy returns: the CPU's (p1) chosen move + its extraData target. */
export type CpuMove = { moveIndex: number; extraData: number };

/**
 * Per-(strategy) mutable state bag a strategy may persist across turns. The dispatcher owns it
 * (`createState()` once per strategy, threaded back into every `decide`); hard keys its per-battle
 * setup lane bits on it, stall its status-used bits — stateless strategies just ignore it.
 */
export interface StrategyState {
  [k: string]: unknown;
}

/**
 * A pluggable CPU strategy. `decide` reads the position (via the `view` + free helpers), consults its
 * own `state`, and returns the move. `playerMove` is p0's revealed move (BetterCPU peeks at it).
 */
export interface CpuStrategy {
  readonly name: string;
  /** Build the initial per-strategy state bag. */
  createState(): StrategyState;
  /** Choose the CPU's move for the current turn. */
  decide(view: BattleView, playerMove: PlayerMove, rng: () => number, state: StrategyState): CpuMove;
}

/**
 * Minimal base: a `name`, a default empty `createState`, the abstract `decide`, and the two engine-view
 * helpers strategies actually reach for via `this.` (candidate enumeration + uniform tie-break). Every
 * other engine read is a direct free-function import from `engine-view` / `heuristic-shared`.
 */
export abstract class BaseCpuStrategy implements CpuStrategy {
  abstract readonly name: string;

  createState(): StrategyState {
    return {};
  }

  abstract decide(view: BattleView, playerMove: PlayerMove, rng: () => number, state: StrategyState): CpuMove;

  /** Port of `CPU._calculateValidMoves` — the candidate buckets a strategy chooses from. */
  protected validMoves(
    e: any,
    bk: string,
    rng?: () => number,
  ): { noOp: RevealedMove[]; moves: RevealedMove[]; switches: RevealedMove[] } {
    return calculateValidMoves(e, bk as Hex, rng);
  }

  /** Uniform pick from `arr` with the injected rng (tie-breaks). */
  protected pickUniform<T>(arr: T[], rng: () => number): T | undefined {
    return pickUniform(arr, rng);
  }
}
