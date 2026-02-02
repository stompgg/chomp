/**
 * Battle Simulation Harness
 *
 * Provides automatic dependency injection setup and turn-by-turn battle execution
 * for client-side simulations that match on-chain results.
 *
 * This is a thin wrapper around the transpiled Engine - it delegates all battle
 * logic to the Engine rather than reimplementing it.
 */

import { ContractContainer, globalEventStream } from './index';
import * as Structs from '../Structs';

// =============================================================================
// HARNESS CONSTANTS
// =============================================================================

/**
 * Dedicated move manager address for harness - allows setting moves for both players.
 */
const HARNESS_MOVE_MANAGER = '0x000000000000000000000000000000000000BEEF';

// =============================================================================
// HARNESS TEAM REGISTRY
// =============================================================================

/**
 * Simple team registry for harness - stores teams directly without MonRegistry.
 * Implements ITeamRegistry interface for Engine.startBattle() compatibility.
 */
class HarnessTeamRegistry {
  _contractAddress: string = '0x000000000000000000000000000000000000TEAM';

  private teams: Map<string, Map<number, Structs.Mon[]>> = new Map();
  private nextTeamIndex: Map<string, number> = new Map();

  registerTeam(player: string, team: Structs.Mon[]): bigint {
    const key = player.toLowerCase();
    if (!this.teams.has(key)) {
      this.teams.set(key, new Map());
      this.nextTeamIndex.set(key, 0);
    }
    const playerTeams = this.teams.get(key)!;
    const idx = this.nextTeamIndex.get(key)!;
    playerTeams.set(idx, team);
    this.nextTeamIndex.set(key, idx + 1);
    return BigInt(idx);
  }

  getTeam(player: string, teamIndex: bigint): Structs.Mon[] {
    const playerTeams = this.teams.get(player.toLowerCase());
    return playerTeams?.get(Number(teamIndex)) || [];
  }

  getTeams(p0: string, p0TeamIndex: bigint, p1: string, p1TeamIndex: bigint): [Structs.Mon[], Structs.Mon[]] {
    return [this.getTeam(p0, p0TeamIndex), this.getTeam(p1, p1TeamIndex)];
  }

  getTeamCount(player: string): bigint {
    return BigInt(this.nextTeamIndex.get(player.toLowerCase()) || 0);
  }

  getMonRegistry(): any { return null; }

  getMonRegistryIndicesForTeam(player: string, teamIndex: bigint): bigint[] {
    return this.getTeam(player, teamIndex).map((_, i) => BigInt(i));
  }
}

// =============================================================================
// HARNESS MATCHMAKER
// =============================================================================

/**
 * Simple matchmaker for harness - always validates registered battles.
 * Implements IMatchmaker interface for Engine.startBattle() compatibility.
 */
class HarnessMatchmaker {
  _contractAddress: string = '0x000000000000000000000000000000000000CAFE';

  private battles: Map<string, { p0: string; p1: string }> = new Map();

  registerBattle(battleKey: string, p0: string, p1: string): void {
    this.battles.set(battleKey, { p0: p0.toLowerCase(), p1: p1.toLowerCase() });
  }

  validateMatch(battleKey: string, player: string): boolean {
    const battle = this.battles.get(battleKey);
    if (!battle) return false;
    const p = player.toLowerCase();
    return p === battle.p0 || p === battle.p1;
  }
}

// =============================================================================
// TYPES
// =============================================================================

/**
 * Mon configuration for battle setup
 */
export interface MonConfig {
  stats: {
    hp: bigint;
    stamina: bigint;
    speed: bigint;
    attack: bigint;
    defense: bigint;
    specialAttack: bigint;
    specialDefense: bigint;
  };
  type1: number;  // Enum value
  type2: number;  // Enum value (0 for none)
  moves: string[];  // Move contract names (e.g., ['BigBite', 'Recover'])
  ability: string;  // Ability contract name
}

/**
 * Team configuration
 */
export interface TeamConfig {
  mons: MonConfig[];
}

/**
 * Contract address mapping
 */
export interface AddressConfig {
  [contractName: string]: string;
}

/**
 * Full battle configuration
 */
export interface BattleConfig {
  player0: string;  // Address
  player1: string;  // Address
  teams: [TeamConfig, TeamConfig];  // [p0 team, p1 team]
  addresses?: AddressConfig;  // Optional contract addresses
  rngSeed?: string;  // Optional seed for deterministic RNG
}

/**
 * Move decision for a turn
 */
export interface MoveDecision {
  moveIndex: number;  // 0-3 for moves, or special indices from Constants.sol
  salt: string;  // bytes32 hex string for RNG
  extraData?: bigint;  // Optional extra data (target index, etc.)
}

/**
 * Turn input for both players
 */
export interface TurnInput {
  player0: MoveDecision;
  player1: MoveDecision;
}

/**
 * Mon state snapshot (matches Solidity MonState struct)
 */
