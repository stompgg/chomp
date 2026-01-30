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

  constructor(container: ContractContainer) {
    this.container = container;
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
  startBattle(config: BattleConfig): string {
    // Set addresses if provided
    if (config.addresses) {
      this.setAddresses(config.addresses);
    }

    // Build teams with resolved contract references
    const teams = config.teams.map((teamConfig) =>
      teamConfig.mons.map((monConfig) => this.buildMon(monConfig))
    );

    // Call Engine.startBattle() with the configuration
    const engine = this.container.resolve('Engine');
    const battleKey = engine.startBattle({
      p0: config.player0,
      p1: config.player1,
      p0Team: teams[0],
      p1Team: teams[1],
      validator: this.container.resolve('IValidator'),
      rngOracle: this.container.resolve('IRandomnessOracle'),
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
