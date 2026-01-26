/**
 * Simple test runner without vitest
 * Run with: npx tsx test/run.ts
 */

import { test, expect, runTests } from './test-utils';

// =============================================================================
// IMPORTS
// =============================================================================

import { keccak256, encodePacked } from 'viem';
import { Contract, Storage, ADDRESS_ZERO } from '../runtime/index';

// =============================================================================
// SIMPLE MON TYPES (minimal for scaffold test)
// =============================================================================

interface MonStats {
  hp: bigint;
  stamina: bigint;
  speed: bigint;
  attack: bigint;
  defense: bigint;
  specialAttack: bigint;
  specialDefense: bigint;
}

interface MonState {
  hpDelta: bigint;
  isKnockedOut: boolean;
}

// =============================================================================
// MINIMAL ENGINE FOR SCAFFOLD TEST
// =============================================================================

class ScaffoldEngine extends Contract {
  // Battle state
  private battles: Map<string, {
    p0: string;
    p1: string;
    p0Mon: MonStats;
    p1Mon: MonStats;
    p0State: MonState;
    p1State: MonState;
    turnId: bigint;
    winner: number; // -1 = ongoing, 0 = p0 wins, 1 = p1 wins
  }> = new Map();

  private pairHashNonces: Map<string, bigint> = new Map();

  /**
   * Start a battle between two players
   */
  startBattle(p0: string, p1: string, p0Mon: MonStats, p1Mon: MonStats): string {
    const battleKey = this._computeBattleKey(p0, p1);

    this.battles.set(battleKey, {
      p0, p1,
      p0Mon, p1Mon,
      p0State: { hpDelta: 0n, isKnockedOut: false },
      p1State: { hpDelta: 0n, isKnockedOut: false },
      turnId: 0n,
      winner: -1,
    });

    return battleKey;
  }

  /**
   * Execute a turn - faster mon attacks first
   * Returns: [p0Damage, p1Damage, winnerId]
   */
  executeTurn(battleKey: string, p0Attack: bigint, p1Attack: bigint): [bigint, bigint, number] {
    const battle = this.battles.get(battleKey);
    if (!battle) throw new Error('Battle not found');
    if (battle.winner !== -1) throw new Error('Battle already ended');

    battle.turnId++;

    // Determine turn order by speed
    const p0Speed = battle.p0Mon.speed;
    const p1Speed = battle.p1Mon.speed;
    const p0First = p0Speed >= p1Speed;

    let p0Damage = 0n;
    let p1Damage = 0n;

    if (p0First) {
      // P0 attacks first
      p1Damage = this._calculateDamage(p0Attack, battle.p0Mon.attack, battle.p1Mon.defense);
      battle.p1State.hpDelta -= p1Damage;

      // Check if P1 is KO'd
      if (battle.p1Mon.hp + battle.p1State.hpDelta <= 0n) {
        battle.p1State.isKnockedOut = true;
        battle.winner = 0;
        return [p0Damage, p1Damage, 0];
      }

      // P1 attacks back
      p0Damage = this._calculateDamage(p1Attack, battle.p1Mon.attack, battle.p0Mon.defense);
      battle.p0State.hpDelta -= p0Damage;

      if (battle.p0Mon.hp + battle.p0State.hpDelta <= 0n) {
        battle.p0State.isKnockedOut = true;
        battle.winner = 1;
        return [p0Damage, p1Damage, 1];
      }
    } else {
      // P1 attacks first
      p0Damage = this._calculateDamage(p1Attack, battle.p1Mon.attack, battle.p0Mon.defense);
      battle.p0State.hpDelta -= p0Damage;

      if (battle.p0Mon.hp + battle.p0State.hpDelta <= 0n) {
        battle.p0State.isKnockedOut = true;
        battle.winner = 1;
        return [p0Damage, p1Damage, 1];
      }

      // P0 attacks back
      p1Damage = this._calculateDamage(p0Attack, battle.p0Mon.attack, battle.p1Mon.defense);
      battle.p1State.hpDelta -= p1Damage;

      if (battle.p1Mon.hp + battle.p1State.hpDelta <= 0n) {
        battle.p1State.isKnockedOut = true;
        battle.winner = 0;
        return [p0Damage, p1Damage, 0];
      }
    }

    return [p0Damage, p1Damage, -1]; // Battle continues
  }

  /**
   * Get battle state
   */
  getBattleState(battleKey: string) {
    return this.battles.get(battleKey);
  }

  /**
   * Simple damage calculation: basePower * attack / defense
   */
  private _calculateDamage(basePower: bigint, attack: bigint, defense: bigint): bigint {
    if (defense <= 0n) defense = 1n;
    return (basePower * attack) / defense;
  }

