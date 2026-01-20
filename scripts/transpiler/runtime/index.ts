/**
 * Solidity to TypeScript Runtime Library
 *
 * This library provides the runtime support for transpiled Solidity code,
 * including storage simulation, bit manipulation, and type utilities.
 */

import { keccak256, encodePacked, encodeAbiParameters, parseAbiParameters, toHex, fromHex, hexToBigInt, numberToHex } from 'viem';
import { createHash } from 'crypto';

// =============================================================================
// HASH FUNCTIONS
// =============================================================================

/**
 * SHA-256 hash function (returns hex string with 0x prefix)
 */
export function sha256(data: `0x${string}` | string): `0x${string}` {
  // Remove 0x prefix if present for input
  const input = data.startsWith('0x') ? data.slice(2) : data;
  const buffer = Buffer.from(input, 'hex');
  const hash = createHash('sha256').update(buffer).digest('hex');
  return `0x${hash}` as `0x${string}`;
}

/**
 * SHA-256 hash of a string value (encodes string first)
 */
export function sha256String(str: string): `0x${string}` {
  // Encode the string as Solidity would with abi.encode
  const encoded = encodeAbiParameters([{ type: 'string' }], [str]);
  return sha256(encoded);
}

// =============================================================================
// BIGINT HELPERS
// =============================================================================

/**
 * Mask a BigInt to fit within a specific bit width
 */
export function mask(value: bigint, bits: number): bigint {
  const m = (1n << BigInt(bits)) - 1n;
  return value & m;
}

/**
 * Convert signed to unsigned (for int -> uint conversions)
 */
export function toUnsigned(value: bigint, bits: number): bigint {
  if (value < 0n) {
    return (1n << BigInt(bits)) + value;
  }
  return mask(value, bits);
}

/**
 * Convert unsigned to signed (for uint -> int conversions)
 */
export function toSigned(value: bigint, bits: number): bigint {
  const halfRange = 1n << BigInt(bits - 1);
  if (value >= halfRange) {
    return value - (1n << BigInt(bits));
  }
  return value;
}

/**
 * Safe integer type casts
 */
export const uint8 = (v: bigint | number): bigint => mask(BigInt(v), 8);
export const uint16 = (v: bigint | number): bigint => mask(BigInt(v), 16);
export const uint32 = (v: bigint | number): bigint => mask(BigInt(v), 32);
export const uint64 = (v: bigint | number): bigint => mask(BigInt(v), 64);
export const uint96 = (v: bigint | number): bigint => mask(BigInt(v), 96);
export const uint128 = (v: bigint | number): bigint => mask(BigInt(v), 128);
export const uint160 = (v: bigint | number): bigint => mask(BigInt(v), 160);
export const uint240 = (v: bigint | number): bigint => mask(BigInt(v), 240);
export const uint256 = (v: bigint | number): bigint => mask(BigInt(v), 256);

export const int8 = (v: bigint | number): bigint => toSigned(mask(BigInt(v), 8), 8);
export const int16 = (v: bigint | number): bigint => toSigned(mask(BigInt(v), 16), 16);
export const int32 = (v: bigint | number): bigint => toSigned(mask(BigInt(v), 32), 32);
export const int64 = (v: bigint | number): bigint => toSigned(mask(BigInt(v), 64), 64);
export const int128 = (v: bigint | number): bigint => toSigned(mask(BigInt(v), 128), 128);
export const int256 = (v: bigint | number): bigint => toSigned(mask(BigInt(v), 256), 256);

// =============================================================================
// BIT MANIPULATION
// =============================================================================

/**
 * Extract bits from a value
 * @param value The source value
 * @param offset The bit offset to start from (0 = LSB)
 * @param width The number of bits to extract
 */
export function extractBits(value: bigint, offset: number, width: number): bigint {
  const m = (1n << BigInt(width)) - 1n;
  return (value >> BigInt(offset)) & m;
}

/**
 * Insert bits into a value
 * @param target The target value to modify
 * @param value The value to insert
 * @param offset The bit offset to start at
 * @param width The number of bits to use
 */
export function insertBits(target: bigint, value: bigint, offset: number, width: number): bigint {
  const m = (1n << BigInt(width)) - 1n;
  const clearMask = ~(m << BigInt(offset));
  return (target & clearMask) | ((value & m) << BigInt(offset));
}

/**
 * Pack multiple values into a single bigint
 * @param values Array of [value, bitWidth] pairs, packed from LSB
 */
