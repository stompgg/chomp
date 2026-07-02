import { Hex } from './hex';
import { MonStateIndexName, Type } from '../../../transpiler/ts-output/Enums';
import {
  cpuActiveMonIndex,
  oppActiveMonIndex,
  cpuTeamSize,
  oppTeamSize,
  koBitmap,
  monMaxHp,
  monHpDelta,
  monBaseStamina,
  monStaminaDelta,
  monTypes,
} from './engine-view';

/**
 * SEARCH SUBSTRATE — layer 1: a read-once snapshot of a battle position.
 *
 * `captureBattleView` pulls the frequently-read position fields off the live (or forked) engine in one
 * pass, reusing the faithful `engine-view.ts` readers (so HP / stamina / types / KO bitmaps match what
 * the ported CPUs trust). It is a thin projection the forward model + evaluator consume without
 * re-touching the engine. It deliberately does NOT enumerate valid moves: the ports call
 * `calculateValidMoves` themselves with their own rng for stream parity, so a snapshot copy would be
 * unused — they read the few scalars here off the view and enumerate candidates live.
 *
 * Convention (inherited from the CPU ports): the CPU is ALWAYS p1, the human opponent is p0.
 *   - `cpu*` fields read p1 (playerIndex 1).
 *   - `opp*` fields read p0 (playerIndex 0).
 *   - `mons.p0` / `mons.p1` carry the per-slot snapshot for each side.
 */

const CPU_PLAYER_INDEX = 1n;
const OPP_PLAYER_INDEX = 0n;

/** Per-slot snapshot. `hp` / `stamina` are CURRENT values (base + delta). */
export interface MonView {
  /** Current HP (base + delta). */
  hp: number;
  /** Base (max) HP — lets consumers compute hp% without re-reading the engine. */
  maxHp: number;
  /** Current stamina (base + delta). */
  stamina: number;
  type1: Type;
  type2: Type;
  ko: boolean;
  /**
   * Net stat-stage position: Σ delta/base over the five combat stats (atk/def/spatk/spdef/speed).
   * Setup boosts land positive; burn's attack divide / frostbite's spatk divide land negative.
   */
  statDeltaScore: number;
  /** ShouldSkipTurn flag (zap) — the mon loses its next action. */
  skipTurn: boolean;
}

export interface BattleView {
  engine: any;
  bk: string;
  /** playerSwitchForTurnFlag: 0 = p0-only, 1 = p1-only (CPU forced switch), 2 = both move. */
  switchFlag: number;
  cpuActive: number;
  oppActive: number;
  /** KO bitmaps (bit i set => slot i is KO'd). */
  cpuKO: number;
  oppKO: number;
  // Team sizes are just `mons.p1.length` / `mons.p0.length` — read them off the arrays, not a field.
  mons: { p0: MonView[]; p1: MonView[] };
}

// Σ delta/base over the five combat stats. The getters normalize the cleared sentinel to 0, so a
// switched-out mon's score reads 0 without special-casing.
function readStatDeltaScore(e: any, bk: Hex, playerIndex: bigint, monIndex: number): number {
  const stats = e.getMonStatsForBattle(bk, playerIndex, BigInt(monIndex));
  const mi = BigInt(monIndex);
  let score = 0;
  const add = (base: bigint, stat: MonStateIndexName) => {
    const b = Number(base);
    if (b <= 0) return;
    score += Number(e.getMonStateForBattle(bk, playerIndex, mi, stat)) / b;
  };
  add(stats.attack, MonStateIndexName.Attack);
  add(stats.defense, MonStateIndexName.Defense);
  add(stats.specialAttack, MonStateIndexName.SpecialAttack);
  add(stats.specialDefense, MonStateIndexName.SpecialDefense);
  add(stats.speed, MonStateIndexName.Speed);
  return score;
}

// Per-slot snapshot. `hp` / `maxHp` / `ko` are read eagerly (every consumer uses HP, and the fork that
// produced this view may be disposed after scoring). The four heavier fields — `stamina`, the type
// pair, `statDeltaScore` (5 stat reads + a stats load), `skipTurn` — are LAZY: computed on first
// access and cached. A position evaluator only reads them for the two ACTIVE mons, so the ~6 bench
// slots per view never pay for them. Exact: every consumer touches these before its fork is disposed
// (scoring precedes `disposeFork`), and fork/child views are only ever read for eager `.hp`.
class LazyMonView implements MonView {
  readonly hp: number;
  readonly maxHp: number;
  readonly ko: boolean;
  private _stamina?: number;
  private _types?: [Type, Type];
  private _statDeltaScore?: number;
  private _skipTurn?: boolean;

  constructor(
    private readonly e: any,
    private readonly bk: Hex,
    private readonly pi: bigint,
    private readonly mi: number,
    ko: boolean,
  ) {
    this.ko = ko;
    this.maxHp = monMaxHp(e, bk, pi, mi);
    this.hp = this.maxHp + monHpDelta(e, bk, pi, mi);
  }

  get stamina(): number {
    if (this._stamina === undefined) {
      this._stamina = monBaseStamina(this.e, this.bk, this.pi, this.mi) + monStaminaDelta(this.e, this.bk, this.pi, this.mi);
    }
    return this._stamina;
  }
  get type1(): Type { return this.typePair()[0]; }
  get type2(): Type { return this.typePair()[1]; }
  private typePair(): [Type, Type] {
    if (this._types === undefined) this._types = monTypes(this.e, this.bk, this.pi, this.mi);
    return this._types;
  }
  get statDeltaScore(): number {
    if (this._statDeltaScore === undefined) this._statDeltaScore = readStatDeltaScore(this.e, this.bk, this.pi, this.mi);
    return this._statDeltaScore;
  }
  get skipTurn(): boolean {
    if (this._skipTurn === undefined) {
      this._skipTurn = Number(this.e.getMonStateForBattle(this.bk, this.pi, BigInt(this.mi), MonStateIndexName.ShouldSkipTurn)) !== 0;
    }
    return this._skipTurn;
  }
}

function readSide(e: any, bk: Hex, playerIndex: bigint, size: number): MonView[] {
  const ko = koBitmap(e, bk, playerIndex);
  const out: MonView[] = [];
  for (let i = 0; i < size; i++) {
    out.push(new LazyMonView(e, bk, playerIndex, i, (ko & (1 << i)) !== 0));
  }
  return out;
}

/** Read-once snapshot of the position at `bk`, populated entirely from the engine-view readers. */
export function captureBattleView(e: any, bk: string): BattleView {
  const key = bk as Hex;
  const p0Size = oppTeamSize(e, key);
  const p1Size = cpuTeamSize(e, key);
  return {
    engine: e,
    bk,
    switchFlag: Number(e.getBattleContext(key).playerSwitchForTurnFlag),
    cpuActive: cpuActiveMonIndex(e, key),
    oppActive: oppActiveMonIndex(e, key),
    cpuKO: koBitmap(e, key, CPU_PLAYER_INDEX),
    oppKO: koBitmap(e, key, OPP_PLAYER_INDEX),
    mons: {
      p0: readSide(e, key, OPP_PLAYER_INDEX, p0Size),
      p1: readSide(e, key, CPU_PLAYER_INDEX, p1Size),
    },
  };
}
