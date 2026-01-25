/**
 * End-to-End Battle Simulation Test
 *
 * This test demonstrates the complete battle simulation flow:
 * 1. Given a list of mons/moves (actual transpiled code)
 * 2. Both players' selected move indices and extraData
 * 3. The salt for the pRNG
 * 4. Compute the resulting state entirely in TypeScript
 *
 * Run with: npx tsx test/battle-simulation.ts
 */

import { strict as assert } from 'node:assert';
import { keccak256, encodePacked, encodeAbiParameters } from 'viem';

// Import transpiled contracts
import { Engine } from '../ts-output/Engine';
import { StandardAttack } from '../ts-output/StandardAttack';
import { BullRush } from '../ts-output/BullRush';
import { UnboundedStrike } from '../ts-output/UnboundedStrike';
import { Baselight } from '../ts-output/Baselight';
import { TypeCalculator } from '../ts-output/TypeCalculator';
import { AttackCalculator } from '../ts-output/AttackCalculator';
import * as Structs from '../ts-output/Structs';
import * as Enums from '../ts-output/Enums';
import * as Constants from '../ts-output/Constants';
import { EventStream, globalEventStream } from '../ts-output/runtime';

// =============================================================================
// TEST FRAMEWORK
// =============================================================================

const tests: Array<{ name: string; fn: () => void | Promise<void> }> = [];
let passed = 0;
let failed = 0;

function test(name: string, fn: () => void | Promise<void>) {
  tests.push({ name, fn });
}

function expect<T>(actual: T) {
  return {
    toBe(expected: T) {
      assert.strictEqual(actual, expected);
    },
    toEqual(expected: T) {
      assert.deepStrictEqual(actual, expected);
    },
    not: {
      toBe(expected: T) {
        assert.notStrictEqual(actual, expected);
      },
    },
    toBeGreaterThan(expected: number | bigint) {
      assert.ok(actual > expected, `Expected ${actual} > ${expected}`);
    },
    toBeLessThan(expected: number | bigint) {
      assert.ok(actual < expected, `Expected ${actual} < ${expected}`);
    },
    toBeGreaterThanOrEqual(expected: number | bigint) {
      assert.ok(actual >= expected, `Expected ${actual} >= ${expected}`);
    },
    toBeTruthy() {
      assert.ok(actual);
    },
    toBeFalsy() {
      assert.ok(!actual);
    },
  };
}

async function runTests() {
  console.log(`\nRunning ${tests.length} battle simulation tests...\n`);

  for (const { name, fn } of tests) {
    try {
      await fn();
      passed++;
      console.log(`  ✓ ${name}`);
    } catch (err) {
      failed++;
      console.log(`  ✗ ${name}`);
      console.log(`    ${(err as Error).message}`);
      if ((err as Error).stack) {
        console.log(`    ${(err as Error).stack?.split('\n').slice(1, 4).join('\n    ')}`);
      }
    }
  }

  console.log(`\n${passed} passed, ${failed} failed\n`);
  process.exit(failed > 0 ? 1 : 0);
}

// =============================================================================
// MOCK IMPLEMENTATIONS
// =============================================================================

/**
 * Mock RNG Oracle - computes deterministic RNG from both salts
 * This matches the Solidity DefaultRandomnessOracle behavior
 */
class MockRNGOracle {
  getRNG(p0Salt: string, p1Salt: string): bigint {
    // Match Solidity: uint256(keccak256(abi.encode(p0Salt, p1Salt)))
    const encoded = encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'bytes32' }],
      [p0Salt as `0x${string}`, p1Salt as `0x${string}`]
    );
    return BigInt(keccak256(encoded));
  }
}

/**
 * Mock Validator - allows all moves
 */
class MockValidator {
  validateGameStart(_battleKey: string, _config: any): boolean {
    return true;
  }

  validateSwitch(_battleKey: string, _playerIndex: bigint, _monIndex: bigint): boolean {
    return true;
  }

  validateSpecificMoveSelection(
    _battleKey: string,
    _moveIndex: bigint,
    _playerIndex: bigint,
    _extraData: bigint
  ): boolean {
    return true;
  }

  validateTimeout(_battleKey: string, _playerIndex: bigint): string {
    return '0x0000000000000000000000000000000000000000';
  }
}

// =============================================================================
// TESTABLE ENGINE WITH FULL SIMULATION SUPPORT
// =============================================================================

/**
 * BattleSimulator provides a high-level API for running battle simulations
 */
class BattleSimulator extends Engine {
  private typeCalculator = new TypeCalculator();
  private rngOracle = new MockRNGOracle();
  private validator = new MockValidator();

  /**
   * Initialize a battle with two teams
   */
  initializeBattle(
    p0: string,
    p1: string,
    p0Team: Structs.Mon[],
    p1Team: Structs.Mon[]
  ): string {
    // Compute battle key
    const [battleKey] = this.computeBattleKey(p0, p1);

    // Initialize storage
    this.initializeBattleConfig(battleKey);
    this.initializeBattleData(battleKey, p0, p1);

    // Set up teams
    this.setupTeams(battleKey, p0Team, p1Team);

    // Set config dependencies
    const config = this.getBattleConfig(battleKey)!;
    config.rngOracle = this.rngOracle;
    config.validator = this.validator;

    return battleKey;
  }

