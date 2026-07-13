import { ContractContainer, addressToUint, contractAddresses } from '../../transpiler/ts-output/runtime';
import { CallTreeObserver, globalEventStream, runAsTransaction, type CallEntry } from '../../transpiler/ts-output/runtime/base';
import { setupContainer } from '../../transpiler/ts-output/factories';
import { Engine } from '../../transpiler/ts-output/Engine';
import * as Structs from '../../transpiler/ts-output/Structs';
import * as Constants from '../../transpiler/ts-output/Constants';
import { packMove, type InlineMoveJson } from './util/inline-pack';

export type MoveSlotSource =
  | { kind: 'contract'; contractName: string }
  | { kind: 'inline'; json: InlineMoveJson };

const HARNESS_MOVE_MANAGER = '0x000000000000000000000000000000000000beef';
const HARNESS_TEAM_REGISTRY_ADDR = '0x000000000000000000000000000000000000a55e';
const HARNESS_MATCHMAKER_ADDR = '0x000000000000000000000000000000000000cafe';
const INLINE_STAMINA_REGEN_RULESET = '0x000000000000000000000000000000000000057a';

export const P0_ADDR = '0x0000000000000000000000000000000000000001';
export const P1_ADDR = '0x0000000000000000000000000000000000000002';

export interface HarnessMonConfig {
  stats: {
    hp: bigint;
    stamina: bigint;
    speed: bigint;
    attack: bigint;
    defense: bigint;
    specialAttack: bigint;
    specialDefense: bigint;
  };
  type1: number;
  type2: number;
  moves: MoveSlotSource[];
  ability: string | null;
}

class HarnessTeamRegistry {
  _contractAddress = HARNESS_TEAM_REGISTRY_ADDR;
  private teams = new Map<string, Map<number, Structs.Mon[]>>();
  private nextIdx = new Map<string, number>();

  registerTeam(player: string, team: Structs.Mon[]): bigint {
    const key = player.toLowerCase();
    if (!this.teams.has(key)) {
      this.teams.set(key, new Map());
      this.nextIdx.set(key, 0);
    }
    const idx = this.nextIdx.get(key)!;
    this.teams.get(key)!.set(idx, team);
    this.nextIdx.set(key, idx + 1);
    return BigInt(idx);
  }

  getTeam(player: string, teamIndex: bigint): Structs.Mon[] {
    return this.teams.get(player.toLowerCase())?.get(Number(teamIndex)) ?? [];
  }

  getTeams(p0: string, p0Idx: bigint, p1: string, p1Idx: bigint): [Structs.Mon[], Structs.Mon[]] {
    return [this.getTeam(p0, p0Idx), this.getTeam(p1, p1Idx)];
  }

  getTeamCount(player: string): bigint {
    return BigInt(this.nextIdx.get(player.toLowerCase()) ?? 0);
  }

  getMonRegistryIndicesForTeam(player: string, teamIndex: bigint): bigint[] {
    return this.getTeam(player, teamIndex).map((_, i) => BigInt(i));
  }

  validateMonBatch(_mons: Structs.Mon[], _monIds: bigint[]): boolean {
    return true;
  }

  validateMon(_m: Structs.Mon, _monId: bigint): boolean {
    return true;
  }
}

class HarnessMatchmaker {
  _contractAddress = HARNESS_MATCHMAKER_ADDR;
  private battles = new Map<string, { p0: string; p1: string }>();

  registerBattle(battleKey: string, p0: string, p1: string): void {
    this.battles.set(battleKey, { p0: p0.toLowerCase(), p1: p1.toLowerCase() });
  }

  validateMatch(battleKey: string, player: string): boolean {
    const b = this.battles.get(battleKey);
    if (!b) return false;
    const p = player.toLowerCase();
    return p === b.p0 || p === b.p1;
  }
}

export interface SimContext {
  container: ContractContainer;
  engine: Engine;
  teamRegistry: HarnessTeamRegistry;
  matchmaker: HarnessMatchmaker;
}

export interface SimContextOptions {
  monsPerTeam?: bigint;
}

