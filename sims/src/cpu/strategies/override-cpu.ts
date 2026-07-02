import { Hex } from '../hex';
import { SWITCH_MOVE_INDEX } from '../constants';
import {
  cpuActiveMonIndex,
  oppActiveMonIndex,
  monMaxHp,
  monCurrentHp,
  monCurrentStamina,
  monCurrentSpeed,
} from '../engine-view';
import { forkMeasureIncomingDamage } from '../heuristic-native';
import { BattleView } from '../battle-view';
import { BaseCpuStrategy, CpuMove, PlayerMove, StrategyState } from '../strategy';
import { HardCpu } from './hard-cpu';

/**
 * OVERRIDE CPU — a scripted-plan pilot for validating setup / resource / self-sacrifice lines the
 * heuristic pilots refuse to play ("unpiloted is not weak"). It wraps {@link HardCpu}: for the active
 * mon it consults a per-mon script (ordered rules with `when` / `once` / `maxUses` gates); the first
 * rule whose move is affordable this turn and whose gate passes is played, otherwise it delegates the
 * whole decision to hard. Reusable beyond the design pass — any "force this mon to play this line"
 * experiment registers a script here.
 *
 * Mons are keyed by BASE HP, which is unique per mon (see drool/mons.csv), because the battle view
 * exposes stats, not mon ids.
 *
 *   getCpuStrategy('override')   // then run via sim-tests/arena/*.ts --strategies override
 */

const CPU = 1n; // the CPU is always p1
const OPP = 0n;

/** Read-only position facts a `when` predicate can gate on. */
export interface OverrideCtx {
  /** CPU active mon current HP / max HP, in [0, 1]. */
  hpFrac: number;
  /** CPU active mon current stamina. */
  stamina: number;
  /** CPU active mon outspeeds the opponent's active mon. */
  outspeeds: boolean;
  /** The opponent's revealed move this turn would KO the CPU active mon if it stays in. */
  incomingLethal: boolean;
  /** The opponent's revealed move index (SWITCH_MOVE_INDEX / NO_OP when it isn't attacking). */
  oppMoveIndex: number;
  /** Turns elapsed this game. */
  turn: number;
  /** How many times THIS rule has already fired this game. */
  uses: number;
}

export interface OverrideRule {
  /** Move slot 0-3 to play. */
  move: number;
  /** Optional gate; the rule only fires when this returns true (or when omitted). */
  when?: (c: OverrideCtx) => boolean;
  /** Fire at most once per game. */
  once?: boolean;
  /** Fire at most N times per game. */
  maxUses?: number;
  /** Force a specific extraData target; defaults to the engine-picked valid target. */
  extraData?: number;
  /** Human label for logs. */
  label?: string;
}

/** An ordered list of rules; first affordable + passing rule wins, else fall through to hard. */
export type OverrideScript = OverrideRule[];

/**
 * Scripts keyed by base HP. Add a mon by dropping its base HP (from mons.csv) and an ordered rule
 * list. Start small — one signature line per mon is enough to test the hypothesis.
 */
export const OVERRIDE_SCRIPTS: Record<number, OverrideScript> = {
  // Ghouliath (baseHp 303): fire Eternal Grudge (slot 0) on the turn it would otherwise be KO'd,
  // while Rise From The Grave can still refund the self-KO. Once per game (the revive is one charge).
  303: [{ move: 0, when: (c) => c.incomingLethal, once: true, label: 'Eternal Grudge on lethal' }],

  // Aurox (baseHp 400): the tank line — Iron Wall (slot 2) on a fresh, stamina-flush entry, then
  // Bull Rush (slot 3) as the default so Up Only ramps behind the regen.
  400: [
    { move: 2, when: (c) => c.hpFrac > 0.9 && c.stamina >= 3, maxUses: 1, label: 'Iron Wall on entry' },
    { move: 3, label: 'Bull Rush' },
  ],

  // Inutia (baseHp 351): the weave-and-pass line — Initialize (slot 1) on a fresh, safe entry, then
  // Hit and Dip (slot 3) to pivot and pass the boost. NOTE: the pivot target is engine-picked, not
  // frailest-partner-aware, so this tests "does weaving beat mono-attacking," not a hand-picked pass.
  351: [
    { move: 1, when: (c) => c.hpFrac > 0.75, once: true, label: 'Initialize on entry' },
    { move: 3, once: true, label: 'Hit and Dip pivot (pass the boost)' },
  ],
};

export class OverrideCpu extends BaseCpuStrategy {
  readonly name = 'override';
  private readonly fallback = new HardCpu();

  createState(): StrategyState {
    return { fallback: this.fallback.createState(), turn: 0, uses: {} };
  }

  decide(view: BattleView, playerMove: PlayerMove, rng: () => number, state: StrategyState): CpuMove {
    const e = view.engine;
    const bk = view.bk as Hex;
    state.turn = (state.turn as number) + 1;

    const activeIdx = cpuActiveMonIndex(e, bk);
    const script = OVERRIDE_SCRIPTS[monMaxHp(e, bk, CPU, activeIdx)];

    if (script) {
      const { moves } = this.validMoves(e, bk, rng); // affordable slots, each with a valid target
      const uses = state.uses as Record<string, number>;
      let ctx: OverrideCtx | undefined;

      for (let i = 0; i < script.length; i++) {
        const rule = script[i];
        const key = `${activeIdx}:${i}`;
        const fired = uses[key] ?? 0;
        if (rule.once && fired >= 1) continue;
        if (rule.maxUses !== undefined && fired >= rule.maxUses) continue;

        const affordable = moves.find((m) => m.moveIndex === rule.move);
        if (!affordable) continue; // not castable this turn (stamina / forced-switch / etc.)

        if (rule.when) {
          if (!ctx) ctx = buildCtx(e, bk, activeIdx, playerMove, state.turn as number);
          if (!rule.when({ ...ctx, uses: fired })) continue;
        }

        uses[key] = fired + 1;
        return { moveIndex: affordable.moveIndex, extraData: rule.extraData ?? affordable.extraData };
      }
    }

    return this.fallback.decide(view, playerMove, rng, state.fallback as StrategyState);
  }
}

function buildCtx(e: any, bk: Hex, activeIdx: number, playerMove: PlayerMove, turn: number): OverrideCtx {
  const curHp = monCurrentHp(e, bk, CPU, activeIdx);
  const maxHp = monMaxHp(e, bk, CPU, activeIdx);
  const oppIdx = oppActiveMonIndex(e, bk);

  // Incoming lethal: only meaningful when the opponent actually attacks this turn.
  let incomingLethal = false;
  if (playerMove.moveIndex < SWITCH_MOVE_INDEX) {
    try {
      incomingLethal =
        forkMeasureIncomingDamage(e, bk, playerMove.moveIndex, playerMove.extraData, null, 0n) >= curHp;
    } catch {
      incomingLethal = false; // a fork that fails on an odd state just reads as non-lethal
    }
  }

  return {
    hpFrac: maxHp > 0 ? curHp / maxHp : 0,
    stamina: monCurrentStamina(e, bk, CPU, activeIdx),
    outspeeds: monCurrentSpeed(e, bk, CPU, activeIdx) > monCurrentSpeed(e, bk, OPP, oppIdx),
    incomingLethal,
    oppMoveIndex: playerMove.moveIndex,
    turn,
    uses: 0,
  };
}
