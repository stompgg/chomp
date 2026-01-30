/**
 * Tests for the Battle Harness
 *
 * Run with: npx tsx test/harness-test.ts
 */

import { test, expect, runTests } from './test-utils';
import {
  BattleHarness,
  createBattleHarness,
  ContractContainer,
  type MonConfig,
  type TeamConfig,
  type BattleConfig,
  type TurnInput,
} from '../runtime/index';

// These constants are defined in Solidity (src/Constants.sol) and emitted by the transpiler.
// For tests, we define them locally to match the Solidity source of truth.
// In production, import from transpiled Constants.ts instead.
const SWITCH_MOVE_INDEX = 125;
const NO_OP_MOVE_INDEX = 126;

// =============================================================================
// MOCK SETUP
// =============================================================================

/**
 * Create a mock container setup function for testing
 */
function mockSetupContainer(container: ContractContainer): void {
  // Register mock singletons
  container.registerLazySingleton('Engine', [], () => ({
    _contractAddress: '0x' + '1'.repeat(40),
    computeBattleKey: () => '0x' + 'a'.repeat(64),
  }));

  container.registerLazySingleton('TypeCalculator', [], () => ({
    _contractAddress: '0x' + '2'.repeat(40),
  }));

  container.registerLazySingleton('DefaultRandomnessOracle', [], () => ({
    _contractAddress: '0x' + '4'.repeat(40),
    getRNG: (salt0: string, salt1: string) => BigInt(salt0) ^ BigInt(salt1),
  }));

  container.registerLazySingleton('DefaultValidator', [], () => ({
    _contractAddress: '0x' + '3'.repeat(40),
  }));

  // Register interface aliases
  container.registerAlias('IEngine', 'Engine');
  container.registerAlias('ITypeCalculator', 'TypeCalculator');
  container.registerAlias('IRandomnessOracle', 'DefaultRandomnessOracle');
  container.registerAlias('IValidator', 'DefaultValidator');
}

// =============================================================================
// TESTS
// =============================================================================

test('BattleHarness can be created with container', () => {
  const container = new ContractContainer();
  mockSetupContainer(container);
  const harness = new BattleHarness(container);
  expect(harness).toBeDefined();
  expect(harness.getContainer()).toBeDefined();
});

test('createBattleHarness creates harness with setup function', () => {
  const harness = createBattleHarness(mockSetupContainer);
  expect(harness).toBeDefined();
  expect(harness.getContainer().has('Engine')).toBe(true);
});

test('MonConfig interface works correctly', () => {
  const monConfig: MonConfig = {
    stats: {
      hp: 100n,
      stamina: 10n,
      speed: 50n,
      attack: 60n,
      defense: 40n,
      specialAttack: 70n,
      specialDefense: 45n,
    },
    type1: 1,
    type2: 0,
    moves: ['MockMove1', 'MockMove2'],
    ability: 'MockAbility',
  };

  expect(monConfig.stats.hp).toBe(100n);
  expect(monConfig.moves.length).toBe(2);
});

test('TeamConfig interface works correctly', () => {
  const team: TeamConfig = {
    mons: [
      {
        stats: {
          hp: 100n,
          stamina: 10n,
          speed: 50n,
          attack: 60n,
          defense: 40n,
          specialAttack: 70n,
          specialDefense: 45n,
        },
        type1: 1,
        type2: 0,
        moves: ['MockMove'],
        ability: 'MockAbility',
      },
    ],
  };

  expect(team.mons.length).toBe(1);
  expect(team.mons[0].stats.hp).toBe(100n);
});

test('BattleConfig interface works correctly', () => {
  const config: BattleConfig = {
    player0: '0x' + '1'.repeat(40),
    player1: '0x' + '2'.repeat(40),
    teams: [
      { mons: [] },
      { mons: [] },
    ],
    addresses: {
      'Engine': '0x' + 'a'.repeat(40),
    },
    rngSeed: '0x' + 'b'.repeat(64),
  };

  expect(config.player0).toContain('0x');
  expect(config.teams.length).toBe(2);
});

test('TurnInput interface works correctly', () => {
  const input: TurnInput = {
    player0: {
      moveIndex: 0,
      salt: '0x' + 'a'.repeat(64),
      extraData: 0n,
    },
    player1: {
      moveIndex: SWITCH_MOVE_INDEX,
      salt: '0x' + 'b'.repeat(64),
      extraData: 1n,
    },
  };

  expect(input.player0.moveIndex).toBe(0);
  expect(input.player1.moveIndex).toBe(SWITCH_MOVE_INDEX);
});

test('Move indices match Solidity Constants.sol', () => {
  // These values must match src/Constants.sol - if Solidity changes, update here
  expect(SWITCH_MOVE_INDEX).toBe(125);
  expect(NO_OP_MOVE_INDEX).toBe(126);
});

test('Container registration and resolution works', () => {
  const harness = createBattleHarness(mockSetupContainer);
  const container = harness.getContainer();

  expect(container.has('Engine')).toBe(true);
  expect(container.has('IEngine')).toBe(true);

  const engine = container.resolve('Engine');
  const engineViaInterface = container.resolve('IEngine');
  expect(engine).toBe(engineViaInterface);
});

test('getEngine returns engine from container', () => {
  const harness = createBattleHarness(mockSetupContainer);
  const engine = harness.getEngine();
  expect(engine).toBeDefined();
  expect(engine._contractAddress).toContain('0x');
});

// Run all tests
runTests();
