/**
 * Tests for the Battle Harness
 *
 * Run with: npx tsx test/harness-test.ts
 */

import { test, expect, runTests } from './test-utils';
import {
  BattleHarness,
  createBattleHarness,
  SWITCH_MOVE_INDEX,
  NO_OP_MOVE_INDEX,
  type MonConfig,
  type TeamConfig,
  type BattleConfig,
  type TurnInput,
} from '../runtime/index';

// =============================================================================
// MOCK CONTRACTS
// =============================================================================

class MockEngine {
  _contractAddress = '0x' + '1'.repeat(40);

  computeBattleKey(p0: string, p1: string): string {
    return '0x' + 'a'.repeat(64);
  }
}

class MockTypeCalculator {
  _contractAddress = '0x' + '2'.repeat(40);
}

class MockValidator {
  _contractAddress = '0x' + '3'.repeat(40);
  constructor(engine: any) {}
}

class MockRNGOracle {
  _contractAddress = '0x' + '4'.repeat(40);

  getRNG(salt0: string, salt1: string): bigint {
    return BigInt(salt0) ^ BigInt(salt1);
  }
}

class MockMove {
  _contractAddress: string;
  _name: string;

  constructor(engine?: any, typeCalc?: any) {
    this._name = 'MockMove';
    this._contractAddress = '0x' + '5'.repeat(40);
  }

  name(): string {
    return this._name;
  }

  priority(battleKey: string, playerIndex: number): number {
    return 0;
  }

  stamina(battleKey: string, playerIndex: number, monIndex: number): number {
    return 1;
  }

  moveType(battleKey: string): number {
    return 0;
  }

  move(battleKey: string, attackerIndex: number, extraData: bigint, rng: bigint): void {
    // Mock move execution
  }
}

class MockAbility {
  _contractAddress = '0x' + '6'.repeat(40);

  constructor(engine?: any) {}

  activateOnSwitch(battleKey: string, playerIndex: number, monIndex: number): void {
    // Mock ability activation
  }
}

// =============================================================================
// TESTS
// =============================================================================

test('BattleHarness can be created', () => {
  const harness = new BattleHarness();
  expect(harness).toBeDefined();
  expect(harness.getContainer()).toBeDefined();
});

test('BattleHarness can set module loader', () => {
  const harness = new BattleHarness();

  const mockLoader = async (name: string) => {
    if (name === 'Engine') return { Engine: MockEngine };
    if (name === 'TypeCalculator') return { TypeCalculator: MockTypeCalculator };
    if (name === 'DefaultValidator') return { DefaultValidator: MockValidator };
    if (name === 'DefaultRandomnessOracle') return { DefaultRandomnessOracle: MockRNGOracle };
    throw new Error(`Unknown module: ${name}`);
  };

  harness.setModuleLoader(mockLoader);
  // Should not throw
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

test('SWITCH_MOVE_INDEX and NO_OP_MOVE_INDEX are defined', () => {
  expect(SWITCH_MOVE_INDEX).toBe(125);
  expect(NO_OP_MOVE_INDEX).toBe(126);
});

test('Container registration works', () => {
  const harness = new BattleHarness();
  const container = harness.getContainer();

  const mockEngine = new MockEngine();
  container.registerSingleton('Engine', mockEngine);

  expect(container.has('Engine')).toBe(true);
  expect(container.resolve('Engine')).toBe(mockEngine);
});

// Run all tests
runTests();
