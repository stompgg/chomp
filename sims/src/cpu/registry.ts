import { CpuStrategy } from './strategy';
import { HardCpu } from './strategies/hard-cpu';
import { GreedyEvalCpu } from './strategies/greedy-eval';
import { OverrideCpu } from './strategies/override-cpu';
import { SearchCpu } from './strategies/search-cpu';

/**
 * CPU strategy registry — the strategies the balance arena exercises:
 *   - `hard`        -> HardCpu (peek + best-respond, sim-measured damage, guarded setup punishment)
 *   - `greedy`      -> GreedyEvalCpu (1-ply forward-model + evaluator best response)
 *   - `override`    -> OverrideCpu (scripted per-mon plans, else delegates to hard)
 *   - `search`      -> SearchCpu d2, no-peek (maximin matrix game — production reveal semantics)
 *   - `search-peek` -> SearchCpu d2, peek-at-root (best-respond to the reveal, maximin deeper)
 *
 * Strategy INSTANCES are shared singletons; per-battle MUTABLE state lives in the `StrategyState` bag
 * the caller owns (`createState()` + thread it back into `decide`), so one instance is safe across battles.
 */
export const CPU_STRATEGIES = new Map<string, CpuStrategy>([
  ['hard', new HardCpu()],
  ['greedy', new GreedyEvalCpu()],
  ['override', new OverrideCpu()],
  ['search', new SearchCpu('search', 2, false)],
  ['search-peek', new SearchCpu('search-peek', 2, true)],
]);

/** Register (or replace) a strategy under `key`. Returns the registry for chaining. */
export function registerCpuStrategy(key: string, strategy: CpuStrategy): Map<string, CpuStrategy> {
  return CPU_STRATEGIES.set(key, strategy);
}

/** Look up a strategy by key, or `undefined` if none is registered. */
export function getCpuStrategy(key: string): CpuStrategy | undefined {
  return CPU_STRATEGIES.get(key);
}
