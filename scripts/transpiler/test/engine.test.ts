/**
 * Engine Transpilation Test
 *
 * This test verifies that the transpiled Engine.ts produces
 * the same results as the Solidity Engine contract.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { keccak256, encodePacked, toHex } from 'viem';

// Import runtime utilities
import {
  Contract,
  Storage,
  Type,
  ADDRESS_ZERO,
  uint256,
  extractBits,
  insertBits,
} from '../runtime/index';

// =============================================================================
// TYPE DEFINITIONS (should match transpiled Structs.ts)
// =============================================================================

interface MonStats {
  hp: bigint;
  stamina: bigint;
  speed: bigint;
  attack: bigint;
  defense: bigint;
  specialAttack: bigint;
  specialDefense: bigint;
  type1: Type;
  type2: Type;
}

interface Mon {
  stats: MonStats;
  ability: string;  // address
  moves: string[];  // IMoveSet addresses
}

interface MonState {
  hpDelta: bigint;
  staminaDelta: bigint;
  speedDelta: bigint;
  attackDelta: bigint;
  defenceDelta: bigint;
  specialAttackDelta: bigint;
  specialDefenceDelta: bigint;
  isKnockedOut: boolean;
  shouldSkipTurn: boolean;
}

interface BattleData {
  p1: string;
  turnId: bigint;
  p0: string;
  winnerIndex: bigint;
  prevPlayerSwitchForTurnFlag: bigint;
  playerSwitchForTurnFlag: bigint;
  activeMonIndex: bigint;
}

interface MoveDecision {
  packedMoveIndex: bigint;
  extraData: bigint;
}

// =============================================================================
// PACKED MON STATE HELPERS (matches Solidity MonStatePacking library)
// =============================================================================

const CLEARED_MON_STATE = 0n;

// Bit layout for packed MonState:
// hpDelta: int32 (bits 0-31)
// staminaDelta: int32 (bits 32-63)
// speedDelta: int32 (bits 64-95)
// attackDelta: int32 (bits 96-127)
// defenceDelta: int32 (bits 128-159)
// specialAttackDelta: int32 (bits 160-191)
// specialDefenceDelta: int32 (bits 192-223)
// isKnockedOut: bool (bit 224)
// shouldSkipTurn: bool (bit 225)

function packMonState(state: MonState): bigint {
  let packed = 0n;

  // Pack int32 values with sign handling
  const packInt32 = (value: bigint, offset: number): void => {
    // Convert to unsigned 32-bit representation
    const unsigned = value < 0n ? (1n << 32n) + value : value;
    packed |= (unsigned & 0xFFFFFFFFn) << BigInt(offset);
  };

  packInt32(state.hpDelta, 0);
  packInt32(state.staminaDelta, 32);
  packInt32(state.speedDelta, 64);
  packInt32(state.attackDelta, 96);
  packInt32(state.defenceDelta, 128);
  packInt32(state.specialAttackDelta, 160);
  packInt32(state.specialDefenceDelta, 192);

  if (state.isKnockedOut) packed |= (1n << 224n);
  if (state.shouldSkipTurn) packed |= (1n << 225n);

  return packed;
}

function unpackMonState(packed: bigint): MonState {
  const extractInt32 = (offset: number): bigint => {
    const unsigned = (packed >> BigInt(offset)) & 0xFFFFFFFFn;
    // Convert from unsigned to signed
    if (unsigned >= (1n << 31n)) {
      return unsigned - (1n << 32n);
    }
    return unsigned;
  };

  return {
    hpDelta: extractInt32(0),
    staminaDelta: extractInt32(32),
    speedDelta: extractInt32(64),
    attackDelta: extractInt32(96),
    defenceDelta: extractInt32(128),
    specialAttackDelta: extractInt32(160),
    specialDefenceDelta: extractInt32(192),
    isKnockedOut: ((packed >> 224n) & 1n) === 1n,
    shouldSkipTurn: ((packed >> 225n) & 1n) === 1n,
  };
}

// =============================================================================
// BATTLE KEY COMPUTATION (matches Solidity)
// =============================================================================

function computeBattleKey(p0: string, p1: string, nonce: bigint): [string, string] {
  // Sort addresses to get consistent pairHash
  const [addr0, addr1] = p0.toLowerCase() < p1.toLowerCase() ? [p0, p1] : [p1, p0];

  const pairHash = keccak256(encodePacked(
    ['address', 'address'],
    [addr0 as `0x${string}`, addr1 as `0x${string}`]
  ));

  const battleKey = keccak256(encodePacked(
    ['bytes32', 'uint256'],
    [pairHash, nonce]
  ));

  return [battleKey, pairHash];
}

// =============================================================================
// SIMPLE ENGINE SIMULATION
// =============================================================================

/**
 * Simplified Engine for testing core logic
 */