export interface MonState {
  hpDelta: bigint;
  staminaDelta: bigint;
  speedDelta: bigint;
  attackDelta: bigint;
  defenseDelta: bigint;
  specialAttackDelta: bigint;
  specialDefenseDelta: bigint;
  isKnockedOut: boolean;
  shouldSkipTurn: boolean;
}

/**
 * Battle state snapshot
 */
export interface BattleState {
  turnId: bigint;
  activeMonIndex: [number, number];  // [p0 active, p1 active]
  winnerIndex: number;  // 0, 1, or 2 (no winner yet)
  p0States: MonState[];
  p1States: MonState[];
  events: any[];  // Events emitted this turn
}

/**
 * Container setup function type (from transpiled factories.ts)
 */
export type ContainerSetupFn = (container: ContractContainer) => void;

// NOTE: Special move indices (SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX) are defined
// in the transpiled Constants.ts from src/Constants.sol. Import them from there
// rather than hardcoding here. The harness just passes through whatever moveIndex
// the user provides - the Engine handles interpreting special indices.

// =============================================================================
// BATTLE SIMULATOR
// =============================================================================

/**
 * Battle Simulation Harness
 *
 * Manages contract instantiation via dependency injection and delegates battle
 * execution to the transpiled Engine contract.
 *
 * @example
 * ```typescript
 * import { setupContainer } from './ts-output/factories';
 *
 * const harness = createBattleHarness(setupContainer);
 *
 * const battleKey = await harness.startBattle({
 *   player0: '0x1234...',
 *   player1: '0x5678...',
 *   teams: [team1Config, team2Config],
 * });
 *
 * const state = harness.executeTurn(battleKey, {
 *   player0: { moveIndex: 0, salt: '0x...', extraData: 0n },
 *   player1: { moveIndex: 1, salt: '0x...' }
 * });
 *
 * console.log(state.winnerIndex); // 0, 1, or 2 (ongoing)
 * ```
 */
export class BattleHarness {
  private container: ContractContainer;
  private teamRegistry: HarnessTeamRegistry;
  private matchmaker: HarnessMatchmaker;

  constructor(container: ContractContainer) {
    this.container = container;
    this.teamRegistry = new HarnessTeamRegistry();
    this.matchmaker = new HarnessMatchmaker();
  }

  /**
   * Configure contract addresses
   */
  setAddresses(addresses: AddressConfig): void {
    for (const [name, address] of Object.entries(addresses)) {
      const instance = this.container.tryResolve(name);
      if (instance && typeof instance === 'object') {
        (instance as any)._contractAddress = address;
      }
    }
  }

  /**
   * Start a new battle
   *
   * This sets up the battle configuration in the Engine and returns a battleKey.
   * Uses mutators to bypass authorization checks for testing.
   */
  startBattle(config: BattleConfig): string {
    // Set addresses if provided
    if (config.addresses) {
      this.setAddresses(config.addresses);
    }

    // Build teams with resolved contract references
    const teams = config.teams.map((teamConfig) =>
      teamConfig.mons.map((monConfig) => this.buildMon(monConfig))
    );

    const engine = this.container.resolve('Engine') as any;

    // Register teams with harness registry
    const p0TeamIndex = this.teamRegistry.registerTeam(config.player0, teams[0]);
    const p1TeamIndex = this.teamRegistry.registerTeam(config.player1, teams[1]);

    // Compute battleKey BEFORE startBattle (uses current nonce)
    const [battleKey] = engine.computeBattleKey(config.player0, config.player1);

    // Register battle with matchmaker
    this.matchmaker.registerBattle(battleKey, config.player0, config.player1);

    // Use mutators to authorize matchmaker for both players (bypasses msg.sender checks)
    engine.__mutateIsMatchmakerFor(config.player0, this.matchmaker._contractAddress, true);
    engine.__mutateIsMatchmakerFor(config.player1, this.matchmaker._contractAddress, true);

    // Resolve dependencies
    const validator = this.container.resolve('IValidator');
    const rngOracle = this.container.resolve('IRandomnessOracle');
    const ruleset = this.container.resolve('IRuleset');

    // Build correct Battle struct with all required fields
    const battle = {
      p0: config.player0,
      p0TeamIndex,
      p1: config.player1,
      p1TeamIndex,
      teamRegistry: this.teamRegistry,
      validator,
      rngOracle,
      ruleset,
      moveManager: HARNESS_MOVE_MANAGER,
      matchmaker: this.matchmaker,
      engineHooks: [],
    };

    // Set msg.sender to matchmaker (who calls startBattle in real flow)
    engine._msg.sender = this.matchmaker._contractAddress;
    engine.startBattle(battle);

    // Initialize mon states with defaults (fixes Solidity vs TypeScript storage semantics)
    // In Solidity, uninitialized storage returns zeros; in TypeScript it returns undefined
    this.initializeMonStates(engine, battleKey, teams[0].length, teams[1].length);

    return battleKey;
  }

