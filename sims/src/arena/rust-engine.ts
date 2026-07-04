/**
 * Rust-engine adapter for the arena: an object exposing the SAME read
 * surface the CPU strategies + their helpers reach on the TS engine
 * (engine-view / battle-view / heuristic-shared / forward-model), backed by
 * the transpiled native engine behind bun:ffi.
 *
 * Design (mirrors the lockstep-gate philosophy — no engine semantics live
 * here):
 *   - All getters read a CACHED rich state JSON that the Rust side builds
 *     BY CALLING THE TRANSPILED GETTERS (`chomp_battle_state`). This class
 *     is a dumb field mapper; the cache refreshes after every executed
 *     turn and per forward-model fork.
 *   - `validatePlayerMoveForBattle` is a live FFI call (real validation
 *     logic, incl. move-specific checks through dispatch).
 *   - The forward model delegates through `__runHypotheticalFork` /
 *     `__disposeFork` (see forward-model.ts): fork + one silent turn run
 *     natively; the fork's state lands in the same cache so
 *     `captureBattleView(adapter, forkKey)` reads it like any battle.
 *   - No RNG-oracle or status-key shims: the battle runs the engine's
 *     inline keccak(p0Salt, p1Salt) path (rngOracle = 0), byte-identical
 *     to the memoized-oracle TS arena path.
 *
 * TS keeps what it is good at: pure move METADATA (moveSlotLib/decodeMeta
 * resolve contract moves via the live container's address book — the Rust
 * battle is configured with the SAME book, so addresses line up), and the
 * strategy code itself.
 */
import { dlopen, FFIType, ptr, CString } from 'bun:ffi';
import { join } from 'node:path';
import { contractAddresses } from '../../../transpiler/ts-output/runtime';
import * as Structs from '../../../transpiler/ts-output/Structs';
import type { SimContext } from '../harness';

const LIB_PATH = process.env.CHOMP_FFI_LIB
  ?? join(import.meta.dir, '..', '..', '..', 'transpiler', 'rs-output', 'target', 'release', 'libchomp_ffi.so');

/** Expected chomp_ffi_version (major << 16 | minor). Bump in lockstep with
 * ffi-rs on every exported-signature change — the assert below turns silent
 * ABI drift into an immediate load-time failure. */
const EXPECTED_FFI_VERSION = (0 << 16) | 3;

let _lib: any = null;
export function ffi(): any {
  if (_lib === null) {
    _lib = dlopen(LIB_PATH, {
      chomp_ffi_version: { args: [], returns: FFIType.u32 },
      chomp_battle_new: { args: [FFIType.ptr], returns: FFIType.u64 },
      chomp_battle_validate: {
        args: [FFIType.u64, FFIType.ptr, FFIType.u8, FFIType.u8, FFIType.u16],
        returns: FFIType.i32,
      },
      chomp_battle_turn: { args: [FFIType.u64, FFIType.ptr], returns: FFIType.ptr },
      chomp_battle_key: { args: [FFIType.u64], returns: FFIType.ptr },
      chomp_battle_kv: { args: [FFIType.u64, FFIType.ptr, FFIType.u64], returns: FFIType.ptr },
      chomp_battle_state: { args: [FFIType.u64], returns: FFIType.ptr },
      chomp_battle_hypothetical: { args: [FFIType.u64, FFIType.ptr], returns: FFIType.ptr },
      chomp_battle_dispose_fork: { args: [FFIType.u64, FFIType.ptr], returns: FFIType.i32 },
      chomp_battle_free: { args: [FFIType.u64], returns: FFIType.void },
      chomp_run_games: { args: [FFIType.ptr], returns: FFIType.ptr },
      chomp_str_free: { args: [FFIType.ptr], returns: FFIType.void },
    });
    const v = Number(_lib.symbols.chomp_ffi_version());
    if (v !== EXPECTED_FFI_VERSION) {
      throw new Error(`chomp_ffi ABI mismatch: lib=${v.toString(16)} expected=${EXPECTED_FFI_VERSION.toString(16)} — rebuild rs-output or update EXPECTED_FFI_VERSION`);
    }
  }
  return _lib;
}

/** The container's full contract address book, as the Rust side expects it —
 * every battle (handle or batch) must be configured with the SAME book the
 * TS address registry assigned, so metadata resolution lines up. */