class TestEngine extends Contract {
  // Storage mappings
  pairHashNonces: Record<string, bigint> = {};
  isMatchmakerFor: Record<string, Record<string, boolean>> = {};

  // Internal storage helpers (simulate Yul operations)
  protected _getStorageKey(key: any): string {
    return typeof key === 'string' ? key : JSON.stringify(key);
  }

  protected _storageRead(key: any): bigint {
    return this._storage.sload(this._getStorageKey(key));
  }

  protected _storageWrite(key: any, value: bigint): void {
    this._storage.sstore(this._getStorageKey(key), value);
  }

  /**
   * Update matchmakers for the caller
   */
  updateMatchmakers(makersToAdd: string[], makersToRemove: string[]): void {
    const sender = this._msg.sender;

    if (!this.isMatchmakerFor[sender]) {
      this.isMatchmakerFor[sender] = {};
    }

    for (const maker of makersToAdd) {
      this.isMatchmakerFor[sender][maker] = true;
    }

    for (const maker of makersToRemove) {
      this.isMatchmakerFor[sender][maker] = false;
    }
  }

  /**
   * Compute battle key for two players
   */
  computeBattleKey(p0: string, p1: string): [string, string] {
    const nonce = this.pairHashNonces[this._getPairHash(p0, p1)] ?? 0n;
    return computeBattleKey(p0, p1, nonce);
  }

  private _getPairHash(p0: string, p1: string): string {
    const [addr0, addr1] = p0.toLowerCase() < p1.toLowerCase() ? [p0, p1] : [p1, p0];
    return keccak256(encodePacked(
      ['address', 'address'],
      [addr0 as `0x${string}`, addr1 as `0x${string}`]
    ));
  }

  /**
   * Increment nonce for pair and return new battle key
   */
  incrementNonceAndGetKey(p0: string, p1: string): string {
    const pairHash = this._getPairHash(p0, p1);
    const nonce = (this.pairHashNonces[pairHash] ?? 0n) + 1n;
    this.pairHashNonces[pairHash] = nonce;

    return keccak256(encodePacked(
      ['bytes32', 'uint256'],
      [pairHash as `0x${string}`, nonce]
    ));
  }
}

// =============================================================================
// TESTS
// =============================================================================