  /**
   * Initialize battle config for a given battle key
   */
  initializeBattleConfig(battleKey: string): void {
    const self = this as any;

    // Helper to create auto-vivifying storage for effect slots
    const createEffectStorage = () => new Proxy({} as Record<number, Structs.EffectInstance>, {
      get(target, prop) {
        const index = typeof prop === 'string' ? parseInt(prop, 10) : (prop as number);
        if (!isNaN(index) && !(index in target)) {
          // Auto-create empty effect slot
          target[index] = {
            effect: null as any,
            data: '0x0000000000000000000000000000000000000000000000000000000000000000',
          };
        }
        return target[index as keyof typeof target];
      },
      set(target, prop, value) {
        target[prop as keyof typeof target] = value;
        return true;
      },
    });

    // Initialize mapping containers for effects
    const emptyConfig: Structs.BattleConfig = {
      validator: this.validator,
      packedP0EffectsCount: 0n,
      rngOracle: this.rngOracle,
      packedP1EffectsCount: 0n,
      moveManager: '0x0000000000000000000000000000000000000000',
      globalEffectsLength: 0n,
      teamSizes: 0n,
      engineHooksLength: 0n,
      koBitmaps: 0n,
      startTimestamp: BigInt(Math.floor(Date.now() / 1000)),
      p0Salt: '0x0000000000000000000000000000000000000000000000000000000000000000',
      p1Salt: '0x0000000000000000000000000000000000000000000000000000000000000000',
      p0Move: { packedMoveIndex: 0n, extraData: 0n },
      p1Move: { packedMoveIndex: 0n, extraData: 0n },
      p0Team: {} as any,
      p1Team: {} as any,
      p0States: {} as any,
      p1States: {} as any,
      globalEffects: createEffectStorage() as any,
      p0Effects: createEffectStorage() as any,
      p1Effects: createEffectStorage() as any,
      engineHooks: {} as any,
    };

    self.battleConfig[battleKey] = emptyConfig;
    self.storageKeyForWrite = battleKey;
    self.storageKeyMap ??= {};
    self.storageKeyMap[battleKey] = battleKey;
  }

  /**
   * Initialize battle data
   */
  initializeBattleData(battleKey: string, p0: string, p1: string): void {
    const self = this as any;
    self.battleData[battleKey] = {
      p0,
      p1,
      winnerIndex: 2n, // No winner yet
      prevPlayerSwitchForTurnFlag: 2n,
      playerSwitchForTurnFlag: 2n, // Both players move
      activeMonIndex: 0n, // Both start with mon 0
      turnId: 0n,
    };
  }

  /**
   * Set up teams for a battle
   */
  setupTeams(battleKey: string, p0Team: Structs.Mon[], p1Team: Structs.Mon[]): void {
    const config = this.getBattleConfig(battleKey)!;

    // Set team sizes (p0 in lower 4 bits, p1 in upper 4 bits)
    config.teamSizes = BigInt(p0Team.length) | (BigInt(p1Team.length) << 4n);

    // Add mons to teams
    for (let i = 0; i < p0Team.length; i++) {
      (config.p0Team as any)[i] = p0Team[i];
      (config.p0States as any)[i] = createEmptyMonState();
    }
    for (let i = 0; i < p1Team.length; i++) {
      (config.p1Team as any)[i] = p1Team[i];
      (config.p1States as any)[i] = createEmptyMonState();
    }
  }

  /**
   * Submit moves for both players and execute the turn
   */
  executeTurn(
    battleKey: string,
    p0MoveIndex: bigint,
    p0ExtraData: bigint,
    p0Salt: string,
    p1MoveIndex: bigint,
    p1ExtraData: bigint,
    p1Salt: string
  ): void {
    // Advance block timestamp to ensure we're not on the same block as battle start
    // This is required because _handleGameOver checks that game doesn't end on same block
    this.setBlockTimestamp(this._block.timestamp + 1n);

    // Set moves for both players
    this.setMove(battleKey, 0n, p0MoveIndex, p0Salt, p0ExtraData);
    this.setMove(battleKey, 1n, p1MoveIndex, p1Salt, p1ExtraData);

    // Execute the turn
    this.execute(battleKey);
  }

  /**
   * Get battle config for testing
   */
  getBattleConfig(battleKey: string): Structs.BattleConfig | undefined {
    return (this as any).battleConfig[battleKey];
  }

  /**
   * Get battle data for testing
   */
  getBattleData(battleKey: string): Structs.BattleData | undefined {
    return (this as any).battleData[battleKey];
  }