export function buildAddressBook(ctx: SimContext): Record<string, string> {
  const book: Record<string, string> = {};
  for (const name of ctx.container.getRegisteredNames()) {
    book[name] = contractAddresses.getAddress(name);
  }
  return book;
}

export function cstr(s: string): Buffer {
  return Buffer.from(s + '\0', 'utf8');
}

export function takeString(p: number | bigint, what: string): string {
  if (!p) throw new Error(`rust-engine: ${what} returned null (engine revert or bad input)`);
  const s = new CString(p as any).toString();
  ffi().symbols.chomp_str_free(p as any);
  return s;
}

// Rich-state JSON shapes (see ffi-rs rich_state_json).
interface RsMon {
  stats: Record<string, number>;
  state: number[]; // indexed by MonStateIndexName ordinal, 0..8
  value: number[]; // indexed by MonStateIndexName ordinal, 0..10 (7/8 are 0)
  /** Absent on LITE fork states (forward-model views never read these). */
  moves?: string[];
  effects?: { address: string; stepsBitmap: number; data: string; index: number }[];
}
interface RsSide {
  teamSize: number;
  koBitmap: number;
  /** Absent on LITE fork states. */
  moveDecision?: { packedMoveIndex: number; extraData: number };
  mons: RsMon[];
}
interface RsState {
  turnId: number;
  winnerIndex: number;
  playerSwitchForTurnFlag: number;
  p0Active: number;
  p1Active: number;
  p0: RsSide;
  p1: RsSide;
  /** True for fork states: moves/effects/moveDecision/dcc omitted. */
  lite?: boolean;
  dcc01?: Record<string, number>;
  dcc10?: Record<string, number>;
}

export function monToJson(m: Structs.Mon): unknown {
  return {
    hp: Number(m.stats.hp), stamina: Number(m.stats.stamina), speed: Number(m.stats.speed),
    attack: Number(m.stats.attack), defense: Number(m.stats.defense),
    specialAttack: Number(m.stats.specialAttack), specialDefense: Number(m.stats.specialDefense),
    type1: Number(m.stats.type1), type2: Number(m.stats.type2),
    moves: m.moves.map((w) => '0x' + w.toString(16)),
    ability: '0x' + m.ability.toString(16),
  };
}

export class RustBattleAdapter {
  private handle: bigint | number = 0;
  /** Live battle key + every live fork key -> cached rich state. */
  private states = new Map<string, RsState>();
  battleKey = '';

  /** Same-shaped raw read game.ts does for the winner check. */
  readonly battleData: Record<string, { winnerIndex: bigint; playerSwitchForTurnFlag: bigint }>;

  constructor() {
    const self = this;
    this.battleData = new Proxy({}, {
      get(_t, key) {
        const s = self.state(String(key));
        return {
          winnerIndex: BigInt(s.winnerIndex),
          playerSwitchForTurnFlag: BigInt(s.playerSwitchForTurnFlag),
        };
      },
    }) as any;
  }

  /** Start a Rust battle with the container's OWN address book so TS-side
   * metadata resolution (moveSlotLib/decodeMeta by address) lines up. */
  start(ctx: SimContext, p0Team: Structs.Mon[], p1Team: Structs.Mon[], monsPerTeam: number): string {
    const addressBook = buildAddressBook(ctx);
    const cfg = {
      monsPerTeam,
      p0Team: p0Team.map(monToJson),
      p1Team: p1Team.map(monToJson),
      addressBook,
      // no rngOracle: zero -> the engine's inline keccak(p0Salt, p1Salt) path
    };
    this.handle = ffi().symbols.chomp_battle_new(ptr(cstr(JSON.stringify(cfg))));
    if (!this.handle) throw new Error('chomp_battle_new failed');
    this.battleKey = takeString(ffi().symbols.chomp_battle_key(this.handle as any), 'chomp_battle_key');
    this.refresh();
    return this.battleKey;
  }

  private state(bk: string): RsState {
    const s = this.states.get(bk);
    if (!s) throw new Error(`rust-engine: no cached state for battle key ${bk}`);
    return s;
  }

