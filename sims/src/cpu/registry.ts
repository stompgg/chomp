import { CpuStrategy } from './strategy';
import { HardCpu } from './strategies/hard-cpu';
import { GreedyEvalCpu } from './strategies/greedy-eval';
import { OverrideCpu } from './strategies/override-cpu';

/**
 * CPU strategy registry — trimmed to the three strategies the balance arena exercises:
 *   - `hard`     -> HardCpu (peek + best-respond, sim-measured damage, guarded setup punishment)
 *   - `greedy`   -> GreedyEvalCpu (1-ply forward-model + evaluator best response)
 *   - `override` -> OverrideCpu (scripted per-mon plans, else delegates to hard)
 *
 * Strategy INSTANCES are shared singletons; per-battle MUTABLE state lives in the `StrategyState` bag
 * the caller owns (`createState()` + thread it back into `decide`), so one instance is safe across battles.
 */
export const CPU_STRATEGIES = new Map<string, CpuStrategy>([
  ['hard', new HardCpu()],
  ['greedy', new GreedyEvalCpu()],
  ['override', new OverrideCpu()],
]);

/** Register (or replace) a strategy under `key`. Returns the registry for chaining. */
export function registerCpuStrategy(key: string, strategy: CpuStrategy): Map<string, CpuStrategy> {
  return CPU_STRATEGIES.set(key, strategy);
}

/** Look up a strategy by key, or `undefined` if none is registered. */
export function getCpuStrategy(key: string): CpuStrategy | undefined {
  return CPU_STRATEGIES.get(key);
}