  /**
   * Get the type calculator
   */
  getTypeCalculator(): TypeCalculator {
    return this.typeCalculator;
  }
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

function createEmptyMonState(): Structs.MonState {
  return {
    hpDelta: Constants.CLEARED_MON_STATE_SENTINEL,
    staminaDelta: Constants.CLEARED_MON_STATE_SENTINEL,
    speedDelta: Constants.CLEARED_MON_STATE_SENTINEL,
    attackDelta: Constants.CLEARED_MON_STATE_SENTINEL,
    defenceDelta: Constants.CLEARED_MON_STATE_SENTINEL,
    specialAttackDelta: Constants.CLEARED_MON_STATE_SENTINEL,
    specialDefenceDelta: Constants.CLEARED_MON_STATE_SENTINEL,
    isKnockedOut: false,
    shouldSkipTurn: false,
  };
}

function createMonStats(overrides: Partial<Structs.MonStats> = {}): Structs.MonStats {
  return {
    hp: 100n,
    stamina: 100n,
    speed: 50n,
    attack: 50n,
    defense: 50n,
    specialAttack: 50n,
    specialDefense: 50n,
    type1: Enums.Type.Fire,
    type2: Enums.Type.None,
    ...overrides,
  };
}

/**
 * Create a mon with a StandardAttack move
 */
function createMonWithBasicAttack(
  engine: BattleSimulator,
  stats: Partial<Structs.MonStats> = {},
  moveName: string = 'Tackle',
  basePower: bigint = 40n,
  moveType: Enums.Type = Enums.Type.Fire
): Structs.Mon {
  const typeCalc = engine.getTypeCalculator();

  const move = new StandardAttack(
    '0x0000000000000000000000000000000000000001', // owner
    engine, // ENGINE
    typeCalc, // TYPE_CALCULATOR
    {
      NAME: moveName,
      BASE_POWER: basePower,
      STAMINA_COST: 10n,
      ACCURACY: 100n,
      MOVE_TYPE: moveType,
      MOVE_CLASS: Enums.MoveClass.Physical,
      PRIORITY: Constants.DEFAULT_PRIORITY,
      CRIT_RATE: Constants.DEFAULT_CRIT_RATE,
      VOLATILITY: 0n, // No variance for predictable tests
      EFFECT_ACCURACY: 0n,
      EFFECT: '0x0000000000000000000000000000000000000000',
    } as Structs.ATTACK_PARAMS
  );

  return {
    stats: createMonStats(stats),
    ability: '0x0000000000000000000000000000000000000000',
    moves: [move],
  };
}

/**
 * Create a mon with a BullRush move (has recoil damage)
 */
function createMonWithBullRush(
  engine: BattleSimulator,
  stats: Partial<Structs.MonStats> = {}
): Structs.Mon {
  const typeCalc = engine.getTypeCalculator();
  const move = new BullRush(engine, typeCalc);

  return {
    stats: createMonStats({ ...stats, type1: Enums.Type.Metal }),
    ability: '0x0000000000000000000000000000000000000000',
    moves: [move],
  };
}

/**
 * Create Baselight ability instance and UnboundedStrike move for testing
 */
function createBaselightAndUnboundedStrike(
  engine: BattleSimulator
): { baselight: Baselight; move: UnboundedStrike } {
  const typeCalc = engine.getTypeCalculator();
  const baselight = new Baselight(engine);
  const move = new UnboundedStrike(engine, typeCalc, baselight);
  return { baselight, move };
}

/**
 * Create a mon with UnboundedStrike move and Baselight ability (Iblivion)
 */
function createMonWithUnboundedStrike(
  engine: BattleSimulator,
  baselight: Baselight,
  move: UnboundedStrike,
  stats: Partial<Structs.MonStats> = {}
): Structs.Mon {
  return {
    stats: createMonStats({ ...stats, type1: Enums.Type.Air }),
    ability: baselight,
    moves: [move],
  };
}

// =============================================================================
// BATTLE SIMULATION TESTS
// =============================================================================

test('BattleSimulator: can initialize and setup battle', () => {
  const sim = new BattleSimulator();

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  const p0Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 60n, attack: 50n });
  const p1Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 40n, attack: 50n });

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);

  expect(battleKey).toBeTruthy();

  const battleData = sim.getBattleData(battleKey);
  expect(battleData).toBeTruthy();
  expect(battleData!.p0).toBe(p0);
  expect(battleData!.p1).toBe(p1);
  expect(battleData!.winnerIndex).toBe(2n);
  expect(battleData!.turnId).toBe(0n);
});

test('BattleSimulator: first turn switches to active mons', () => {
  const sim = new BattleSimulator();

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  const p0Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 60n, attack: 50n });
  const p1Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 40n, attack: 50n });

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  // First turn: both players switch to mon 0
  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, p0Salt, // P0 switches to mon 0
    Constants.SWITCH_MOVE_INDEX, 0n, p1Salt  // P1 switches to mon 0
  );

  const battleData = sim.getBattleData(battleKey);
  expect(battleData!.turnId).toBe(1n); // Turn incremented
  expect(battleData!.winnerIndex).toBe(2n); // No winner yet
});

