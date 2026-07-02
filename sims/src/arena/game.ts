/**
 * Single CPU-vs-CPU game driver for the balance arena, BRIDGED onto chomp's scripted harness
 * (`sims/src/harness.ts`) over `transpiler/ts-output`.
 *
 * Seating (from munch): every strategy assumes it is p1, so the p0 seat reads through `transposeEngine`;
 * the p1 seat gets the true reveal of p0's move (production peek), the p0 seat only the opponent's
 * previous move.
 *
 * Bridge specifics vs the raw chomp harness:
 *   1. After `startBattle`, the battle's rngOracle is patched to the zero-address stub so the engine
 *      derives `rng = keccak256(uint104 p0Salt, uint104 p1Salt)` — matching munch's ZERO-oracle harness
 *      (chomp's harness installs a real DefaultRandomnessOracle with a different encoding).
 *   2. On a forced-switch turn only the acting side is decided AND only its salt is drawn (p0 before p1),
 *      exactly mirroring munch's `toDecision(null)` skip — the shared rng stream must stay in lockstep.
 */
import { CpuStrategy, PlayerMove, StrategyState } from '../cpu/strategy';
import { captureBattleView } from '../cpu/battle-view';
import { NO_OP_INDEX, TEAM_SIZE } from '../cpu/constants';
import { makeSimContext, startBattle, executeTurn, P0_ADDR, P1_ADDR, type SimContext } from '../harness';
import { loadRoster } from '../util/csv-load';
import { buildTeamMon } from './team';
import { transposeEngine } from './transpose';
import { makeRng, randomSalt } from './rng';

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const roster = loadRoster();

export interface Seat {
  strategy: CpuStrategy;
  state: StrategyState;
  engine: any; // raw engine for the p1 seat, transposed proxy for the p0 seat
  lastOwnMove: PlayerMove; // most recent move this seat actually played (the other seat's stale peek)
}

export type GameOutcome = { winnerSeat: 0 | 1 | null; turns: number } | { error: string };

/** Called after both seats decided, before the turn executes. `engine`/`battleKey` are the RAW views. */
export interface TurnHook {
  (info: {
    turn: number;
    engine: any;
    battleKey: `0x${string}`;
    /** null when that seat does not act this turn (forced-switch flag). */
    p0Move: PlayerMove | null;
    p1Move: PlayerMove | null;
    seats: [Seat, Seat];
  }): void;
}

// Reuse chomp's startBattle, then flip the rngOracle to ZERO so the keccak256(p0Salt,p1Salt) inline
// path runs (parity with munch's harness).
function startArenaBattle(ctx: SimContext, teams: [number[], number[]]): `0x${string}` {
  const p0Team = teams[0].map((id) => buildTeamMon(ctx, roster, id));
  const p1Team = teams[1].map((id) => buildTeamMon(ctx, roster, id));
  const { battleKey } = startBattle(ctx, p0Team, p1Team);
  const engine = ctx.engine as any;
  const storageKey = engine._getStorageKey(battleKey);
  engine.battleConfig[storageKey].rngOracle = { _contractAddress: ZERO_ADDRESS };
  return battleKey;
}

export function playGame(
  stratP1: CpuStrategy, stratP0: CpuStrategy,
  teams: [number[], number[]], seed: number, maxTurns: number,
  onBeforeExecute?: TurnHook,
): GameOutcome {
  const rng = makeRng(seed);

  const ctx = makeSimContext({ monsPerTeam: BigInt(TEAM_SIZE) });
  const battleKey = startArenaBattle(ctx, teams);
  const engine = ctx.engine as any;

  const winnerNow = () => Number(engine.battleData[battleKey].winnerIndex);

  const seats: [Seat, Seat] = [
    { strategy: stratP0, state: stratP0.createState(), engine: transposeEngine(engine), lastOwnMove: { moveIndex: 0, extraData: 0 } },
    { strategy: stratP1, state: stratP1.createState(), engine, lastOwnMove: { moveIndex: 0, extraData: 0 } },
  ];

  for (let t = 0; t < maxTurns; t++) {
    const winner = winnerNow();
    if (winner !== 2) return { winnerSeat: winner as 0 | 1, turns: t };

    const flag = Number(engine.getBattleContext(battleKey).playerSwitchForTurnFlag);
    const p0Acts = flag !== 1;
    const p1Acts = flag !== 0;

    try {
      // p0 seat decides first, peeking only the opponent's previous move.
      let p0Move: PlayerMove | null = null;
      if (p0Acts) {
        const view = captureBattleView(seats[0].engine, battleKey);
        p0Move = seats[0].strategy.decide(view, seats[1].lastOwnMove, rng, seats[0].state);
        seats[0].lastOwnMove = p0Move;
      }
      // p1 seat replies with the true reveal (production semantics).
      let p1Move: PlayerMove | null = null;
      if (p1Acts) {
        const view = captureBattleView(seats[1].engine, battleKey);
        p1Move = seats[1].strategy.decide(view, p0Move ?? { moveIndex: 0, extraData: 0 }, rng, seats[1].state);
        seats[1].lastOwnMove = p1Move;
      }

      onBeforeExecute?.({ turn: t, engine, battleKey, p0Move, p1Move, seats });

      // Salt is drawn ONLY for an acting side, p0 before p1 — matching munch's `toDecision(null)` skip.
      const p0Salt = p0Move ? randomSalt(rng) : 0n;
      const p1Salt = p1Move ? randomSalt(rng) : 0n;
      executeTurn(ctx, battleKey, {
        p0MoveIndex: p0Move ? p0Move.moveIndex : NO_OP_INDEX,
        p1MoveIndex: p1Move ? p1Move.moveIndex : NO_OP_INDEX,
        p0Salt,
        p1Salt,
        p0ExtraData: BigInt(p0Move ? p0Move.extraData : 0),
        p1ExtraData: BigInt(p1Move ? p1Move.extraData : 0),
      });
    } catch (e) {
      return { error: `turn ${t}: ${(e as Error).stack ?? (e as Error).message}` };
    }
  }

  const final = winnerNow();
  if (final !== 2) return { winnerSeat: final as 0 | 1, turns: maxTurns };
  return { winnerSeat: null, turns: maxTurns }; // turn-cap draw (stalemate)
}
