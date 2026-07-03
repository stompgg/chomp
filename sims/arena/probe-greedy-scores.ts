/**
 * Probe: what does greedy's own forward model score for each candidate on a board where
 * Inutia's Initialize lock is set? Prints the per-candidate scores so the selection bug's
 * layer (fork vs evaluator vs tie-break) is measured instead of guessed.
 *
 *   bun arena/probe-greedy-scores.ts
 */
import { makeSimContext, startBattle, executeTurn } from '../src/harness';
import { loadRoster } from '../src/util/csv-load';
import { buildTeamMon } from '../src/arena/team';
import { MemoizedInlineRngOracle } from '../src/arena/rng-oracle';
import { captureBattleView } from '../src/cpu/battle-view';
import { applyHypotheticalMove, disposeFork } from '../src/cpu/forward-model';
import { scoreStateWith, DEFAULT_EVAL_WEIGHTS } from '../src/cpu/evaluator';
import * as Constants from '../../transpiler/ts-output/Constants';

const roster = loadRoster();
const monByName = (n: string) => roster.mons.find((r: any) => r.name === n)!;

const ctx = makeSimContext({ monsPerTeam: 1n });
const p0Team = [buildTeamMon(ctx, roster, monByName('Gorillax').id)];
const p1Team = [buildTeamMon(ctx, roster, monByName('Inutia').id)];
const { battleKey } = startBattle(ctx, p0Team, p1Team);
const engine = ctx.engine as any;
engine.battleConfig[engine._getStorageKey(battleKey)].rngOracle = new MemoizedInlineRngOracle();

const SWITCH = Number(Constants.SWITCH_MOVE_INDEX);
const NO_OP = Number(Constants.NO_OP_MOVE_INDEX);

// Leads, then t1: Inutia (p1) casts Initialize for real — lock now set, boost live.
executeTurn(ctx, battleKey, { p0MoveIndex: SWITCH, p1MoveIndex: SWITCH, p0ExtraData: 0n, p1ExtraData: 0n, p0Salt: 1n, p1Salt: 2n });
executeTurn(ctx, battleKey, { p0MoveIndex: NO_OP, p1MoveIndex: 1, p0ExtraData: 0n, p1ExtraData: 0n, p0Salt: 3n, p1Salt: 4n });

// Score each p1 candidate against a revealed p0 rest, exactly as greedy does (salt 0).
const view = captureBattleView(engine, battleKey);
const candidates: Array<[string, number]> = [
  ['Chain Expansion (0)', 0],
  ['Initialize LOCKED (1)', 1],
  ['Big Bite (2)', 2],
  ['Hit And Dip (3)', 3],
  ['rest (126)', NO_OP],
];
console.log('board: p1 Inutia, Initialize cast last turn (lock set, +50% live); p0 Gorillax rests');
for (const [label, idx] of candidates) {
  const fork = applyHypotheticalMove(engine, view.bk as any, { moveIndex: NO_OP, salt: 0n, extraData: 0 }, { moveIndex: idx, salt: 0n, extraData: 0 });
  const score = scoreStateWith(fork, DEFAULT_EVAL_WEIGHTS);
  console.log(`  ${label.padEnd(24)} -> ${score.toFixed(2)}`);
  disposeFork(engine, fork.bk);
}
