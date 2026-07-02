import { Hex } from './hex';
import { makeRng } from './engine-view';
import { captureBattleView } from './battle-view';
import { CPU_STRATEGIES } from './registry';
import { CpuStrategy, StrategyState } from './strategy';

export { CPU_STRATEGIES, registerCpuStrategy, getCpuStrategy } from './registry';
export type { CpuStrategy, CpuMove, PlayerMove, StrategyState } from './strategy';
export { BaseCpuStrategy } from './strategy';

/**
 * Difficulty dispatcher for the local CPU strategies. Routes through {@link CPU_STRATEGIES}:
 * easy -> EasyCpu (greedy attacker), medium -> MediumCpu, hard -> one of the HARD_POOL profiles.
 * Each strategy's bag is lazily created once and threaded back into every `decide` call (hard's setup
 * lane bits and stall's status bits persist there).
 *
 * The signature is UNCHANGED so existing callers (LocalCpuGameService) keep compiling.
 * `playerMoveIndex` / `playerExtraData` form the human's (p0's) revealed move the CPU responds to;
 * both default to 0 when omitted. The CPU is always p1.
 */

// The hard difficulty cycles across the strongest peek-seat profiles (a statistical tie in the
// arena, three very different characters) so repeat battles don't face one learnable policy. The
// pick is battleKey-derived: stable for the whole battle and across reloads, no state to persist.
const HARD_POOL = ['hard', 'planner', 'greedy-risk'] as const;

function resolveStrategyKey(difficulty: 'easy' | 'medium' | 'hard' | 'mirror' | 'greedy', bk: Hex): string {
  if (difficulty !== 'hard') return difficulty;
  return HARD_POOL[Number(BigInt(bk) % BigInt(HARD_POOL.length))];
}

// Lazily-created state bags, keyed by the (shared singleton) strategy instance — one bag per strategy,
// NOT per opponent. A strategy needing per-(opponent, battle) state must key on that itself.
const strategyState = new WeakMap<CpuStrategy, StrategyState>();

function getOrInitState(strat: CpuStrategy): StrategyState {
  let s = strategyState.get(strat);
  if (s === undefined) {
    s = strat.createState();
    strategyState.set(strat, s);
  }
  return s;
}

export function pickCpuMove(
  difficulty: 'easy' | 'medium' | 'hard' | 'mirror' | 'greedy',
  e: any,
  bk: Hex,
  playerMoveIndex: number = 0,
  playerExtraData: number = 0,
  rng: () => number = makeRng(),
): { moveIndex: number; extraData: number } {
  const strat = CPU_STRATEGIES.get(resolveStrategyKey(difficulty, bk));
  if (strat === undefined) {
    // Difficulty is a closed union, so this is unreachable in typed callers; guard for safety.
    throw new Error(`No CPU strategy registered for difficulty "${difficulty}"`);
  }
  const state = getOrInitState(strat);
  // Capture the shared read-once snapshot ONCE per turn; every strategy reads the same view (it also
  // carries `.engine`/`.bk` for readers not projected onto it). captureBattleView consumes no strategy rng.
  const view = captureBattleView(e, bk);
  return strat.decide(view, { moveIndex: playerMoveIndex, extraData: playerExtraData }, rng, state);
}