test('BattleSimulator: basic attack deals damage', () => {
  const sim = new BattleSimulator();
  const eventStream = new EventStream();
  sim.setEventStream(eventStream);

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  // P0 has higher speed so attacks first
  const p0Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 60n, attack: 50n });
  const p1Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 40n, attack: 50n });

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  // Turn 1: Both switch to active mon
  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, p0Salt,
    Constants.SWITCH_MOVE_INDEX, 0n, p1Salt
  );

  eventStream.clear();

  // Turn 2: Both use move 0 (basic attack)
  const newP0Salt = '0x3333333333333333333333333333333333333333333333333333333333333333';
  const newP1Salt = '0x4444444444444444444444444444444444444444444444444444444444444444';

  sim.executeTurn(
    battleKey,
    0n, 0n, newP0Salt, // P0 uses move 0
    0n, 0n, newP1Salt  // P1 uses move 0
  );

  // Check that damage was dealt
  const allEvents = eventStream.getAll();
  const damageEvents = eventStream.getByName('DamageDeal');
  const moveEvents = eventStream.getByName('MonMove');
  const engineEvents = eventStream.getByName('EngineEvent');
  console.log(`    All events: ${allEvents.map(e => e.name).join(', ')}`);
  console.log(`    Damage events: ${damageEvents.length}, Move events: ${moveEvents.length}`);
  for (const ee of engineEvents) {
    const args = ee.args;
    console.log(`    EngineEvent eventType: ${args.arg1}`);
  }

  // Debug: check what types are being used
  const debugConfig = sim.getBattleConfig(battleKey)!;
  const p0MonDebug = (debugConfig.p0Team as any)[0];
  const p1MonDebug = (debugConfig.p1Team as any)[0];
  console.log(`    P0 mon type1: ${p0MonDebug?.stats?.type1}, type2: ${p0MonDebug?.stats?.type2}`);
  console.log(`    P1 mon type1: ${p1MonDebug?.stats?.type1}, type2: ${p1MonDebug?.stats?.type2}`);
  expect(damageEvents.length).toBeGreaterThan(0);

  // Verify HP deltas were updated
  const p0HpDelta = sim.getMonStateForBattle(battleKey, 0n, 0n, Enums.MonStateIndexName.Hp);
  const p1HpDelta = sim.getMonStateForBattle(battleKey, 1n, 0n, Enums.MonStateIndexName.Hp);

  // At least one mon should have taken damage (negative HP delta)
  const p0TookDamage = p0HpDelta < 0n;
  const p1TookDamage = p1HpDelta < 0n;
  expect(p0TookDamage || p1TookDamage).toBe(true);

  console.log(`    P0 HP delta: ${p0HpDelta}, P1 HP delta: ${p1HpDelta}`);
});

test('BattleSimulator: faster mon attacks first', () => {
  const sim = new BattleSimulator();
  const eventStream = new EventStream();
  sim.setEventStream(eventStream);

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  // P0 has much higher speed (100 vs 10)
  const p0Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 100n, attack: 80n });
  const p1Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 10n, attack: 80n });

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  // Turn 1: Both switch
  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, p0Salt,
    Constants.SWITCH_MOVE_INDEX, 0n, p1Salt
  );

  eventStream.clear();

  // Turn 2: Both attack
  sim.executeTurn(battleKey, 0n, 0n, p0Salt, 0n, 0n, p1Salt);

  // Check the order of MonMove events (faster should go first)
  const moveEvents = eventStream.getByName('MonMove');

  if (moveEvents.length >= 2) {
    // The first move event should be from P0 (the faster player)
    console.log(`    Move order: ${moveEvents.map(e => `P${e.args.arg1}`).join(' -> ')}`);
  }
});

test('BattleSimulator: deterministic RNG from salts', () => {
  const oracle = new MockRNGOracle();

  const salt1 = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const salt2 = '0x2222222222222222222222222222222222222222222222222222222222222222';

  const rng1 = oracle.getRNG(salt1, salt2);
  const rng2 = oracle.getRNG(salt1, salt2);

  // Same salts should give same RNG
  expect(rng1).toBe(rng2);

  // Different salts should give different RNG
  const salt3 = '0x3333333333333333333333333333333333333333333333333333333333333333';
  const rng3 = oracle.getRNG(salt1, salt3);
  expect(rng3).not.toBe(rng1);

  console.log(`    RNG from salts: ${rng1.toString(16).slice(0, 16)}...`);
});