export function packBits(values: Array<[bigint, number]>): bigint {
  let result = 0n;
  let offset = 0;
  for (const [value, width] of values) {
    result = insertBits(result, value, offset, width);
    offset += width;
  }
  return result;
}

/**
 * Unpack multiple values from a single bigint
 * @param packed The packed value
 * @param widths Array of bit widths to extract, from LSB
 */
export function unpackBits(packed: bigint, widths: number[]): bigint[] {
  const result: bigint[] = [];
  let offset = 0;
  for (const width of widths) {
    result.push(extractBits(packed, offset, width));
    offset += width;
  }
  return result;
}

// =============================================================================
// STORAGE SIMULATION
// =============================================================================

/**
 * Simulates Solidity storage with mapping support
 */
export class Storage {
  private slots: Map<string, bigint> = new Map();
  private transient: Map<string, bigint> = new Map();

  /**
   * Read from a storage slot
   */
  sload(slot: bigint | string): bigint {
    const key = typeof slot === 'string' ? slot : slot.toString();
    return this.slots.get(key) ?? 0n;
  }

  /**
   * Write to a storage slot
   */
  sstore(slot: bigint | string, value: bigint): void {
    const key = typeof slot === 'string' ? slot : slot.toString();
    if (value === 0n) {
      this.slots.delete(key);
    } else {
      this.slots.set(key, value);
    }
  }

  /**
   * Read from transient storage
   */
  tload(slot: bigint | string): bigint {
    const key = typeof slot === 'string' ? slot : slot.toString();
    return this.transient.get(key) ?? 0n;
  }

  /**
   * Write to transient storage
   */
  tstore(slot: bigint | string, value: bigint): void {
    const key = typeof slot === 'string' ? slot : slot.toString();
    if (value === 0n) {
      this.transient.delete(key);
    } else {
      this.transient.set(key, value);
    }
  }

  /**
   * Clear all transient storage (called at end of transaction)
   */
  clearTransient(): void {
    this.transient.clear();
  }

  /**
   * Compute a mapping slot key
   */
  mappingSlot(baseSlot: bigint, key: bigint | string): bigint {
    const keyBytes = typeof key === 'string' ? key : toHex(key, { size: 32 });
    const slotBytes = toHex(baseSlot, { size: 32 });
    return hexToBigInt(keccak256(encodePacked(['bytes32', 'bytes32'], [keyBytes as `0x${string}`, slotBytes as `0x${string}`])));
  }

  /**
   * Compute a nested mapping slot key
   */
  nestedMappingSlot(baseSlot: bigint, ...keys: Array<bigint | string>): bigint {
    let slot = baseSlot;
    for (const key of keys) {
      slot = this.mappingSlot(slot, key);
    }
    return slot;
  }
}

// =============================================================================
// TYPE HELPERS
// =============================================================================

/**
 * Address utilities
 */
export const ADDRESS_ZERO = '0x0000000000000000000000000000000000000000';
export const TOMBSTONE_ADDRESS = '0x000000000000000000000000000000000000dead';

export function isZeroAddress(addr: string): boolean {
  return addr === ADDRESS_ZERO || addr === '0x0';
}

export function addressToUint(addr: string): bigint {
  return hexToBigInt(addr as `0x${string}`);
}

export function uintToAddress(value: bigint): string {
  return toHex(uint160(value), { size: 20 });
}

/**
 * Bytes32 utilities
 */
export const BYTES32_ZERO = '0x0000000000000000000000000000000000000000000000000000000000000000';

export function bytes32ToUint(b: string): bigint {
  return hexToBigInt(b as `0x${string}`);
}

export function uintToBytes32(value: bigint): string {
  return toHex(value, { size: 32 });
}

// =============================================================================
// HASH FUNCTIONS
// =============================================================================

export { keccak256 } from 'viem';

// sha256 is defined at the top of the file with Node.js crypto

// =============================================================================
// ABI ENCODING
// =============================================================================

export { encodePacked, encodeAbiParameters, parseAbiParameters } from 'viem';

/**
 * Simple ABI encode for common types
 */
export function abiEncode(types: string[], values: any[]): string {
  // Simplified encoding - in production, use viem's encodeAbiParameters
  return encodeAbiParameters(
    parseAbiParameters(types.join(',')),
    values
  );
}

// =============================================================================
// CONTRACT BASE CLASS
// =============================================================================

/**
 * Base class for transpiled contracts
 */
export abstract class Contract {
  protected _storage: Storage = new Storage();
  protected _msg = {
    sender: ADDRESS_ZERO,
    value: 0n,
    data: '0x' as `0x${string}`,
  };
  protected _block = {
    timestamp: BigInt(Math.floor(Date.now() / 1000)),
    number: 0n,
  };
  protected _tx = {
    origin: ADDRESS_ZERO,
  };