  private refresh(): void {
    const raw = takeString(ffi().symbols.chomp_battle_state(this.handle as any), 'chomp_battle_state');
    this.states.set(this.battleKey, JSON.parse(raw));
  }

  executeTurn(input: {
    p0MoveIndex: number; p1MoveIndex: number;
    p0Salt: bigint; p1Salt: bigint;
    p0ExtraData: bigint; p1ExtraData: bigint;
  }): void {
    const out = ffi().symbols.chomp_battle_turn(this.handle as any, ptr(cstr(JSON.stringify({
      p0MoveIndex: input.p0MoveIndex, p1MoveIndex: input.p1MoveIndex,
      p0Salt: input.p0Salt.toString(), p1Salt: input.p1Salt.toString(),
      p0ExtraData: Number(input.p0ExtraData), p1ExtraData: Number(input.p1ExtraData),
    }))));
    takeString(out as any, 'chomp_battle_turn'); // snapshot unused; throws on revert
    this.refresh();
  }

  free(): void {
    if (this.handle) {
      ffi().symbols.chomp_battle_free(this.handle as any);
      this.handle = 0;
      this.states.clear();
    }
  }

  // -------------------------------------------------------------------
  // Forward-model delegation (see forward-model.ts hooks)
  // -------------------------------------------------------------------

  __runHypotheticalFork(
    p0: { moveIndex: number; salt: bigint; extraData: number } | null,
    p1: { moveIndex: number; salt: bigint; extraData: number } | null,
  ): string {
    const body = JSON.stringify({
      p0: p0 ? { moveIndex: p0.moveIndex, salt: p0.salt.toString(), extraData: p0.extraData } : null,
      p1: p1 ? { moveIndex: p1.moveIndex, salt: p1.salt.toString(), extraData: p1.extraData } : null,
    });
    const raw = takeString(
      ffi().symbols.chomp_battle_hypothetical(this.handle as any, ptr(cstr(body))),
      'chomp_battle_hypothetical',
    );
    const { forkKey, state } = JSON.parse(raw);
    this.states.set(forkKey, state);
    return forkKey;
  }

  __disposeFork(forkKey: string): void {
    this.states.delete(forkKey);
    ffi().symbols.chomp_battle_dispose_fork(this.handle as any, ptr(cstr(forkKey)));
  }

  // -------------------------------------------------------------------
  // The engine read surface (shapes mirror the transpiled TS engine:
  // bigint for integers, plain numbers for enum values).
  // -------------------------------------------------------------------

  private side(s: RsState, playerIndex: bigint | number): RsSide {
    return Number(playerIndex) === 0 ? s.p0 : s.p1;
  }

  private mon(bk: string, playerIndex: bigint | number, monIndex: bigint | number): RsMon {
    const side = this.side(this.state(bk), playerIndex);
    const m = side.mons[Number(monIndex)];
    if (!m) throw new Error(`rust-engine: no mon ${monIndex} for player ${playerIndex}`);
    return m;
  }

  getBattleContext(bk: string) {
    const s = this.state(bk);
    return {
      turnId: BigInt(s.turnId),
      winnerIndex: BigInt(s.winnerIndex),
      playerSwitchForTurnFlag: BigInt(s.playerSwitchForTurnFlag),
      p0ActiveMonIndex: BigInt(s.p0Active),
      p1ActiveMonIndex: BigInt(s.p1Active),
    };
  }

  getActiveMonIndexForBattleState(bk: string): bigint[] {
    const s = this.state(bk);
    return [BigInt(s.p0Active), BigInt(s.p1Active)];
  }

  getTurnIdForBattleState(bk: string): bigint {
    return BigInt(this.state(bk).turnId);
  }

  getTeamSize(bk: string, playerIndex: bigint): bigint {
    return BigInt(this.side(this.state(bk), playerIndex).teamSize);
  }

  getKOBitmap(bk: string, playerIndex: bigint): bigint {
    return BigInt(this.side(this.state(bk), playerIndex).koBitmap);
  }

  getMoveDecisionForBattleState(bk: string, playerIndex: bigint) {
    const d = this.side(this.state(bk), playerIndex).moveDecision;
    if (!d) throw new Error('rust-engine: moveDecision read on a LITE fork state — extend the fork dump');
    return { packedMoveIndex: BigInt(d.packedMoveIndex), extraData: BigInt(d.extraData) };
  }