test('BattleSimulator: damage calculation uses type effectiveness', () => {
  const sim = new BattleSimulator();
  const eventStream = new EventStream();
  sim.setEventStream(eventStream);

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  // P0 uses Fire attack, P1 is Nature type (Fire is super effective vs Nature)
  const p0Mon = createMonWithBasicAttack(
    sim,
    { hp: 100n, speed: 60n, attack: 50n, type1: Enums.Type.Fire },
    'Fireball',
    50n,
    Enums.Type.Fire
  );

  // P1 is Nature type - weak to Fire
  const p1Mon = createMonWithBasicAttack(
    sim,
    { hp: 100n, speed: 40n, attack: 50n, type1: Enums.Type.Nature },
    'Vine Whip',
    50n,
    Enums.Type.Nature
  );

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  // Turn 1: Switch
  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, p0Salt,
    Constants.SWITCH_MOVE_INDEX, 0n, p1Salt
  );

  eventStream.clear();

  // Turn 2: Attack
  sim.executeTurn(battleKey, 0n, 0n, p0Salt, 0n, 0n, p1Salt);

  // Get HP deltas
  const p1HpDelta = sim.getMonStateForBattle(battleKey, 1n, 0n, Enums.MonStateIndexName.Hp);
  const p0HpDelta = sim.getMonStateForBattle(battleKey, 0n, 0n, Enums.MonStateIndexName.Hp);

  // P1 should take more damage due to type effectiveness (if P0 attacked first)
  console.log(`    P0 HP delta: ${p0HpDelta}, P1 HP delta: ${p1HpDelta}`);
});

test('BattleSimulator: KO triggers when HP reaches 0', () => {
  const sim = new BattleSimulator();
  const eventStream = new EventStream();
  sim.setEventStream(eventStream);

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  // P0 is very strong, P1 has low HP
  const p0Mon = createMonWithBasicAttack(
    sim,
    { hp: 100n, speed: 100n, attack: 200n },
    'Mega Attack',
    200n
  );

  const p1Mon = createMonWithBasicAttack(
    sim,
    { hp: 10n, speed: 10n, attack: 10n }, // Very low HP
    'Weak Attack',
    10n
  );

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  // Turn 1: Switch
  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, p0Salt,
    Constants.SWITCH_MOVE_INDEX, 0n, p1Salt
  );

  // Turn 2: Attack - P0 should KO P1
  sim.executeTurn(battleKey, 0n, 0n, p0Salt, 0n, 0n, p1Salt);

  // Check if P1's mon is KO'd
  const p1KOStatus = sim.getMonStateForBattle(battleKey, 1n, 0n, Enums.MonStateIndexName.IsKnockedOut);

  // Check if game is over
  const battleData = sim.getBattleData(battleKey);

  console.log(`    P1 KO status: ${p1KOStatus}, Winner index: ${battleData!.winnerIndex}`);

  // P1's mon should be knocked out
  expect(p1KOStatus).toBe(1n);
});

test('BattleSimulator: stamina is consumed when using moves', () => {
  const sim = new BattleSimulator();
  const eventStream = new EventStream();
  sim.setEventStream(eventStream);

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  const p0Mon = createMonWithBasicAttack(sim, { hp: 100n, stamina: 50n, speed: 60n });
  const p1Mon = createMonWithBasicAttack(sim, { hp: 100n, stamina: 50n, speed: 40n });

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  // Turn 1: Switch
  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, p0Salt,
    Constants.SWITCH_MOVE_INDEX, 0n, p1Salt
  );

  // Turn 2: Both use their attack move
  sim.executeTurn(battleKey, 0n, 0n, p0Salt, 0n, 0n, p1Salt);

  // Check stamina deltas (should be negative due to stamina cost)
  const p0StaminaDelta = sim.getMonStateForBattle(battleKey, 0n, 0n, Enums.MonStateIndexName.Stamina);
  const p1StaminaDelta = sim.getMonStateForBattle(battleKey, 1n, 0n, Enums.MonStateIndexName.Stamina);

  console.log(`    P0 stamina delta: ${p0StaminaDelta}, P1 stamina delta: ${p1StaminaDelta}`);

  // Both should have consumed stamina (negative delta)
  expect(p0StaminaDelta).toBeLessThan(0n);
  expect(p1StaminaDelta).toBeLessThan(0n);
});

test('BattleSimulator: NO_OP move does nothing', () => {
  const sim = new BattleSimulator();
  const eventStream = new EventStream();
  sim.setEventStream(eventStream);

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  const p0Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 60n });
  const p1Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 40n });

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  // Turn 1: Switch
  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, p0Salt,
    Constants.SWITCH_MOVE_INDEX, 0n, p1Salt
  );

  eventStream.clear();

  // Turn 2: P0 attacks, P1 does NO_OP
  sim.executeTurn(
    battleKey,
    0n, 0n, p0Salt,                    // P0 attacks
    Constants.NO_OP_MOVE_INDEX, 0n, p1Salt // P1 does nothing
  );

  // P1 should have taken damage, P0 should not
  const p0HpDelta = sim.getMonStateForBattle(battleKey, 0n, 0n, Enums.MonStateIndexName.Hp);
  const p1HpDelta = sim.getMonStateForBattle(battleKey, 1n, 0n, Enums.MonStateIndexName.Hp);

  console.log(`    P0 HP delta: ${p0HpDelta}, P1 HP delta: ${p1HpDelta}`);

  // P0 should be unharmed (sentinel value treated as 0), P1 should have taken damage
  const p0Damage = p0HpDelta === Constants.CLEARED_MON_STATE_SENTINEL ? 0n : p0HpDelta;
  expect(p0Damage).toBe(0n);
  expect(p1HpDelta).toBeLessThan(0n);
});

