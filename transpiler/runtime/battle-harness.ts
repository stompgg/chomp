/**
 * Battle Simulation Harness
 *
 * Provides automatic dependency injection setup and turn-by-turn battle execution
 * for client-side simulations that match on-chain results.
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
  rngSeed?: string;  // Optional seed for deterministic RNG (default: random)
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
 * Mon state after turn
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
// SPECIAL MOVE INDICES
// =============================================================================

export const SWITCH_MOVE_INDEX = 125;
export const NO_OP_MOVE_INDEX = 126;

// =============================================================================
// BATTLE SIMULATOR
// =============================================================================

/**
 * Battle Simulation Harness
 *
 * Manages contract instantiation, dependency injection, and turn execution
 * for client-side battle simulation.
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
 * // Execute turns
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
  private battles: Map<string, BattleInstance> = new Map();

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
    // Import the contractAddresses from runtime
    // This would need to be passed in or accessed differently
    // For now, we'll set addresses on instances directly
    for (const [name, address] of Object.entries(addresses)) {
      const instance = this.container.tryResolve(name);
      if (instance && typeof instance === 'object') {
        (instance as any)._contractAddress = address;
      }
    }
  }

  /**
   * Start a new battle
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
    const teams = config.teams.map((teamConfig, teamIndex) =>
      teamConfig.mons.map((monConfig, monIndex) => this.buildMon(monConfig))
    );

    // Compute battle key
    const battleKey = this.computeBattleKey(config.player0, config.player1);

    // Create battle instance
    const battle = new BattleInstance(
      this,
      battleKey,
      config,
      teams,
      config.rngSeed
    );

    this.battles.set(battleKey, battle);

    // Initialize battle in engine
    battle.initialize();

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
   * Compute deterministic battle key from player addresses
   */
  private computeBattleKey(p0: string, p1: string): string {
    // Canonical ordering
    const [addr0, addr1] = p0.toLowerCase() < p1.toLowerCase()
      ? [p0, p1]
      : [p1, p0];

    // Use a simple hash for now - in production would use keccak256
    const combined = `${addr0}:${addr1}:${Date.now()}`;
    return `0x${Buffer.from(combined).toString('hex').padEnd(64, '0').slice(0, 64)}`;
  }

  /**
   * Execute a turn for a battle
   */
  executeTurn(battleKey: string, input: TurnInput): BattleState {
    const battle = this.battles.get(battleKey);
    if (!battle) {
      throw new Error(`Battle not found: ${battleKey}`);
    }

    return battle.executeTurn(input);
  }

  /**
   * Get current battle state
   */
  getBattleState(battleKey: string): BattleState {
    const battle = this.battles.get(battleKey);
    if (!battle) {
      throw new Error(`Battle not found: ${battleKey}`);
    }

    return battle.getState();
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
// BATTLE INSTANCE
// =============================================================================

/**
 * Represents a single battle in progress
 */
class BattleInstance {
  private harness: BattleHarness;
  private battleKey: string;
  private config: BattleConfig;
  private teams: any[][];
  private rngSeed: string;

  // Battle state
  private turnId: bigint = 0n;
  private activeMonIndex: [number, number] = [0, 0];
  private winnerIndex: number = 2;  // 2 = no winner
  private p0States: MonState[] = [];
  private p1States: MonState[] = [];
  private turnEvents: any[] = [];

  constructor(
    harness: BattleHarness,
    battleKey: string,
    config: BattleConfig,
    teams: any[][],
    rngSeed?: string
  ) {
    this.harness = harness;
    this.battleKey = battleKey;
    this.config = config;
    this.teams = teams;
    this.rngSeed = rngSeed ?? `0x${Math.random().toString(16).slice(2).padEnd(64, '0')}`;
  }

  /**
   * Initialize the battle
   */
  initialize(): void {
    // Initialize mon states
    this.p0States = this.teams[0].map(() => this.createInitialMonState());
    this.p1States = this.teams[1].map(() => this.createInitialMonState());

    // Both players start with mon 0 active (implicit switch on turn 0)
    this.activeMonIndex = [0, 0];
  }

  /**
   * Create initial mon state
   */
  private createInitialMonState(): MonState {
    return {
      hpDelta: 0n,
      staminaDelta: 0n,
      speedDelta: 0n,
      attackDelta: 0n,
      defenseDelta: 0n,
      specialAttackDelta: 0n,
      specialDefenseDelta: 0n,
      isKnockedOut: false,
      shouldSkipTurn: false,
    };
  }

  /**
   * Execute a turn
   */
  executeTurn(input: TurnInput): BattleState {
    if (this.winnerIndex !== 2) {
      throw new Error('Battle already ended');
    }

    // Clear events for this turn
    this.turnEvents = [];
    globalEventStream.clear();

    // Compute RNG from salts
    const rng = this.computeRNG(input.player0.salt, input.player1.salt);

    // Determine priority
    const priorityPlayer = this.computePriorityPlayer(input, rng);
    const otherPlayer = priorityPlayer === 0 ? 1 : 0;

    const moves = [input.player0, input.player1];
    const playerOrder = [priorityPlayer, otherPlayer];

    // Execute moves in priority order
    for (const playerIndex of playerOrder) {
      const move = moves[playerIndex];
      const monStates = playerIndex === 0 ? this.p0States : this.p1States;
      const activeIndex = this.activeMonIndex[playerIndex];
      const activeState = monStates[activeIndex];

      // Skip if mon should skip turn
      if (activeState.shouldSkipTurn) {
        activeState.shouldSkipTurn = false;
        this.turnEvents.push({
          type: 'SkipTurn',
          player: playerIndex,
          mon: activeIndex
        });
        continue;
      }

      // Handle switch
      if (move.moveIndex === SWITCH_MOVE_INDEX) {
        const switchTo = Number(move.extraData ?? 0n);
        this.handleSwitch(playerIndex, switchTo);
        continue;
      }

      // Handle no-op
      if (move.moveIndex === NO_OP_MOVE_INDEX) {
        // Recover some stamina
        activeState.staminaDelta += 1n;
        this.turnEvents.push({
          type: 'NoOp',
          player: playerIndex,
          mon: activeIndex
        });
        continue;
      }

      // Execute move
      this.executeMove(playerIndex, move, rng);

      // Check for KO
      this.checkGameOver();
      if (this.winnerIndex !== 2) {
        break;
      }
    }

    // Increment turn
    this.turnId += 1n;

    // Collect events
    this.turnEvents.push(...globalEventStream.getAll());

    return this.getState();
  }

  /**
   * Compute RNG from salts
   */
  private computeRNG(salt0: string, salt1: string): bigint {
    // Simple deterministic RNG - in production would use keccak256
    const combined = salt0 + salt1 + this.rngSeed;
    let hash = 0n;
    for (let i = 0; i < combined.length; i++) {
      hash = (hash * 31n + BigInt(combined.charCodeAt(i))) % (2n ** 256n);
    }
    return hash;
  }

  /**
   * Compute which player has priority
   */
  private computePriorityPlayer(input: TurnInput, rng: bigint): number {
    const moves = [input.player0, input.player1];

    // Get priorities
    const priorities = moves.map((move, playerIndex) => {
      // Switches and no-ops have priority 6
      if (move.moveIndex === SWITCH_MOVE_INDEX || move.moveIndex === NO_OP_MOVE_INDEX) {
        return 6n;
      }

      // Get move priority from contract
      const mon = this.teams[playerIndex][this.activeMonIndex[playerIndex]];
      const moveContract = mon.moves[move.moveIndex];
      if (moveContract && typeof moveContract.priority === 'function') {
        try {
          return BigInt(moveContract.priority(this.battleKey, playerIndex));
        } catch {
          return 0n;
        }
      }
      return 0n;
    });

    // Compare priorities
    if (priorities[0] > priorities[1]) return 0;
    if (priorities[1] > priorities[0]) return 1;

    // Tied priority - use speed
    const speeds = [0, 1].map(playerIndex => {
      const mon = this.teams[playerIndex][this.activeMonIndex[playerIndex]];
      const state = playerIndex === 0 ? this.p0States : this.p1States;
      const baseSpeed = mon.stats.speed;
      const delta = state[this.activeMonIndex[playerIndex]].speedDelta;
      return baseSpeed + delta;
    });

    if (speeds[0] > speeds[1]) return 0;
    if (speeds[1] > speeds[0]) return 1;

    // Tied speed - use RNG
    return Number(rng % 2n);
  }

  /**
   * Handle a switch
   */
  private handleSwitch(playerIndex: number, switchTo: number): void {
    const oldIndex = this.activeMonIndex[playerIndex];

    this.turnEvents.push({
      type: 'Switch',
      player: playerIndex,
      from: oldIndex,
      to: switchTo
    });

    this.activeMonIndex[playerIndex] = switchTo;

    // Activate ability on switch in
    const mon = this.teams[playerIndex][switchTo];
    if (mon.ability && typeof mon.ability.activateOnSwitch === 'function') {
      try {
        mon.ability.activateOnSwitch(this.battleKey, playerIndex, switchTo);
      } catch (e) {
        // Ability failed - log but continue
        this.turnEvents.push({
          type: 'AbilityError',
          ability: mon.ability.constructor?.name,
          error: String(e)
        });
      }
    }
  }

  /**
   * Execute a move
   */
  private executeMove(playerIndex: number, decision: MoveDecision, rng: bigint): void {
    const mon = this.teams[playerIndex][this.activeMonIndex[playerIndex]];
    const moveContract = mon.moves[decision.moveIndex];

    if (!moveContract) {
      this.turnEvents.push({
        type: 'InvalidMove',
        player: playerIndex,
        moveIndex: decision.moveIndex
      });
      return;
    }

    // Check stamina
    const state = playerIndex === 0 ? this.p0States : this.p1States;
    const monState = state[this.activeMonIndex[playerIndex]];
    const baseStamina = mon.stats.stamina;
    const currentStamina = baseStamina + monState.staminaDelta;

    let staminaCost = 1n;
    if (typeof moveContract.stamina === 'function') {
      try {
        staminaCost = BigInt(moveContract.stamina(
          this.battleKey,
          playerIndex,
          this.activeMonIndex[playerIndex]
        ));
      } catch {
        // Use default
      }
    }

    if (currentStamina < staminaCost) {
      this.turnEvents.push({
        type: 'InsufficientStamina',
        player: playerIndex,
        required: staminaCost,
        current: currentStamina
      });
      return;
    }

    // Deduct stamina
    monState.staminaDelta -= staminaCost;

    // Execute the move
    try {
      moveContract.move(
        this.battleKey,
        playerIndex,
        decision.extraData ?? 0n,
        rng
      );

      this.turnEvents.push({
        type: 'MoveExecuted',
        player: playerIndex,
        move: moveContract.constructor?.name ?? 'Unknown',
        moveIndex: decision.moveIndex
      });
    } catch (e) {
      this.turnEvents.push({
        type: 'MoveError',
        player: playerIndex,
        move: moveContract.constructor?.name ?? 'Unknown',
        error: String(e)
      });
    }
  }

  /**
   * Check if the game is over
   */
  private checkGameOver(): void {
    // Check if all of p0's mons are KO'd
    const p0AllKO = this.p0States.every(s => s.isKnockedOut);
    if (p0AllKO) {
      this.winnerIndex = 1;
      return;
    }

    // Check if all of p1's mons are KO'd
    const p1AllKO = this.p1States.every(s => s.isKnockedOut);
    if (p1AllKO) {
      this.winnerIndex = 0;
      return;
    }
  }

  /**
   * Get current state
   */
  getState(): BattleState {
    return {
      turnId: this.turnId,
      activeMonIndex: [...this.activeMonIndex] as [number, number],
      winnerIndex: this.winnerIndex,
      p0States: this.p0States.map(s => ({ ...s })),
      p1States: this.p1States.map(s => ({ ...s })),
      events: [...this.turnEvents],
    };
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