  /**
   * Build a Mon struct from config
   * Returns a Structs.Mon compatible object
   */
  private buildMon(config: MonConfig): Structs.Mon {
    const moves = config.moves.map(moveName => this.container.resolve(moveName));
    const ability = config.ability ? this.container.resolve(config.ability) : null;

    // MonStats includes type1/type2, so merge them with the stats
    const stats: Structs.MonStats = {
      hp: config.stats.hp,
      stamina: config.stats.stamina,
      speed: config.stats.speed,
      attack: config.stats.attack,
      defense: config.stats.defense,
      specialAttack: config.stats.specialAttack,
      specialDefense: config.stats.specialDefense,
      type1: config.type1,
      type2: config.type2,
    };

    return {
      stats,
      moves,
      ability,
    };
  }

  /**
   * Initialize mon states with default values.
   *
   * This is needed because in Solidity, uninitialized storage mappings return
   * default values (zeros), but in TypeScript they return undefined.
   * Without this, accessing monState.speedDelta etc. will throw.
   */
  private initializeMonStates(engine: any, battleKey: string, p0TeamSize: number, p1TeamSize: number): void {
    // Access the storage key and config (these are private/protected, but we need them for testing)
    const storageKey = engine._getStorageKey(battleKey);
    const config = engine.battleConfig[storageKey];

    if (!config) return;

    // Initialize p0States with default MonState objects
    for (let i = 0; i < p0TeamSize; i++) {
      if (!config.p0States[i]) {
        config.p0States[i] = Structs.createDefaultMonState();
      }
    }

    // Initialize p1States with default MonState objects
    for (let i = 0; i < p1TeamSize; i++) {
      if (!config.p1States[i]) {
        config.p1States[i] = Structs.createDefaultMonState();
      }
    }
  }

  /**
   * Execute a turn for a battle
   *
   * This delegates to the Engine:
   * 1. Calls setMove() for each player (as moveManager)
   * 2. Calls execute()
   * 3. Reads back the state
   */
  executeTurn(battleKey: string, input: TurnInput): BattleState {
    // Clear events for this turn
    globalEventStream.clear();

    const engine = this.container.resolve('Engine') as any;

    // Set msg.sender to moveManager for ALL setMove calls
    // This bypasses the validation that normally requires either:
    // 1. Being the moveManager, or
    // 2. Being in the middle of execute() (isForCurrentBattle check)
    engine._msg.sender = HARNESS_MOVE_MANAGER;

    // Set moves for both players via Engine
    engine.setMove(
      battleKey,
      0n,  // player 0
      BigInt(input.player0.moveIndex),
      input.player0.salt,
      input.player0.extraData ?? 0n
    );

    engine.setMove(
      battleKey,
      1n,  // player 1
      BigInt(input.player1.moveIndex),
      input.player1.salt,
      input.player1.extraData ?? 0n
    );

    // Advance block timestamp to avoid GameStartsAndEndsSameBlock error
    // In real blockchain, execute() would be in a later block than startBattle()
    engine._block.timestamp = engine._block.timestamp + 1n;

    // Execute the turn - Engine handles all logic
    engine.execute(battleKey);

    // Read back the state from Engine
    return this.getBattleState(battleKey);
  }

  /**
   * Get current battle state from the Engine
   */
  getBattleState(battleKey: string): BattleState {
    const engine = this.container.resolve('Engine') as any;

    // Get battle data from Engine - getBattle returns [BattleConfigView, BattleData]
    const [configView, battleData] = engine.getBattle(battleKey);

    // Use Engine's public methods for active mon indices
    const activeIndices = engine.getActiveMonIndexForBattleState(battleKey);
    const activeMonIndex: [number, number] = [
      Number(activeIndices[0]),
      Number(activeIndices[1])
    ];

    // Mon states are included in the config view (monStates[0] = p0, monStates[1] = p1)
    const p0States: MonState[] = configView.monStates[0] || [];
    const p1States: MonState[] = configView.monStates[1] || [];

    return {
      turnId: battleData.turnId,
      activeMonIndex,
      winnerIndex: Number(battleData.winnerIndex),
      p0States,
      p1States,
      events: globalEventStream.getAll(),
    };
  }

  /**
   * Get the container for advanced usage
   */
  getContainer(): ContractContainer {
    return this.container;
  }

  /**
   * Get the engine instance
   */
  getEngine(): any {
    return this.container.resolve('Engine');
  }
}

// =============================================================================
// FACTORY FUNCTION
// =============================================================================

/**
 * Create a battle harness with the container setup from factories.ts
 *
 * @example
 * ```typescript
 * import { setupContainer } from './ts-output/factories';
 *
 * const harness = createBattleHarness(setupContainer);
 * ```
 */
export function createBattleHarness(containerSetup: ContainerSetupFn): BattleHarness {
  const container = new ContractContainer();
  containerSetup(container);
  return new BattleHarness(container);
}