  private _computeBattleKey(p0: string, p1: string): string {
    const [addr0, addr1] = p0.toLowerCase() < p1.toLowerCase() ? [p0, p1] : [p1, p0];
    const pairHash = keccak256(encodePacked(
      ['address', 'address'],
      [addr0 as `0x${string}`, addr1 as `0x${string}`]
    ));

    const nonce = (this.pairHashNonces.get(pairHash) ?? 0n) + 1n;
    this.pairHashNonces.set(pairHash, nonce);

    return keccak256(encodePacked(
      ['bytes32', 'uint256'],
      [pairHash as `0x${string}`, nonce]
    ));
  }
}

// =============================================================================
// TESTS
// =============================================================================

const ALICE = '0x0000000000000000000000000000000000000001';
const BOB = '0x0000000000000000000000000000000000000002';

// Test: Faster mon should attack first and win if it can KO
test('faster mon attacks first and KOs opponent', () => {
  const engine = new ScaffoldEngine();

  // Create two mons: Alice's is faster and stronger
  const aliceMon: MonStats = {
    hp: 100n,
    stamina: 10n,
    speed: 100n,  // Faster
    attack: 50n,
    defense: 20n,
    specialAttack: 30n,
    specialDefense: 20n,
  };

  const bobMon: MonStats = {
    hp: 50n,     // Lower HP
    stamina: 10n,
    speed: 50n,   // Slower
    attack: 30n,
    defense: 10n,
    specialAttack: 20n,
    specialDefense: 15n,
  };

  const battleKey = engine.startBattle(ALICE, BOB, aliceMon, bobMon);

  // Alice attacks with base power 100
  // Damage = 100 * 50 / 10 = 500 (way more than Bob's 50 HP)
  const [p0Damage, p1Damage, winner] = engine.executeTurn(battleKey, 100n, 100n);

  expect(winner).toBe(0); // Alice wins
  expect(p1Damage).toBeGreaterThan(0); // Bob took damage

  const state = engine.getBattleState(battleKey);
  expect(state?.p1State.isKnockedOut).toBe(true);
});

// Test: Slower mon loses if both can OHKO
test('slower mon loses when both can one-shot', () => {
  const engine = new ScaffoldEngine();

  // Both mons can one-shot each other, but Alice is faster
  const aliceMon: MonStats = {
    hp: 10n,
    stamina: 10n,
    speed: 100n,  // Faster
    attack: 100n,
    defense: 10n,
    specialAttack: 30n,
    specialDefense: 20n,
  };

  const bobMon: MonStats = {
    hp: 10n,
    stamina: 10n,
    speed: 50n,   // Slower
    attack: 100n,
    defense: 10n,
    specialAttack: 20n,
    specialDefense: 15n,
  };

  const battleKey = engine.startBattle(ALICE, BOB, aliceMon, bobMon);
  const [_, __, winner] = engine.executeTurn(battleKey, 50n, 50n);

  expect(winner).toBe(0); // Alice wins (attacked first)
});

// Test: Multi-turn battle
test('multi-turn battle until KO', () => {
  const engine = new ScaffoldEngine();

  // Balanced mons - neither can one-shot
  const aliceMon: MonStats = {
    hp: 100n,
    stamina: 10n,
    speed: 60n,
    attack: 30n,
    defense: 20n,
    specialAttack: 30n,
    specialDefense: 20n,
  };

  const bobMon: MonStats = {
    hp: 100n,
    stamina: 10n,
    speed: 50n,
    attack: 25n,
    defense: 20n,
    specialAttack: 20n,
    specialDefense: 15n,
  };

  const battleKey = engine.startBattle(ALICE, BOB, aliceMon, bobMon);

  let turns = 0;
  let winner = -1;

  while (winner === -1 && turns < 20) {
    const result = engine.executeTurn(battleKey, 50n, 50n);
    winner = result[2];
    turns++;
  }

  expect(turns).toBeGreaterThan(1); // Should take multiple turns
  expect(winner).not.toBe(-1); // Someone should win
});

// Test: Battle key computation
test('battle keys are deterministic', () => {
  const engine1 = new ScaffoldEngine();
  const engine2 = new ScaffoldEngine();

  const key1 = engine1.startBattle(ALICE, BOB, {} as MonStats, {} as MonStats);
  const key2 = engine2.startBattle(ALICE, BOB, {} as MonStats, {} as MonStats);

  // Same players should produce same key (with same nonce)
  expect(key1).toBe(key2);
});

// Test: Storage operations work
test('storage read/write works', () => {
  const engine = new ScaffoldEngine();

  // Access protected methods via type assertion
  (engine as any)._storageWrite('test', 42n);
  const value = (engine as any)._storageRead('test');

  expect(value).toBe(42n);
});

// Run all tests
runTests();