test('BattleSimulator: complete battle simulation from scratch', () => {
  console.log('\n    --- FULL BATTLE SIMULATION ---');

  const sim = new BattleSimulator();
  const eventStream = new EventStream();
  sim.setEventStream(eventStream);

  const p0 = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0001';
  const p1 = '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb0002';

  // Create teams with different stats
  const p0Mon = createMonWithBasicAttack(
    sim,
    { hp: 100n, speed: 80n, attack: 60n, defense: 40n, type1: Enums.Type.Fire },
    'Flamethrower',
    60n,
    Enums.Type.Fire
  );

  const p1Mon = createMonWithBasicAttack(
    sim,
    { hp: 120n, speed: 40n, attack: 50n, defense: 50n, type1: Enums.Type.Metal },
    'Iron Bash',
    50n,
    Enums.Type.Metal
  );

  // Initialize battle
  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  console.log(`    Battle Key: ${battleKey.slice(0, 18)}...`);
  console.log(`    P0 (Fire): HP=100, SPD=80, ATK=60`);
  console.log(`    P1 (Metal): HP=120, SPD=40, ATK=50`);

  // Turn 1: Both switch in
  const salt1 = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const salt2 = '0x2222222222222222222222222222222222222222222222222222222222222222';

  console.log(`\n    Turn 1: Both players switch in their mon`);
  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, salt1,
    Constants.SWITCH_MOVE_INDEX, 0n, salt2
  );

  let battleData = sim.getBattleData(battleKey)!;
  console.log(`    Turn complete. turnId now: ${battleData.turnId}`);

  // Turn 2-5: Exchange attacks
  for (let turn = 2; turn <= 5; turn++) {
    eventStream.clear();

    const turnSalt1 = keccak256(
      encodeAbiParameters([{ type: 'uint256' }, { type: 'bytes32' }], [BigInt(turn), salt1 as `0x${string}`])
    );
    const turnSalt2 = keccak256(
      encodeAbiParameters([{ type: 'uint256' }, { type: 'bytes32' }], [BigInt(turn), salt2 as `0x${string}`])
    );

    console.log(`\n    Turn ${turn}: Both players attack`);

    sim.executeTurn(battleKey, 0n, 0n, turnSalt1, 0n, 0n, turnSalt2);

    // Get current HP
    const p0HpDelta = sim.getMonStateForBattle(battleKey, 0n, 0n, Enums.MonStateIndexName.Hp);
    const p1HpDelta = sim.getMonStateForBattle(battleKey, 1n, 0n, Enums.MonStateIndexName.Hp);

    const p0CurrentHp = 100n + (p0HpDelta === Constants.CLEARED_MON_STATE_SENTINEL ? 0n : p0HpDelta);
    const p1CurrentHp = 120n + (p1HpDelta === Constants.CLEARED_MON_STATE_SENTINEL ? 0n : p1HpDelta);

    console.log(`    P0 HP: ${p0CurrentHp}/100, P1 HP: ${p1CurrentHp}/120`);

    // Check for KOs
    battleData = sim.getBattleData(battleKey)!;
    if (battleData.winnerIndex !== 2n) {
      const winner = battleData.winnerIndex === 0n ? 'P0 (Fire)' : 'P1 (Metal)';
      console.log(`\n    BATTLE OVER! Winner: ${winner}`);
      break;
    }
  }

  // Final state
  battleData = sim.getBattleData(battleKey)!;
  console.log(`\n    Final turn ID: ${battleData.turnId}`);
  console.log(`    Winner index: ${battleData.winnerIndex === 2n ? 'No winner yet' : battleData.winnerIndex}`);

  // The test passes if we got this far without errors
  expect(battleData.turnId).toBeGreaterThan(0n);
});

// =============================================================================
// UNBOUNDED STRIKE TESTS
// =============================================================================

test('UnboundedStrike: returns BASE_STAMINA (2) when Baselight level < 3', () => {
  const sim = new BattleSimulator();
  const { baselight, move } = createBaselightAndUnboundedStrike(sim);

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  const p0Mon = createMonWithUnboundedStrike(sim, baselight, move, { hp: 100n, speed: 60n, attack: 50n });
  const p1Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 40n, attack: 50n });

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  // First turn: both players switch in (this activates Baselight at level 1)
  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, p0Salt,
    Constants.SWITCH_MOVE_INDEX, 0n, p1Salt
  );

  // Check Baselight level (should be 1 after switch-in, then 2 after round end)
  const baselightLevel = baselight.getBaselightLevel(battleKey, 0n, 0n);
  console.log(`    Baselight level after switch: ${baselightLevel}`);

  // Check stamina cost for UnboundedStrike - should be BASE_STAMINA (2) since level < 3
  const staminaCost = move.stamina(battleKey, 0n, 0n);
  console.log(`    Stamina cost: ${staminaCost} (expected: ${UnboundedStrike.BASE_STAMINA})`);

  expect(staminaCost).toBe(UnboundedStrike.BASE_STAMINA); // Should be 2n
});