export function makeSimContext(opts: SimContextOptions = {}): SimContext {
  const monsPerTeam = opts.monsPerTeam ?? 1n;
  const container = new ContractContainer();
  setupContainer(container);
  // DefaultValidator is no longer transpiled — use the engine's inline validator path (startBattle
  // passes a zero validator). Inline validation reads the engine's DEFAULT_MONS_PER_TEAM /
  // DEFAULT_MOVES_PER_MON, which setupContainer leaves at 0, so re-register the Engine with them set.
  container.registerLazySingleton('Engine', [], () => new Engine(monsPerTeam, Constants.GAME_MOVES_PER_MON));
  for (const name of container.getRegisteredNames()) {
    const inst = container.tryResolve<any>(name);
    if (inst && typeof inst === 'object' && '_contractAddress' in inst) {
      inst._contractAddress = contractAddresses.getAddress(name);
    }
  }
  const engine = container.resolve<Engine>('Engine');
  (engine as any)._block = { timestamp: 1_800_000_000n, number: 1n };
  return {
    container,
    engine,
    teamRegistry: new HarnessTeamRegistry(),
    matchmaker: new HarnessMatchmaker(),
  };
}

function resolveEffectAddress(ctx: SimContext, effectName: string | null): bigint {
  if (!effectName) return 0n;
  const c = ctx.container.resolve<any>(effectName);
  return addressToUint(c._contractAddress);
}

export function buildMon(ctx: SimContext, m: HarnessMonConfig): Structs.Mon {
  const moves = m.moves.map((src) => {
    if (src.kind === 'contract') {
      const c = ctx.container.resolve<any>(src.contractName);
      return addressToUint(c._contractAddress);
    }
    return packMove(src.json, resolveEffectAddress(ctx, src.json.effect));
  });
  let ability = 0n;
  if (m.ability) {
    const c = ctx.container.resolve<any>(m.ability);
    ability = addressToUint(c._contractAddress);
  }
  return {
    stats: {
      hp: m.stats.hp,
      stamina: m.stats.stamina,
      speed: m.stats.speed,
      attack: m.stats.attack,
      defense: m.stats.defense,
      specialAttack: m.stats.specialAttack,
      specialDefense: m.stats.specialDefense,
      type1: m.type1,
      type2: m.type2,
    },
    moves,
    ability,
  };
}

export interface StartedBattle {
  battleKey: `0x${string}`;
  p0Team: Structs.Mon[];
  p1Team: Structs.Mon[];
}

/** `battleMode`: 0 = Singles (default), 1 = Doubles (2 active slots/side, slot-packed turns). */
export function startBattle(ctx: SimContext, p0Team: Structs.Mon[], p1Team: Structs.Mon[], battleMode = 0): StartedBattle {
  const { engine, teamRegistry, matchmaker } = ctx;
  const p0Idx = teamRegistry.registerTeam(P0_ADDR, p0Team);
  const p1Idx = teamRegistry.registerTeam(P1_ADDR, p1Team);
  const [battleKey] = (engine as any).computeBattleKey(P0_ADDR, P1_ADDR) as [`0x${string}`, `0x${string}`];
  matchmaker.registerBattle(battleKey, P0_ADDR, P1_ADDR);
  (engine as any).__mutateIsMatchmakerFor(P0_ADDR, matchmaker._contractAddress, true);
  (engine as any).__mutateIsMatchmakerFor(P1_ADDR, matchmaker._contractAddress, true);

  const rngOracle = ctx.container.resolve<any>('IRandomnessOracle');
  const ruleset = { _contractAddress: INLINE_STAMINA_REGEN_RULESET } as any;
  const battle: Structs.Battle = {
    p0: P0_ADDR,
    p0TeamIndex: p0Idx,
    p1: P1_ADDR,
    p1TeamIndex: p1Idx,
    // Multi seats: zero in Singles/Doubles (startBattle validates the p2/p3 invariant).
    p2: '0x0000000000000000000000000000000000000000',
    p2TeamIndex: 0n,
    p3: '0x0000000000000000000000000000000000000000',
    p3TeamIndex: 0n,
    teamRegistry: teamRegistry as any,
    rngOracle,
    ruleset,
    moveManager: HARNESS_MOVE_MANAGER,
    matchmaker: matchmaker as any,
    engineHooks: [],
  };
  runAsTransaction(matchmaker._contractAddress, [], () => {
    if (battleMode === 0) (engine as any).startBattle(battle);
    else (engine as any).startBattleWithMode(battle, BigInt(battleMode));
  });
  // Initialize per-mon states (Solidity zero-fill semantics — TS needs explicit defaults).
  const storageKey = (engine as any)._getStorageKey(battleKey);
  const config = (engine as any).battleConfig[storageKey];
  for (let i = 0; i < p0Team.length; i++) config.p0States[i] ??= Structs.createDefaultMonState();
  for (let i = 0; i < p1Team.length; i++) config.p1States[i] ??= Structs.createDefaultMonState();
  return { battleKey, p0Team, p1Team };
}