  /**
   * Set the caller for the next call
   */
  setMsgSender(sender: string): void {
    this._msg.sender = sender;
  }

  /**
   * Set the block timestamp
   */
  setBlockTimestamp(timestamp: bigint): void {
    this._block.timestamp = timestamp;
  }

  /**
   * Emit an event (in simulation, just logs it)
   */
  protected _emitEvent(...args: any[]): void {
    // In simulation mode, we can log events or store them
    console.log('Event:', ...args);
  }

  // =========================================================================
  // YUL/STORAGE HELPERS (for inline assembly simulation)
  // =========================================================================

  /**
   * Convert a key to a storage key string
   */
  protected _yulStorageKey(key: any): string {
    return typeof key === 'string' ? key : JSON.stringify(key);
  }

  /**
   * Read from raw storage (simulates Yul sload)
   */
  protected _storageRead(key: any): bigint {
    return this._storage.sload(this._yulStorageKey(key));
  }

  /**
   * Write to raw storage (simulates Yul sstore)
   */
  protected _storageWrite(key: any, value: bigint): void {
    this._storage.sstore(this._yulStorageKey(key), value);
  }
}

// =============================================================================
// EFFECT AND MOVE INTERFACES
// =============================================================================

export enum EffectStep {
  OnApply = 0,
  RoundStart = 1,
  RoundEnd = 2,
  OnRemove = 3,
  OnMonSwitchIn = 4,
  OnMonSwitchOut = 5,
  AfterDamage = 6,
  AfterMove = 7,
  OnUpdateMonState = 8,
}

export enum MoveClass {
  Physical = 0,
  Special = 1,
  Self = 2,
  Other = 3,
}

export enum Type {
  Yin = 0,
  Yang = 1,
  Earth = 2,
  Liquid = 3,
  Fire = 4,
  Metal = 5,
  Ice = 6,
  Nature = 7,
  Lightning = 8,
  Mythic = 9,
  Air = 10,
  Math = 11,
  Cyber = 12,
  Wild = 13,
  Cosmic = 14,
  None = 15,
}

// =============================================================================
// RNG HELPERS
// =============================================================================

/**
 * Deterministic RNG based on keccak256
 */
export function rngFromSeed(seed: bigint): bigint {
  return hexToBigInt(keccak256(toHex(seed, { size: 32 })));
}

/**
 * Get next RNG value from current
 */
export function nextRng(current: bigint): bigint {
  return rngFromSeed(current);
}

/**
 * Roll RNG for percentage check (0-99)
 */
export function rngPercent(rng: bigint): bigint {
  return rng % 100n;
}

// =============================================================================
// REGISTRY FOR MOVES AND EFFECTS
// =============================================================================

export interface IMoveSet {
  name(): string;
  move(battleKey: string, attackerPlayerIndex: bigint, extraData: bigint, rng: bigint): void;
  priority(battleKey: string, attackerPlayerIndex: bigint): bigint;
  stamina(battleKey: string, attackerPlayerIndex: bigint, monIndex: bigint): bigint;
  moveType(battleKey: string): Type;
  isValidTarget(battleKey: string, extraData: bigint): boolean;
  moveClass(battleKey: string): MoveClass;
}

export interface IEffect {
  name(): string;
  shouldRunAtStep(step: EffectStep): boolean;
  shouldApply(extraData: string, targetIndex: bigint, monIndex: bigint): boolean;
  onRoundStart(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean];
  onRoundEnd(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean];
  onMonSwitchIn(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean];
  onMonSwitchOut(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean];
  onAfterDamage(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint, damage: bigint): [string, boolean];
  onAfterMove(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean];
  onApply(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean];
  onRemove(extraData: string, targetIndex: bigint, monIndex: bigint): void;
}

/**
 * Registry for moves and effects
 */
export class Registry {
  private moves: Map<string, IMoveSet> = new Map();
  private effects: Map<string, IEffect> = new Map();

  registerMove(address: string, move: IMoveSet): void {
    this.moves.set(address.toLowerCase(), move);
  }

  registerEffect(address: string, effect: IEffect): void {
    this.effects.set(address.toLowerCase(), effect);
  }

  getMove(address: string): IMoveSet | undefined {
    return this.moves.get(address.toLowerCase());
  }

  getEffect(address: string): IEffect | undefined {
    return this.effects.get(address.toLowerCase());
  }
}

// Global registry instance
export const registry = new Registry();