  getMonStatsForBattle(bk: string, playerIndex: bigint, monIndex: bigint) {
    const st = this.mon(bk, playerIndex, monIndex).stats;
    return {
      hp: BigInt(st.hp), stamina: BigInt(st.stamina), speed: BigInt(st.speed),
      attack: BigInt(st.attack), defense: BigInt(st.defense),
      specialAttack: BigInt(st.specialAttack), specialDefense: BigInt(st.specialDefense),
      type1: st.type1, type2: st.type2,
    };
  }

  getMonStateForBattle(bk: string, playerIndex: bigint, monIndex: bigint, stateVarIndex: number | bigint): bigint {
    return BigInt(this.mon(bk, playerIndex, monIndex).state[Number(stateVarIndex)]);
  }

  getMonValueForBattle(bk: string, playerIndex: bigint, monIndex: bigint, stateVarIndex: number | bigint): bigint {
    return BigInt(this.mon(bk, playerIndex, monIndex).value[Number(stateVarIndex)]);
  }

  getMoveForMonForBattle(bk: string, playerIndex: bigint, monIndex: bigint, moveIndex: bigint): bigint | undefined {
    const lanes = this.mon(bk, playerIndex, monIndex).moves;
    if (!lanes) throw new Error('rust-engine: moves read on a LITE fork state — extend the fork dump');
    const w = lanes[Number(moveIndex)];
    if (w === undefined) return undefined;
    const v = BigInt(w);
    // Mirror the TS engine: an empty lane reads as undefined so
    // engine-view's moveSlot loop stops at the real move count.
    return v === 0n ? undefined : v;
  }

  getEffectData(bk: string, playerIndex: bigint, monIndex: bigint, effectAddress: string | bigint): [boolean, bigint, string] {
    const want = (typeof effectAddress === 'bigint'
      ? '0x' + effectAddress.toString(16)
      : effectAddress).toLowerCase().replace(/^0x0*/, '0x');
    const effects = this.mon(bk, playerIndex, monIndex).effects;
    if (!effects) throw new Error('rust-engine: effects read on a LITE fork state — extend the fork dump');
    for (const e of effects) {
      const have = e.address.toLowerCase().replace(/^0x0*/, '0x');
      if (have === want) return [true, BigInt(e.index), e.data];
    }
    return [false, 0n, '0x' + '0'.repeat(64)];
  }

  getDamageCalcContext(bk: string, attackerPlayerIndex: bigint, defenderPlayerIndex: bigint) {
    const s = this.state(bk);
    const d = Number(attackerPlayerIndex) === 0 ? s.dcc01 : s.dcc10;
    if (!d) throw new Error('rust-engine: dcc read on a LITE fork state — extend the fork dump');
    return {
      attackerMonIndex: BigInt(d.attackerMonIndex), defenderMonIndex: BigInt(d.defenderMonIndex),
      attackerAttack: BigInt(d.attackerAttack), attackerAttackDelta: BigInt(d.attackerAttackDelta),
      attackerSpAtk: BigInt(d.attackerSpAtk), attackerSpAtkDelta: BigInt(d.attackerSpAtkDelta),
      defenderDef: BigInt(d.defenderDef), defenderDefDelta: BigInt(d.defenderDefDelta),
      defenderSpDef: BigInt(d.defenderSpDef), defenderSpDefDelta: BigInt(d.defenderSpDefDelta),
      defenderType1: d.defenderType1, defenderType2: d.defenderType2,
    };
  }

  getGlobalKV(bk: string, key: bigint): bigint {
    const out = ffi().symbols.chomp_battle_kv(this.handle as any, ptr(cstr(bk)), key);
    return BigInt(takeString(out as any, 'chomp_battle_kv'));
  }

  validatePlayerMoveForBattle(bk: string, moveIndex: bigint, playerIndex: bigint, extraData: bigint): boolean {
    const r = ffi().symbols.chomp_battle_validate(
      this.handle as any, ptr(cstr(bk)),
      Number(playerIndex), Number(moveIndex), Number(extraData),
    );
    if (r < 0) throw new Error('chomp_battle_validate errored');
    return r === 1;
  }
}
