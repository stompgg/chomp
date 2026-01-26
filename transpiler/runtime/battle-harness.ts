/**
 * Battle Simulation Harness
 *
 * Provides automatic dependency injection setup and turn-by-turn battle execution
 * for client-side simulations that match on-chain results.
 *
 * This is a thin wrapper around the transpiled Engine - it delegates all battle
 * logic to the Engine rather than reimplementing it.
 */

import { ContractContainer, Contract, registry, globalEventStream } from './index';

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
  moveIndex: number;  // 0-3 for moves, 125 for switch, 126 for no-op
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

// =============================================================================
// SPECIAL MOVE INDICES (exported for convenience, but handled by Engine)
// =============================================================================

export const SWITCH_MOVE_INDEX = 125;
export const NO_OP_MOVE_INDEX = 126;

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
 * const harness = new BattleHarness();
 *
 * // Load modules from transpiled output
 * await harness.loadModules(async (name) => import(`./ts-output/${name}`));
 *
 * // Configure a battle
 * const battleKey = await harness.startBattle({
 *   player0: '0x1234...',
 *   player1: '0x5678...',
 *   teams: [team1Config, team2Config],
 *   addresses: { 'Engine': '0xaaaa...', ... }
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
  private loadedModules: Map<string, any> = new Map();

  // Core singleton instances
  private engine: any;
  private typeCalculator: any;
  private validator: any;
  private rngOracle: any;

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
   * Load and register core modules
   */
  async loadCoreModules(): Promise<void> {
    if (!this.moduleLoader) {
      throw new Error('Module loader not set. Call setModuleLoader() first.');
    }

    // Load core modules
    const [
      engineModule,
      typeCalculatorModule,
      validatorModule,
      rngOracleModule,
    ] = await Promise.all([
      this.loadModule('Engine'),
      this.loadModule('TypeCalculator'),
      this.loadModule('DefaultValidator'),
      this.loadModule('DefaultRandomnessOracle'),
    ]);

    // Create core singletons
    this.engine = this.createInstance(engineModule);
    this.typeCalculator = this.createInstance(typeCalculatorModule);
    this.rngOracle = this.createInstance(rngOracleModule);

    // Validator needs engine
    const ValidatorClass = this.getExportedClass(validatorModule);
    this.validator = new ValidatorClass(this.engine);

    // Register with container
    this.container.registerSingleton('Engine', this.engine);
    this.container.registerSingleton('IEngine', this.engine);
    this.container.registerSingleton('TypeCalculator', this.typeCalculator);
    this.container.registerSingleton('ITypeCalculator', this.typeCalculator);
    this.container.registerSingleton('Validator', this.validator);
    this.container.registerSingleton('IValidator', this.validator);
    this.container.registerSingleton('RNGOracle', this.rngOracle);
    this.container.registerSingleton('IRandomnessOracle', this.rngOracle);
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
   * Create an instance from a module
   */
  private createInstance(module: any, ...args: any[]): any {
    const Class = this.getExportedClass(module);
    return new Class(...args);
  }

  /**
   * Load and register a move contract
   */
  async loadMove(moveName: string): Promise<any> {
    if (this.container.has(moveName)) {
      return this.container.resolve(moveName);
    }

    const module = await this.loadModule(moveName);
    const MoveClass = this.getExportedClass(module);

    // Create move instance with engine and type calculator
    // Most moves take (engine, typeCalculator) or just (engine)
    let move: any;
    try {
      move = new MoveClass(this.engine, this.typeCalculator);
    } catch {
      try {
        move = new MoveClass(this.engine);
      } catch {
        move = new MoveClass();
      }
    }

    this.container.registerSingleton(moveName, move);
    return move;
  }

  /**
   * Load and register an ability contract
   */
  async loadAbility(abilityName: string): Promise<any> {
    if (this.container.has(abilityName)) {
      return this.container.resolve(abilityName);
    }

    const module = await this.loadModule(abilityName);
    const AbilityClass = this.getExportedClass(module);

    let ability: any;
    try {
      ability = new AbilityClass(this.engine);
    } catch {
      ability = new AbilityClass();
    }

    this.container.registerSingleton(abilityName, ability);
    return ability;
  }

  /**
   * Load and register an effect contract
   */
  async loadEffect(effectName: string): Promise<any> {
    if (this.container.has(effectName)) {
      return this.container.resolve(effectName);
    }

    const module = await this.loadModule(effectName);
    const EffectClass = this.getExportedClass(module);

    let effect: any;
    try {
      effect = new EffectClass(this.engine);
    } catch {
      effect = new EffectClass();
    }

    this.container.registerSingleton(effectName, effect);

    // Register with effect registry
    if (effect._contractAddress) {
      registry.registerEffect(effect._contractAddress, effect);
    }

    return effect;
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
    if (!this.engine) {
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
    const battleKey = this.engine.startBattle({
      p0: config.player0,
      p1: config.player1,
      p0Team: teams[0],
      p1Team: teams[1],
      validator: this.validator,
      rngOracle: this.rngOracle,
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

    // Set moves for both players via Engine
    this.engine.setMove(
      battleKey,
      0,  // player 0
      input.player0.moveIndex,
      input.player0.salt,
      input.player0.extraData ?? 0n
    );

    this.engine.setMove(
      battleKey,
      1,  // player 1
      input.player1.moveIndex,
      input.player1.salt,
      input.player1.extraData ?? 0n
    );

    // Execute the turn - Engine handles all logic
    this.engine.execute(battleKey);

    // Read back the state from Engine
    return this.getBattleState(battleKey);
  }

  /**
   * Get current battle state from the Engine
   */
  getBattleState(battleKey: string): BattleState {
    // Get battle data from Engine
    const battleData = this.engine.getBattleData(battleKey);
    const battleConfig = this.engine.getBattleConfig(battleKey);

    // Extract active mon indices (packed in 16 bits)
    const activeMonIndex: [number, number] = [
      battleData.activeMonIndex & 0xFF,
      (battleData.activeMonIndex >> 8) & 0xFF
    ];

    // Extract mon states
    const p0States: MonState[] = [];
    const p1States: MonState[] = [];

    const p0TeamSize = battleConfig.teamSizes & 0x0F;
    const p1TeamSize = (battleConfig.teamSizes >> 4) & 0x0F;

    for (let i = 0; i < p0TeamSize; i++) {
      p0States.push(this.engine.getMonState(battleKey, 0, i));
    }

    for (let i = 0; i < p1TeamSize; i++) {
      p1States.push(this.engine.getMonState(battleKey, 1, i));
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
    return this.engine;
  }
}

// =============================================================================
// FACTORY FUNCTION
// =============================================================================

/**
 * Create a battle harness with a module loader
 *
 * @example
 * ```typescript
 * const harness = await createBattleHarness(
 *   async (name) => import(`./ts-output/${name}`)
 * );
 * ```
 */
export async function createBattleHarness(
  moduleLoader: ModuleLoader
): Promise<BattleHarness> {
  const harness = new BattleHarness();
  harness.setModuleLoader(moduleLoader);
  await harness.loadCoreModules();
  return harness;
}