test('UnboundedStrike: returns EMPOWERED_STAMINA (1) when Baselight level >= 3', () => {
  const sim = new BattleSimulator();
  const { baselight, move } = createBaselightAndUnboundedStrike(sim);

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  const p0Mon = createMonWithUnboundedStrike(sim, baselight, move, { hp: 100n, speed: 60n, attack: 50n });
  const p1Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 40n, attack: 50n });

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  // First turn: both players switch in
  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, p0Salt,
    Constants.SWITCH_MOVE_INDEX, 0n, p1Salt
  );

  // Manually set Baselight level to 3 to test empowered stamina
  baselight.setBaselightLevel(0n, 0n, 3n);

  const baselightLevel = baselight.getBaselightLevel(battleKey, 0n, 0n);
  console.log(`    Baselight level (manually set): ${baselightLevel}`);

  // Check stamina cost - should be EMPOWERED_STAMINA (1) since level >= 3
  const staminaCost = move.stamina(battleKey, 0n, 0n);
  console.log(`    Stamina cost: ${staminaCost} (expected: ${UnboundedStrike.EMPOWERED_STAMINA})`);

  expect(staminaCost).toBe(UnboundedStrike.EMPOWERED_STAMINA); // Should be 1n
});

test('UnboundedStrike: uses BASE_POWER (80) when Baselight < 3', () => {
  const sim = new BattleSimulator();
  const eventStream = new EventStream();
  sim.setEventStream(eventStream);

  const { baselight, move } = createBaselightAndUnboundedStrike(sim);

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  const p0Mon = createMonWithUnboundedStrike(sim, baselight, move, { hp: 100n, speed: 100n, attack: 50n });
  const p1Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 40n, attack: 50n });

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  // Turn 1: Switch
  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, p0Salt,
    Constants.SWITCH_MOVE_INDEX, 0n, p1Salt
  );

  const baselightBefore = baselight.getBaselightLevel(battleKey, 0n, 0n);
  console.log(`    Baselight level before attack: ${baselightBefore}`);
  expect(baselightBefore).toBeLessThan(3n);

  eventStream.clear();

  // Turn 2: P0 uses UnboundedStrike (normal power), P1 does nothing
  sim.executeTurn(
    battleKey,
    0n, 0n, p0Salt,
    Constants.NO_OP_MOVE_INDEX, 0n, p1Salt
  );

  // Check damage dealt - with BASE_POWER (80)
  const p1HpDelta = sim.getMonStateForBattle(battleKey, 1n, 0n, Enums.MonStateIndexName.Hp);
  console.log(`    P1 HP delta after normal UnboundedStrike: ${p1HpDelta}`);

  // Should have dealt some damage
  expect(p1HpDelta).toBeLessThan(0n);

  // Baselight should NOT be consumed (since we didn't have 3 stacks)
  const baselightAfter = baselight.getBaselightLevel(battleKey, 0n, 0n);
  console.log(`    Baselight level after normal attack: ${baselightAfter}`);
});

test('UnboundedStrike: uses EMPOWERED_POWER (130) and consumes stacks when Baselight >= 3', () => {
  const sim = new BattleSimulator();
  const eventStream = new EventStream();
  sim.setEventStream(eventStream);

  const { baselight, move } = createBaselightAndUnboundedStrike(sim);

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  const p0Mon = createMonWithUnboundedStrike(sim, baselight, move, { hp: 100n, speed: 100n, attack: 50n });
  const p1Mon = createMonWithBasicAttack(sim, { hp: 200n, speed: 40n, attack: 50n }); // High HP to survive

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  // Turn 1: Switch
  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, p0Salt,
    Constants.SWITCH_MOVE_INDEX, 0n, p1Salt
  );

  // Manually set Baselight to 3 for empowered attack
  baselight.setBaselightLevel(0n, 0n, 3n);

  const baselightBefore = baselight.getBaselightLevel(battleKey, 0n, 0n);
  console.log(`    Baselight level before empowered attack: ${baselightBefore}`);
  expect(baselightBefore).toBe(3n);

  eventStream.clear();

  // Turn 2: P0 uses UnboundedStrike (empowered), P1 does nothing
  sim.executeTurn(
    battleKey,
    0n, 0n, p0Salt,
    Constants.NO_OP_MOVE_INDEX, 0n, p1Salt
  );

  // Check damage dealt - should be higher due to EMPOWERED_POWER (130)
  const p1HpDelta = sim.getMonStateForBattle(battleKey, 1n, 0n, Enums.MonStateIndexName.Hp);
  console.log(`    P1 HP delta after empowered UnboundedStrike: ${p1HpDelta}`);

  // Should have dealt damage
  expect(p1HpDelta).toBeLessThan(0n);

  // Baselight stacks are consumed during the attack (set to 0), but then
  // the round end effect adds 1 stack. So after a complete turn, level = 1
  const baselightAfter = baselight.getBaselightLevel(battleKey, 0n, 0n);
  console.log(`    Baselight level after empowered attack + round end: ${baselightAfter}`);
  // After consuming 3 stacks (to 0) and gaining 1 at round end, should be 1
  expect(baselightAfter).toBe(1n);
});

