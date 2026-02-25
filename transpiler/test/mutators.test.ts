/**
 * E2E Tests for __mutate* Methods
 *
 * Tests that the transpiler-generated mutator methods work correctly
 * for state manipulation in testing scenarios.
 *
 * Run with: npx vitest run test/mutators.test.ts
 */

import { describe, it, expect, beforeEach } from 'vitest';

// Core transpiled contracts
import { Engine } from '../ts-output/Engine';

// Types and constants
import * as Structs from '../ts-output/Structs';
import * as Enums from '../ts-output/Enums';

// Runtime
import { globalEventStream, ContractContainer } from '../ts-output/runtime';
import { BattleHarness } from '../ts-output/runtime/battle-harness';
import { setupContainer } from '../ts-output/factories';

// =============================================================================
// TEST UTILITIES
// =============================================================================

let addressCounter = 1;
function generateAddress(): string {
  return `0x${(addressCounter++).toString(16).padStart(40, '0')}`;
}

function setAddress(instance: any): string {
  const addr = generateAddress();
  instance._contractAddress = addr;
  return addr;
}

// =============================================================================
// MOCK CONTRACTS (for contracts with value type dependencies)
// =============================================================================

/**
 * Mock Validator that always passes
 */
class MockValidator {
  _contractAddress: string;

  constructor() {
    this._contractAddress = generateAddress();
  }

  validateGameStart(): boolean {
    return true;
  }

  validateTeamSize(): bigint[] {
    return [1n, 6n];
  }

  validateSwitch(_battleKey: string, _playerIndex: bigint, _monToSwitchIndex: bigint): boolean {
    return true;
  }

  validateSpecificMoveSelection(_battleKey: string, _moveIndex: bigint, _playerIndex: bigint, _extraData: bigint): boolean {
    return true;
  }

  validateTimeout(_battleKey: string, _presumedAFKPlayerIndex: bigint): string {
    // Return zero address = no timeout winner
    return '0x0000000000000000000000000000000000000000';
  }
}

/**
 * Mock Ruleset
 */
class MockRuleset {
  _contractAddress: string;

  constructor() {
    this._contractAddress = '0x0000000000000000000000000000000000000000';
  }

  getInitialGlobalEffects(): [any[], string[]] {
    return [[], []];
  }
}

/**
 * Mock RNG Oracle
 */
class MockRNGOracle {
  _contractAddress: string;
  private seed: bigint;

  constructor(seed: bigint = 12345n) {
    this._contractAddress = generateAddress();
    this.seed = seed;
  }

  getRNG(): bigint {
    this.seed = (this.seed * 1103515245n + 12345n) % (2n ** 256n);
    return this.seed;
  }
}

/**
 * Create a container with mocks registered for contracts with value type dependencies
 */
function createTestContainer(): ContractContainer {
  const container = new ContractContainer();
  setupContainer(container);

  // Register mocks for contracts that need value type parameters
  const validator = new MockValidator();
  const ruleset = new MockRuleset();
  const rngOracle = new MockRNGOracle();

  container.registerSingleton('MockValidator', validator);
  container.registerSingleton('MockRuleset', ruleset);
  container.registerSingleton('MockRNGOracle', rngOracle);

  // Override the interface aliases to use our mocks
  container.registerAlias('IValidator', 'MockValidator');
  container.registerAlias('IRuleset', 'MockRuleset');
  container.registerAlias('IRandomnessOracle', 'MockRNGOracle');

  return container;
}

// =============================================================================
// MUTATOR METHOD TESTS
// =============================================================================

describe('__mutate* methods', () => {
  let engine: Engine;

  beforeEach(() => {
    addressCounter = 1;
    engine = new Engine();
    setAddress(engine);
    globalEventStream.clear();
  });

  describe('nested mappings', () => {
    it('should mutate isMatchmakerFor with nested keys', () => {
      const player = generateAddress();
      const matchmaker = generateAddress();

      // Use the mutator to set the value directly
      (engine as any).__mutateIsMatchmakerFor(player, matchmaker, true);

      // Verify the value was set via the public getter function
      expect(engine.isMatchmakerFor(player, matchmaker)).toBe(true);
    });

    it('should create intermediate objects for nested mappings', () => {
      const player = generateAddress();
      const matchmaker = generateAddress();

      // Before mutation, the getter should return the default value (false)
      expect(engine.isMatchmakerFor(player, matchmaker)).toBe(false);

      // Mutation should create the intermediate object
      (engine as any).__mutateIsMatchmakerFor(player, matchmaker, true);

      // Now it should return true
      expect(engine.isMatchmakerFor(player, matchmaker)).toBe(true);
    });

    it('should allow overwriting values in nested mappings', () => {
      const player = generateAddress();
      const matchmaker = generateAddress();

      // Set to true first
      (engine as any).__mutateIsMatchmakerFor(player, matchmaker, true);
      expect(engine.isMatchmakerFor(player, matchmaker)).toBe(true);

      // Then set to false
      (engine as any).__mutateIsMatchmakerFor(player, matchmaker, false);
      expect(engine.isMatchmakerFor(player, matchmaker)).toBe(false);
    });
  });

  describe('simple values', () => {
    it('should have mutator methods for simple state variables', () => {
      // The Engine should have mutators for its simple state variables
      // Check that the mutator exists as a function
      expect(typeof (engine as any).__mutatePairHashNonces).toBe('function');
    });
  });
});