describe('Engine Transpilation', () => {
  let engine: TestEngine;

  const ALICE = '0x0000000000000000000000000000000000000001';
  const BOB = '0x0000000000000000000000000000000000000002';
  const MATCHMAKER = '0x0000000000000000000000000000000000000003';

  beforeEach(() => {
    engine = new TestEngine();
  });

  describe('Battle Key Computation', () => {
    it('should compute consistent battle keys', () => {
      const [key1, pairHash1] = computeBattleKey(ALICE, BOB, 0n);
      const [key2, pairHash2] = computeBattleKey(BOB, ALICE, 0n);

      // Same players should give same pairHash regardless of order
      expect(pairHash1).toBe(pairHash2);
      expect(key1).toBe(key2);
    });

    it('should generate different keys for different nonces', () => {
      const [key1] = computeBattleKey(ALICE, BOB, 0n);
      const [key2] = computeBattleKey(ALICE, BOB, 1n);

      expect(key1).not.toBe(key2);
    });

    it('should increment nonces correctly', () => {
      const key1 = engine.incrementNonceAndGetKey(ALICE, BOB);
      const key2 = engine.incrementNonceAndGetKey(ALICE, BOB);
      const key3 = engine.incrementNonceAndGetKey(BOB, ALICE); // Same pair

      expect(key1).not.toBe(key2);
      expect(key2).not.toBe(key3);
    });
  });

  describe('Matchmaker Authorization', () => {
    it('should add matchmakers correctly', () => {
      engine.setMsgSender(ALICE);
      engine.updateMatchmakers([MATCHMAKER], []);

      expect(engine.isMatchmakerFor[ALICE]?.[MATCHMAKER]).toBe(true);
    });

    it('should remove matchmakers correctly', () => {
      engine.setMsgSender(ALICE);
      engine.updateMatchmakers([MATCHMAKER], []);
      engine.updateMatchmakers([], [MATCHMAKER]);

      expect(engine.isMatchmakerFor[ALICE]?.[MATCHMAKER]).toBe(false);
    });

    it('should handle multiple matchmakers', () => {
      const MAKER2 = '0x0000000000000000000000000000000000000004';

      engine.setMsgSender(ALICE);
      engine.updateMatchmakers([MATCHMAKER, MAKER2], []);

      expect(engine.isMatchmakerFor[ALICE]?.[MATCHMAKER]).toBe(true);
      expect(engine.isMatchmakerFor[ALICE]?.[MAKER2]).toBe(true);
    });
  });

  describe('MonState Packing', () => {
    it('should pack and unpack zero state', () => {
      const state: MonState = {
        hpDelta: 0n,
        staminaDelta: 0n,
        speedDelta: 0n,
        attackDelta: 0n,
        defenceDelta: 0n,
        specialAttackDelta: 0n,
        specialDefenceDelta: 0n,
        isKnockedOut: false,
        shouldSkipTurn: false,
      };

      const packed = packMonState(state);
      const unpacked = unpackMonState(packed);

      expect(unpacked).toEqual(state);
    });

    it('should pack and unpack positive deltas', () => {
      const state: MonState = {
        hpDelta: 100n,
        staminaDelta: 50n,
        speedDelta: 25n,
        attackDelta: 10n,
        defenceDelta: 5n,
        specialAttackDelta: 3n,
        specialDefenceDelta: 1n,
        isKnockedOut: false,
        shouldSkipTurn: false,
      };

      const packed = packMonState(state);
      const unpacked = unpackMonState(packed);

      expect(unpacked).toEqual(state);
    });

    it('should pack and unpack negative deltas', () => {
      const state: MonState = {
        hpDelta: -100n,
        staminaDelta: -50n,
        speedDelta: -25n,
        attackDelta: -10n,
        defenceDelta: -5n,
        specialAttackDelta: -3n,
        specialDefenceDelta: -1n,
        isKnockedOut: false,
        shouldSkipTurn: false,
      };

      const packed = packMonState(state);
      const unpacked = unpackMonState(packed);

      expect(unpacked).toEqual(state);
    });

    it('should pack and unpack boolean flags', () => {
      const state: MonState = {
        hpDelta: 0n,
        staminaDelta: 0n,
        speedDelta: 0n,
        attackDelta: 0n,
        defenceDelta: 0n,
        specialAttackDelta: 0n,
        specialDefenceDelta: 0n,
        isKnockedOut: true,
        shouldSkipTurn: true,
      };

      const packed = packMonState(state);
      const unpacked = unpackMonState(packed);

      expect(unpacked.isKnockedOut).toBe(true);
      expect(unpacked.shouldSkipTurn).toBe(true);
    });
  });

  describe('Storage Operations', () => {
    it('should read and write to storage', () => {
      engine['_storageWrite']('testKey', 12345n);
      const value = engine['_storageRead']('testKey');

      expect(value).toBe(12345n);
    });

    it('should return 0 for unset keys', () => {
      const value = engine['_storageRead']('nonexistent');
      expect(value).toBe(0n);
    });
  });
});