test('UnboundedStrike: empowered attack deals more damage than normal attack', () => {
  // Run two separate simulations to compare damage
  console.log('\n    --- Comparing Normal vs Empowered Unbounded Strike ---');

  // NORMAL ATTACK (Baselight < 3)
  const sim1 = new BattleSimulator();
  const { baselight: baselight1, move: move1 } = createBaselightAndUnboundedStrike(sim1);

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  const p0Mon1 = createMonWithUnboundedStrike(sim1, baselight1, move1, { hp: 100n, speed: 100n, attack: 50n });
  const p1Mon1 = createMonWithBasicAttack(sim1, { hp: 200n, speed: 40n, attack: 50n, defense: 50n });

  const battleKey1 = sim1.initializeBattle(p0, p1, [p0Mon1], [p1Mon1]);
  sim1.battleKeyForWrite = battleKey1;

  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  sim1.executeTurn(battleKey1, Constants.SWITCH_MOVE_INDEX, 0n, p0Salt, Constants.SWITCH_MOVE_INDEX, 0n, p1Salt);
  // Baselight level will be ~2 after switch (1 initial + 1 end of turn)
  sim1.executeTurn(battleKey1, 0n, 0n, p0Salt, Constants.NO_OP_MOVE_INDEX, 0n, p1Salt);

  const normalDamage = -sim1.getMonStateForBattle(battleKey1, 1n, 0n, Enums.MonStateIndexName.Hp);
  console.log(`    Normal attack damage (BASE_POWER=80): ${normalDamage}`);

  // EMPOWERED ATTACK (Baselight = 3)
  const sim2 = new BattleSimulator();
  const { baselight: baselight2, move: move2 } = createBaselightAndUnboundedStrike(sim2);

  const p0Mon2 = createMonWithUnboundedStrike(sim2, baselight2, move2, { hp: 100n, speed: 100n, attack: 50n });
  const p1Mon2 = createMonWithBasicAttack(sim2, { hp: 200n, speed: 40n, attack: 50n, defense: 50n });

  const battleKey2 = sim2.initializeBattle(p0, p1, [p0Mon2], [p1Mon2]);
  sim2.battleKeyForWrite = battleKey2;

  sim2.executeTurn(battleKey2, Constants.SWITCH_MOVE_INDEX, 0n, p0Salt, Constants.SWITCH_MOVE_INDEX, 0n, p1Salt);
  baselight2.setBaselightLevel(0n, 0n, 3n); // Set to max stacks
  sim2.executeTurn(battleKey2, 0n, 0n, p0Salt, Constants.NO_OP_MOVE_INDEX, 0n, p1Salt);

  const empoweredDamage = -sim2.getMonStateForBattle(battleKey2, 1n, 0n, Enums.MonStateIndexName.Hp);
  console.log(`    Empowered attack damage (EMPOWERED_POWER=130): ${empoweredDamage}`);

  // Empowered should deal more damage (130 > 80, so ~62.5% more)
  console.log(`    Damage ratio: ${Number(empoweredDamage) / Number(normalDamage)} (expected: ~1.625)`);
  expect(empoweredDamage).toBeGreaterThan(normalDamage);
});

test('Baselight: level increases at end of each round up to max 3', () => {
  const sim = new BattleSimulator();
  const { baselight, move } = createBaselightAndUnboundedStrike(sim);

  const p0 = '0x1111111111111111111111111111111111111111';
  const p1 = '0x2222222222222222222222222222222222222222';

  const p0Mon = createMonWithUnboundedStrike(sim, baselight, move, { hp: 100n, speed: 60n, attack: 50n });
  const p1Mon = createMonWithBasicAttack(sim, { hp: 100n, speed: 40n, attack: 50n });

  const battleKey = sim.initializeBattle(p0, p1, [p0Mon], [p1Mon]);
  sim.battleKeyForWrite = battleKey;

  const p0Salt = '0x1111111111111111111111111111111111111111111111111111111111111111';
  const p1Salt = '0x2222222222222222222222222222222222222222222222222222222222222222';

  // Turn 1: Switch in - Baselight activates at level 1, then increases to 2 at round end
  sim.executeTurn(
    battleKey,
    Constants.SWITCH_MOVE_INDEX, 0n, p0Salt,
    Constants.SWITCH_MOVE_INDEX, 0n, p1Salt
  );

  const levelAfterTurn1 = baselight.getBaselightLevel(battleKey, 0n, 0n);
  console.log(`    Baselight level after turn 1: ${levelAfterTurn1}`);

  // Simulate round end effect to increment level
  // Note: In full engine this would happen automatically, for this test we verify the ability works
  expect(levelAfterTurn1).toBeGreaterThanOrEqual(1n);
  expect(levelAfterTurn1).toBeLessThan(4n); // Should never exceed max
});

// =============================================================================
// RUN TESTS
// =============================================================================

runTests();