// =============================================================================
// HARNESS INTEGRATION TESTS
// =============================================================================

describe('BattleHarness integration with mutators', () => {
  let harness: BattleHarness;

  beforeEach(() => {
    addressCounter = 1;
    globalEventStream.clear();
    const container = createTestContainer();
    harness = new BattleHarness(container);
  });

  it('should start a battle using mutators for authorization', () => {
    const player0 = generateAddress();
    const player1 = generateAddress();

    const battleKey = harness.startBattle({
      player0,
      player1,
      teams: [
        {
          mons: [
            {
              stats: {
                hp: 100n,
                stamina: 10n,
                speed: 50n,
                attack: 60n,
                defense: 50n,
                specialAttack: 60n,
                specialDefense: 50n,
              },
              type1: Enums.Type.Fire,
              type2: Enums.Type.None,
              moves: ['BigBite'],
              ability: 'Angery',
            },
          ],
        },
        {
          mons: [
            {
              stats: {
                hp: 100n,
                stamina: 10n,
                speed: 45n,
                attack: 55n,
                defense: 55n,
                specialAttack: 55n,
                specialDefense: 55n,
              },
              type1: Enums.Type.Liquid,
              type2: Enums.Type.None,
              moves: ['BigBite'],
              ability: 'Angery',
            },
          ],
        },
      ],
    });

    expect(battleKey).toBeDefined();
    expect(battleKey.startsWith('0x')).toBe(true);
    expect(battleKey.length).toBe(66); // 0x + 64 hex chars
  });

  it('should execute a turn using moveManager', () => {
    const player0 = generateAddress();
    const player1 = generateAddress();

    const battleKey = harness.startBattle({
      player0,
      player1,
      teams: [
        {
          mons: [
            {
              stats: {
                hp: 500n,  // High HP to survive multiple turns
                stamina: 10n,
                speed: 50n,
                attack: 60n,
                defense: 50n,
                specialAttack: 60n,
                specialDefense: 50n,
              },
              type1: Enums.Type.Fire,
              type2: Enums.Type.None,
              moves: ['BigBite'],
              ability: 'Angery',
            },
          ],
        },
        {
          mons: [
            {
              stats: {
                hp: 500n,  // High HP to survive multiple turns
                stamina: 10n,
                speed: 45n,
                attack: 55n,
                defense: 55n,
                specialAttack: 55n,
                specialDefense: 55n,
              },
              type1: Enums.Type.Liquid,
              type2: Enums.Type.None,
              moves: ['BigBite'],
              ability: 'Angery',
            },
          ],
        },
      ],
    });

    // Execute a turn - both players use their first move
    const state = harness.executeTurn(battleKey, {
      player0: { moveIndex: 0, salt: '0x0000000000000000000000000000000000000000000000000000000000000001', extraData: 0n },
      player1: { moveIndex: 0, salt: '0x0000000000000000000000000000000000000000000000000000000000000002', extraData: 0n },
    });

    // Turn should have advanced
    expect(state.turnId).toBe(1n);
    // No winner yet (with high HP, one turn doesn't decide the battle)
    expect(state.winnerIndex).toBe(2); // 2 = no winner
  });

  it('should get battle state correctly', () => {
    const player0 = generateAddress();
    const player1 = generateAddress();

    const battleKey = harness.startBattle({
      player0,
      player1,
      teams: [
        {
          mons: [
            {
              stats: {
                hp: 100n,
                stamina: 10n,
                speed: 50n,
                attack: 60n,
                defense: 50n,
                specialAttack: 60n,
                specialDefense: 50n,
              },
              type1: Enums.Type.Fire,
              type2: Enums.Type.None,
              moves: ['BigBite'],
              ability: 'Angery',
            },
          ],
        },
        {
          mons: [
            {
              stats: {
                hp: 100n,
                stamina: 10n,
                speed: 45n,
                attack: 55n,
                defense: 55n,
                specialAttack: 55n,
                specialDefense: 55n,
              },
              type1: Enums.Type.Liquid,
              type2: Enums.Type.None,
              moves: ['BigBite'],
              ability: 'Angery',
            },
          ],
        },
      ],
    });

    const state = harness.getBattleState(battleKey);

    expect(state.turnId).toBe(0n);
    expect(state.activeMonIndex).toEqual([0, 0]);
    expect(state.winnerIndex).toBe(2);
    expect(state.p0States.length).toBe(1);
    expect(state.p1States.length).toBe(1);
  });
});