export interface TurnInput {
  p0MoveIndex: number;
  p1MoveIndex: number;
  p0Salt: bigint;
  p1Salt: bigint;
  p0ExtraData?: bigint;
  p1ExtraData?: bigint;
}

export interface MonStateSnapshot {
  hpDelta: bigint;
  staminaDelta: bigint;
  isKnockedOut: boolean;
}

export interface TurnSnapshot {
  turnId: bigint;
  winnerIndex: bigint;
  p0Active: number;
  p1Active: number;
  p0States: MonStateSnapshot[];
  p1States: MonStateSnapshot[];
  events: ReturnType<typeof globalEventStream.getAll>;
  callLog: CallEntry[];
}

export function executeTurn(ctx: SimContext, battleKey: `0x${string}`, input: TurnInput, captureCallLog = false): TurnSnapshot {
  const engine = ctx.engine as any;
  globalEventStream.clear();
  // Call capture moved to the runtime's Observer side-channel (the old Contract._turnCallLog
  // static is gone). Externals are always captured; no internal methods are subscribed.
  const callObserver = captureCallLog ? new CallTreeObserver(new Set<string>()) : null;
  engine._block.timestamp = engine._block.timestamp + 1n;
  runAsTransaction(HARNESS_MOVE_MANAGER, callObserver ? [callObserver] : [], () => {
    engine.executeWithMoves(
      battleKey,
      BigInt(input.p0MoveIndex),
      input.p0Salt,
      input.p0ExtraData ?? 0n,
      BigInt(input.p1MoveIndex),
      input.p1Salt,
      input.p1ExtraData ?? 0n,
    );
  });
  const callLog = callObserver?.roots ?? [];
  const storageKey = engine._getStorageKey(battleKey);
  const config = engine.battleConfig[storageKey];
  const battle = engine.battleData[battleKey];
  const sentinel = Constants.CLEARED_MON_STATE_SENTINEL;
  const norm = (v: bigint) => (v === sentinel ? 0n : v);
  const snap = (s: Structs.MonState): MonStateSnapshot => ({
    hpDelta: norm(s.hpDelta),
    staminaDelta: norm(s.staminaDelta),
    isKnockedOut: !!s.isKnockedOut,
  });
  const p0States: MonStateSnapshot[] = [];
  const p1States: MonStateSnapshot[] = [];
  const p0Size = Number(config.teamSizes & 0x0fn);
  const p1Size = Number((config.teamSizes >> 4n) & 0x0fn);
  for (let i = 0; i < p0Size; i++) p0States.push(snap(config.p0States[i] ?? Structs.createDefaultMonState()));
  for (let i = 0; i < p1Size; i++) p1States.push(snap(config.p1States[i] ?? Structs.createDefaultMonState()));
  const activePacked = battle.activeMonIndex;
  return {
    turnId: battle.turnId,
    winnerIndex: battle.winnerIndex,
    p0Active: Number(engine._unpackActiveMonIndex(activePacked, 0n)),
    p1Active: Number(engine._unpackActiveMonIndex(activePacked, 1n)),
    p0States,
    p1States,
    events: globalEventStream.getAll(),
    callLog,
  };
}

/** Execute one DOUBLES turn from each side's packed slot word (see cpu/forward-model `packSide`). */
export function executeSlotTurn(ctx: SimContext, battleKey: `0x${string}`, side0Packed: bigint, side1Packed: bigint): void {
  const engine = ctx.engine as any;
  globalEventStream.clear();
  engine._block.timestamp = engine._block.timestamp + 1n;
  runAsTransaction(HARNESS_MOVE_MANAGER, [], () => {
    engine.executeWithSlotMoves(battleKey, side0Packed, side1Packed);
  });
}
