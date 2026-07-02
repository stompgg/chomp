import { Hex } from '../hex';
import { BaseCpuStrategy, CpuMove, PlayerMove, StrategyState } from '../strategy';
import { BattleView } from '../battle-view';
import { RevealedMove } from '../engine-view';
import { applyHypotheticalMove, disposeFork, HypotheticalMove } from '../forward-model';
import { DEFAULT_EVAL_WEIGHTS, EvalWeights, scoreStateWith } from '../evaluator';
import { RISK_SALT_OFFSETS, riskAdjustedScore, riskPosture } from '../heuristic-native';

/**
 * GREEDY (eval) — 1-ply best response on the search kit (forward-model + evaluator). NOT a faithful
 * Solidity port; the only contract is that it returns a LEGAL move.
 *
 * Algorithm (from the CPU's (p1's) point of view):
 *   1. Enumerate every legal CPU action via the shared `validMoves` buckets (moves + switches + noOp).
 *   2. For each candidate, fork the live battle and replay ONE turn with the human's REVEALED move as
 *      p0 and the candidate as p1 (`applyHypotheticalMove`). On a forced-switch turn (p1-only) the
 *      human doesn't act, so p0 is passed as `null`.
 *   3. Score the resulting position (higher = better for the CPU); keep every candidate tied for best
 *      and break ties uniformly with the injected rng.
 *
 * Options (the plain `greedy` key uses none):
 *   - `salts: k` — RISK-AWARE mode: sample each candidate with k salt streams and choose by
 *     risk-adjusted score (mean, tilted toward certainty when ahead / variance when behind). One fork
 *     is one RNG realization, so multi-salt sampling also de-noises crits and branchy moves.
 *   - `weights` — score with a custom {@link EvalWeights} (A/B harness for fitted weights).
 *   - `evalFn` — replace the position scorer entirely (e.g. the race-matrix `ttkEval`).
 *
 * The live battle is never mutated — every candidate runs on a throwaway fork.
 */
export class GreedyEvalCpu extends BaseCpuStrategy {
  readonly name: string;
  private readonly salts: number;
  private readonly score: (view: BattleView) => number;

  constructor(opts: { salts?: number; weights?: EvalWeights; evalFn?: (view: BattleView) => number; tag?: string } = {}) {
    super();
    this.salts = opts.salts ?? 1;
    const weights = opts.weights ?? DEFAULT_EVAL_WEIGHTS;
    this.score = opts.evalFn ?? (v => scoreStateWith(v, weights));
    const tags = [
      this.salts > 1 ? `risk k=${this.salts}` : '',
      opts.weights ? 'tuned' : '',
      opts.tag ?? '',
    ].filter(Boolean);
    this.name = `Greedy (eval${tags.length ? ', ' + tags.join(', ') : ''})`;
  }

  override decide(view: BattleView, pm: PlayerMove, rng: () => number, _state: StrategyState): CpuMove {
    const e = view.engine;
    const bk = view.bk;
    // Candidate CPU actions — pass rng so Self/Opponent-index extraData targets are drawn the same
    // way the faithful ports draw them.
    const { noOp, moves, switches } = this.validMoves(e, bk as Hex, rng);
    const candidates: RevealedMove[] = [...moves, ...switches, ...noOp];
    if (candidates.length === 0) {
      return { moveIndex: noOp.length > 0 ? noOp[0].moveIndex : 126, extraData: 0 };
    }

    // Salt streams: the single-sample default keeps the original fixed salt; risk mode draws k
    // turn-seeded streams. Posture comes from the CURRENT position (pure-view, no fork).
    const turnSalt = BigInt(Number(e.getTurnIdForBattleState(bk)) + 1);
    const saltList: bigint[] =
      this.salts <= 1 ? [0n] : RISK_SALT_OFFSETS.slice(0, this.salts).map(o => turnSalt * 4099n + o);
    const posture = this.salts <= 1 ? 0 : riskPosture(this.score(view));

    // The human (p0) move this turn. On a forced-switch turn (switchFlag === 1) p0 does not act.
    const p0Acts = view.switchFlag !== 1;

    let best: RevealedMove[] = [];
    let bestScore = -Infinity;
    for (const cand of candidates) {
      const samples: number[] = [];
      for (const salt of saltList) {
        const p0Move: HypotheticalMove | null = p0Acts
          ? { moveIndex: pm.moveIndex, salt, extraData: pm.extraData }
          : null;
        const resultView = applyHypotheticalMove(e, bk as Hex, p0Move, {
          moveIndex: cand.moveIndex,
          salt,
          extraData: cand.extraData,
        });
        samples.push(this.score(resultView));
        disposeFork(e, resultView.bk);
      }
      const score = riskAdjustedScore(samples, posture);
      if (score > bestScore) {
        bestScore = score;
        best = [cand];
      } else if (score === bestScore) {
        best.push(cand);
      }
    }

    const chosen = this.pickUniform(best, rng) ?? best[0];
    return { moveIndex: chosen.moveIndex, extraData: chosen.extraData };
  }
}
