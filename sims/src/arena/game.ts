/**
 * Single CPU-vs-CPU game driver for the balance arena, BRIDGED onto chomp's scripted harness
 * (`sims/src/harness.ts`) over `transpiler/ts-output`.
 *
 * Seating (from munch): every strategy assumes it is p1, so the p0 seat reads through `transposeEngine`;
 * the p1 seat gets the true reveal of p0's move (production peek), the p0 seat only the opponent's
 * previous move.
 *
 * Bridge specifics vs the raw chomp harness:
 *   1. After `startBattle`, the battle's rngOracle is patched to a MEMOIZED reproduction of the engine's
 *      inline zero-oracle rng (`keccak256(uint104 p0Salt, uint104 p1Salt)`) — same values as munch's
 *      ZERO-oracle harness, but forks with repeated salts skip the keccak (see `rng-oracle.ts`).
 *   2. On a forced-switch turn only the acting side is decided AND only its salt is drawn (p0 before p1),
 *      exactly mirroring munch's `toDecision(null)` skip — the shared rng stream must stay in lockstep.
 */
import { CpuStrategy, PlayerMove, StrategyState } from '../cpu/strategy';
import { captureBattleView } from '../cpu/battle-view';
import { NO_OP_INDEX, TEAM_SIZE } from '../cpu/constants';
import { makeSimContext, startBattle, executeTurn, P0_ADDR, P1_ADDR, type SimContext } from '../harness';
import { loadRoster } from '../util/csv-load';
import { buildTeamMon, type DraftedMon } from './team';
import { transposeEngine } from './transpose';
import { makeRng, randomSalt } from './rng';
import { MemoizedInlineRngOracle } from './rng-oracle';
import './fast-status-key'; // registers StatusEffectLib.getKeyForMonIndex as a pure (memoized) proxy method
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
function startArenaBattle(ctx: SimContext, teams: [DraftedMon[], DraftedMon[]]): `0x${string}` {
  const p0Team = teams[0].map((dm) => buildTeamMon(ctx, roster, dm.id, dm.equip));
  const p1Team = teams[1].map((dm) => buildTeamMon(ctx, roster, dm.id, dm.equip));
  const { battleKey } = startBattle(ctx, p0Team, p1Team);
  const engine = ctx.engine as any;
  const storageKey = engine._getStorageKey(battleKey);
  engine.battleConfig[storageKey].rngOracle = new MemoizedInlineRngOracle();
  return battleKey;
}

export type EngineKind = 'ts' | 'rust';

/** The engine surface one game runs against; the decision loop is engine-
 * agnostic. `engine` answers every strategy/view read; `execute` runs a turn. */
interface GameDrive {
  engine: any;
  battleKey: string;
  execute(input: {
    p0MoveIndex: number; p1MoveIndex: number;
    p0Salt: bigint; p1Salt: bigint;
    p0ExtraData: bigint; p1ExtraData: bigint;
  }): void;
  dispose(): void;
}

function makeTsDrive(ctx: SimContext, teams: [DraftedMon[], DraftedMon[]]): GameDrive {
  const battleKey = startArenaBattle(ctx, teams);
  return {
    engine: ctx.engine as any,
    battleKey,
    execute: (input) => { executeTurn(ctx, battleKey, input); },
    dispose: () => {},
  };
}

function makeRustDrive(ctx: SimContext, teams: [DraftedMon[], DraftedMon[]]): GameDrive {
  // Lazy import: TS-only arena runs never touch bun:ffi / the cdylib.
  const { RustBattleAdapter } = require('./rust-engine') as typeof import('./rust-engine');
  const p0Team = teams[0].map((dm) => buildTeamMon(ctx, roster, dm.id, dm.equip));
  const p1Team = teams[1].map((dm) => buildTeamMon(ctx, roster, dm.id, dm.equip));
  const adapter = new RustBattleAdapter();
  const battleKey = adapter.start(ctx, p0Team, p1Team, TEAM_SIZE);
  return {
    engine: adapter,
    battleKey,
    execute: (input) => { adapter.executeTurn(input); },
    dispose: () => { adapter.free(); },
  };
}

export function playGame(
  stratP1: CpuStrategy, stratP0: CpuStrategy,
  teams: [DraftedMon[], DraftedMon[]], seed: number, maxTurns: number,
  onBeforeExecute?: TurnHook,
  engineKind: EngineKind = 'ts',
): GameOutcome {
  const rng = makeRng(seed);

  const ctx = makeSimContext({ monsPerTeam: BigInt(TEAM_SIZE) });
  const drive = engineKind === 'rust' ? makeRustDrive(ctx, teams) : makeTsDrive(ctx, teams);
  try {
    return runGameLoop(drive, stratP1, stratP0, rng, maxTurns, onBeforeExecute);
  } finally {
    drive.dispose();
  }
}

function runGameLoop(
  drive: GameDrive,
  stratP1: CpuStrategy, stratP0: CpuStrategy,
  rng: () => number, maxTurns: number,
  onBeforeExecute?: TurnHook,
): GameOutcome {
  const engine = drive.engine;
  const battleKey = drive.battleKey as `0x${string}`;

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
      drive.execute({
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
