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
 * Module loader function type
 */
export type ModuleLoader = (name: string) => Promise<any>;

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
 * Manages contract instantiation, dependency injection, and delegates battle
 * execution to the transpiled Engine contract.
 *
 * @example
 * ```typescript
 * // Import from transpiled output
 * import { setupContainer } from './ts-output/factories';
 *
 * const harness = new BattleHarness();
 * harness.setModuleLoader(name => import(`./ts-output/${name}`));
 * harness.setContainerSetup(setupContainer);  // Uses transpiled dependency info
 * await harness.loadCoreModules();
 *
 * // Configure and start a battle
 * const battleKey = await harness.startBattle({
 *   player0: '0x1234...',
 *   player1: '0x5678...',
 *   teams: [team1Config, team2Config],
 * });
 *
 * // Execute turns (delegates to Engine)
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
  private moduleLoader?: ModuleLoader;
  private containerSetup?: ContainerSetupFn;
  private loadedModules: Map<string, any> = new Map();

  constructor(container?: ContractContainer) {
    this.container = container ?? new ContractContainer();
  }

  /**
   * Set the module loader function for dynamic imports
   */
  setModuleLoader(loader: ModuleLoader): void {
    this.moduleLoader = loader;
  }

  /**
   * Set the container setup function (from transpiled factories.ts)
   * This registers all contract factories with proper dependency info
   */
  setContainerSetup(setup: ContainerSetupFn): void {
    this.containerSetup = setup;
  }

  /**
   * Load and register core modules
   *
   * Uses the transpiled setupContainer() which registers:
   * - Zero-dependency contracts as lazy singletons
   * - Interface aliases (derived from Solidity inheritance)
   * - Contracts with dependencies as factories
   */
  async loadCoreModules(): Promise<void> {
    if (!this.moduleLoader) {
      throw new Error('Module loader not set. Call setModuleLoader() first.');
    }

    if (!this.containerSetup) {
      throw new Error('Container setup not set. Call setContainerSetup() first.');
    }

    // setupContainer registers everything:
    // - Zero-dep contracts as lazy singletons (Engine, TypeCalculator, etc.)
    // - Interface aliases (IEngine -> Engine, ITypeCalculator -> TypeCalculator, etc.)
    // - Contracts with deps as factories that resolve dependencies on demand
    this.containerSetup(this.container);
  }

  /**
   * Load a module by name
   */
  async loadModule(name: string): Promise<any> {
    if (this.loadedModules.has(name)) {
      return this.loadedModules.get(name);
    }

    if (!this.moduleLoader) {
      throw new Error('Module loader not set');
    }

    const module = await this.moduleLoader(name);
    this.loadedModules.set(name, module);
    return module;
  }

  /**
   * Get the exported class from a module
   */
  private getExportedClass(module: any): any {
    // Try named export matching filename
    const keys = Object.keys(module);
    for (const key of keys) {
      if (typeof module[key] === 'function' && key !== 'default') {
        return module[key];
      }
    }
    // Fall back to default export
    return module.default;
  }

  /**
   * Load and resolve a contract by name
   * Uses the container's registered factories (from setupContainer) to instantiate
   */
  async loadContract(name: string): Promise<any> {
    // If already resolved as singleton, return it
    if (this.container.has(name)) {
      return this.container.resolve(name);
    }

    // Load the module
    const module = await this.loadModule(name);
    const ContractClass = this.getExportedClass(module);

    // If container has a factory registered (from setupContainer), use it
    // Otherwise, instantiate directly (for contracts with no dependencies)
    let instance: any;
    if (this.containerSetup) {
      // Factory should be registered, resolve will use it
      try {
        instance = this.container.resolve(name);
      } catch {
        // Not in container, instantiate without dependencies
        instance = new ContractClass();
        this.container.registerSingleton(name, instance);
      }
    } else {
      // No setup function, instantiate without dependencies
      instance = new ContractClass();
      this.container.registerSingleton(name, instance);
    }

    return instance;
  }

  /**
   * Load and register a move contract
   */
  async loadMove(moveName: string): Promise<any> {
    const move = await this.loadContract(moveName);
    return move;
  }

  /**
   * Load and register an ability contract
   */
  async loadAbility(abilityName: string): Promise<any> {
    const ability = await this.loadContract(abilityName);
    return ability;
  }

  /**
   * Load an effect contract
   */
  async loadEffect(effectName: string): Promise<any> {
    return this.loadContract(effectName);
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
   */
  async startBattle(config: BattleConfig): Promise<string> {
    // Ensure core modules are loaded
    if (!this.container.has('Engine')) {
      await this.loadCoreModules();
    }

    // Set addresses if provided
    if (config.addresses) {
      this.setAddresses(config.addresses);
    }

    // Load all moves and abilities used by both teams
    const allMoves = new Set<string>();
    const allAbilities = new Set<string>();

    for (const team of config.teams) {
      for (const mon of team.mons) {
        mon.moves.forEach(m => allMoves.add(m));
        if (mon.ability) {
          allAbilities.add(mon.ability);
        }
      }
    }

    // Load in parallel
    await Promise.all([
      ...Array.from(allMoves).map(m => this.loadMove(m)),
      ...Array.from(allAbilities).map(a => this.loadAbility(a)),
    ]);

    // Build teams with resolved contract references
    const teams = config.teams.map((teamConfig) =>
      teamConfig.mons.map((monConfig) => this.buildMon(monConfig))
    );

    // Call Engine.startBattle() with the configuration
    // The Engine handles all battle initialization
    const engine = this.container.resolve('Engine');
    const battleKey = engine.startBattle({
      p0: config.player0,
      p1: config.player1,
      p0Team: teams[0],
      p1Team: teams[1],
      validator: this.container.resolve('DefaultValidator'),
      rngOracle: this.container.resolve('DefaultRandomnessOracle'),
    });

    return battleKey;
  }

  /**
   * Build a Mon struct from config
   */
  private buildMon(config: MonConfig): any {
    const moves = config.moves.map(moveName => this.container.resolve(moveName));
    const ability = config.ability ? this.container.resolve(config.ability) : null;

    return {
      stats: config.stats,
      type1: config.type1,
      type2: config.type2,
      moves,
      ability,
    };
  }

  /**
   * Execute a turn for a battle
   *
   * This delegates to the Engine:
   * 1. Calls setMove() for each player
   * 2. Calls execute()
   * 3. Reads back the state
   */
  executeTurn(battleKey: string, input: TurnInput): BattleState {
    // Clear events for this turn
    globalEventStream.clear();

    const engine = this.container.resolve('Engine');

    // Set moves for both players via Engine
    engine.setMove(
      battleKey,
      0,  // player 0
      input.player0.moveIndex,
      input.player0.salt,
      input.player0.extraData ?? 0n
    );

    engine.setMove(
      battleKey,
      1,  // player 1
      input.player1.moveIndex,
      input.player1.salt,
      input.player1.extraData ?? 0n
    );

    // Execute the turn - Engine handles all logic
    engine.execute(battleKey);

    // Read back the state from Engine
    return this.getBattleState(battleKey);
  }

  /**
   * Get current battle state from the Engine
   */
  getBattleState(battleKey: string): BattleState {
    const engine = this.container.resolve('Engine');

    // Get battle data from Engine
    const battleData = engine.getBattleData(battleKey);

    // Use Engine's public methods instead of reimplementing unpacking
    const activeIndices = engine.getActiveMonIndexForBattleState(battleKey);
    const activeMonIndex: [number, number] = [
      Number(activeIndices[0]),
      Number(activeIndices[1])
    ];

    // Get team sizes from Engine
    const p0TeamSize = Number(engine.getTeamSize(battleKey, 0));
    const p1TeamSize = Number(engine.getTeamSize(battleKey, 1));

    // Extract mon states
    const p0States: MonState[] = [];
    const p1States: MonState[] = [];

    for (let i = 0; i < p0TeamSize; i++) {
      p0States.push(engine.getMonState(battleKey, 0, i));
    }

    for (let i = 0; i < p1TeamSize; i++) {
      p1States.push(engine.getMonState(battleKey, 1, i));
    }

    return {
      turnId: battleData.turnId,
      activeMonIndex,
      winnerIndex: battleData.winnerIndex,
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
 * Create a battle harness with a module loader and optional container setup
 *
 * @example
 * ```typescript
 * import { setupContainer } from './ts-output/factories';
 *
 * const harness = await createBattleHarness(
 *   name => import(`./ts-output/${name}`),
 *   setupContainer
 * );
 * ```
 */
export async function createBattleHarness(
  moduleLoader: ModuleLoader,
  containerSetup?: ContainerSetupFn
): Promise<BattleHarness> {
  const harness = new BattleHarness();
  harness.setModuleLoader(moduleLoader);
  if (containerSetup) {
    harness.setContainerSetup(containerSetup);
  }
  await harness.loadCoreModules();
  return harness;
}
