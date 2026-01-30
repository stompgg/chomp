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
// BLOCKCHAIN BUILTINS
// =============================================================================

/**
 * Simulated blockhash function
 * In Solidity, blockhash(n) returns the hash of block n (if within last 256 blocks)
 * For simulation purposes, we generate a deterministic pseudo-hash based on block number
 */
export function blockhash(blockNumber: bigint): `0x${string}` {
  // Generate a deterministic hash based on block number for simulation
  const encoded = encodeAbiParameters([{ type: 'uint256' }], [blockNumber]);
  return keccak256(encoded);
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
// EVENT STREAM
// =============================================================================

/**
 * Represents a single event emitted by a contract
 */
export interface EventLog {
  /** Event name/type */
  name: string;
  /** Event arguments as key-value pairs */
  args: Record<string, any>;
  /** Timestamp when the event was emitted */
  timestamp: number;
  /** Contract address that emitted the event (if available) */
  emitter?: string;
  /** Additional raw data */
  data?: any[];
}

/**
 * Virtual event stream that stores all emitted events for inspection/testing
 */
export class EventStream {
  private events: EventLog[] = [];

  /**
   * Append an event to the stream
   */
  emit(name: string, args: Record<string, any> = {}, emitter?: string, data?: any[]): void {
    this.events.push({
      name,
      args,
      timestamp: Date.now(),
      emitter,
      data,
    });
  }

  /**
   * Get all events
   */
  getAll(): EventLog[] {
    return [...this.events];
  }

  /**
   * Get events by name
   */
  getByName(name: string): EventLog[] {
    return this.events.filter(e => e.name === name);
  }

  /**
   * Get the last N events
   */
  getLast(n: number = 1): EventLog[] {
    return this.events.slice(-n);
  }

  /**
   * Get events matching a filter function
   */
  filter(predicate: (event: EventLog) => boolean): EventLog[] {
    return this.events.filter(predicate);
  }

  /**
   * Clear all events
   */
  clear(): void {
    this.events = [];
  }

  /**
   * Get event count
   */
  get length(): number {
    return this.events.length;
  }

  /**
   * Check if any event matches
   */
  has(name: string): boolean {
    return this.events.some(e => e.name === name);
  }

  /**
   * Get the most recent event (or undefined if empty)
   */
  get latest(): EventLog | undefined {
    return this.events[this.events.length - 1];
  }
}

/**
 * Global event stream instance - all contracts emit to this by default
 */
export const globalEventStream = new EventStream();

// =============================================================================
// CONTRACT BASE CLASS
// =============================================================================

/**
 * Base class for transpiled contracts
 */
export abstract class Contract {
  protected _storage: Storage = new Storage();
  protected _eventStream: EventStream = globalEventStream;
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
   * Contract address for address(this) pattern
   * Initialized to a unique address based on instance creation
   */
  readonly _contractAddress: string = ADDRESS_ZERO;

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
   * Set a custom event stream for this contract
   */
  setEventStream(stream: EventStream): void {
    this._eventStream = stream;
  }

  /**
   * Get the event stream for this contract
   */
  getEventStream(): EventStream {
    return this._eventStream;
  }

  /**
   * Emit an event to the event stream
   */
  protected _emitEvent(name: string, ...args: any[]): void {
    // Convert args array to a more structured format
    const argsObj: Record<string, any> = {};
    args.forEach((arg, i) => {
      if (typeof arg === 'object' && arg !== null && !Array.isArray(arg)) {
        // Merge object arguments
        Object.assign(argsObj, arg);
      } else {
        argsObj[`arg${i}`] = arg;
      }
    });
    this._eventStream.emit(name, argsObj, undefined, args);
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
// DEPENDENCY INJECTION CONTAINER
// =============================================================================

/**
 * Factory function type for creating contract instances
 */
export type ContractFactory<T = any> = (...deps: any[]) => T;

/**
 * Container registration entry
 */
interface ContainerEntry {
  instance?: any;
  factory?: ContractFactory;
  dependencies?: string[];
  singleton: boolean;
  aliasFor?: string;  // If set, this entry delegates to another registration
}

/**
 * Dependency injection container for managing contract instances and their dependencies.
 *
 * Supports:
 * - Singleton instances (register once, resolve same instance)
 * - Factory functions (create new instance on each resolve)
 * - Automatic dependency resolution
 * - Lazy instantiation
 *
 * Example usage:
 * ```typescript
 * const container = new ContractContainer();
 *
 * // Register singletons (shared instances)
 * container.registerSingleton('Engine', new Engine());
 * container.registerSingleton('TypeCalculator', new TypeCalculator());
 *
 * // Register factory with dependencies
 * container.registerFactory('UnboundedStrike',
 *   ['Engine', 'TypeCalculator', 'Baselight'],
 *   (engine, typeCalc, baselight) => new UnboundedStrike(engine, typeCalc, baselight)
 * );
 *
 * // Resolve with automatic dependency injection
 * const move = container.resolve<UnboundedStrike>('UnboundedStrike');
 * ```
 */
export class ContractContainer {
  private entries: Map<string, ContainerEntry> = new Map();
  private resolving: Set<string> = new Set(); // For circular dependency detection

  /**
   * Register a singleton instance
   */
  registerSingleton<T>(name: string, instance: T): void {
    this.entries.set(name, {
      instance,
      singleton: true,
    });
  }

  /**
   * Register a factory function with dependencies
   */
  registerFactory<T>(
    name: string,
    dependencies: string[],
    factory: ContractFactory<T>
  ): void {
    this.entries.set(name, {
      factory,
      dependencies,
      singleton: false,
    });
  }

  /**
   * Register a lazy singleton (created on first resolve)
   */
  registerLazySingleton<T>(
    name: string,
    dependencies: string[],
    factory: ContractFactory<T>
  ): void {
    this.entries.set(name, {
      factory,
      dependencies,
      singleton: true,
    });
  }

  /**
   * Register an alias that resolves to another registered name.
   * Useful for mapping interface names to implementations (e.g., 'IEngine' -> 'Engine').
   */
  registerAlias(aliasName: string, targetName: string): void {
    this.entries.set(aliasName, {
      aliasFor: targetName,
      singleton: false,
    });
  }

  /**
   * Check if a name is registered
   */
  has(name: string): boolean {
    return this.entries.has(name);
  }

  /**
   * Resolve an instance by name
   */
  resolve<T = any>(name: string): T {
    const entry = this.entries.get(name);
    if (!entry) {
      throw new Error(`ContractContainer: '${name}' is not registered`);
    }

    // Handle aliases by delegating to the target
    if (entry.aliasFor) {
      return this.resolve<T>(entry.aliasFor);
    }

    // Return existing singleton instance
    if (entry.singleton && entry.instance !== undefined) {
      return entry.instance;
    }

    // Check for circular dependencies
    if (this.resolving.has(name)) {
      const cycle = Array.from(this.resolving).join(' -> ') + ' -> ' + name;
      throw new Error(`ContractContainer: Circular dependency detected: ${cycle}`);
    }

    // Create new instance using factory
    if (entry.factory) {
      this.resolving.add(name);
      try {
        // Resolve dependencies
        const deps = (entry.dependencies || []).map(dep => this.resolve(dep));
        const instance = entry.factory(...deps);

        // Store singleton instances
        if (entry.singleton) {
          entry.instance = instance;
        }

        return instance;
      } finally {
        this.resolving.delete(name);
      }
    }

    throw new Error(`ContractContainer: '${name}' has no instance or factory`);
  }

  /**
   * Try to resolve an instance, returning undefined if not found
   */
  tryResolve<T = any>(name: string): T | undefined {
    try {
      return this.resolve<T>(name);
    } catch {
      return undefined;
    }
  }

  /**
   * Get all registered names
   */
  getRegisteredNames(): string[] {
    return Array.from(this.entries.keys());
  }

  /**
   * Create a child container that inherits from this one
   */
  createChild(): ContractContainer {
    const child = new ContractContainer();
    // Copy all entries from parent
    for (const [name, entry] of this.entries) {
      child.entries.set(name, { ...entry });
    }
    return child;
  }

  /**
   * Clear all registrations
   */
  clear(): void {
    this.entries.clear();
    this.resolving.clear();
  }

  /**
   * Bulk register from a dependency manifest
   */
  registerFromManifest(
    manifest: Record<string, string[]>,
    factories: Record<string, ContractFactory>
  ): void {
    for (const [name, dependencies] of Object.entries(manifest)) {
      const factory = factories[name];
      if (factory) {
        this.registerFactory(name, dependencies, factory);
      }
    }
  }
}

/**
 * Global container instance for convenience
 */
export const globalContainer = new ContractContainer();

// =============================================================================
// RUNTIME REPLACEMENT RE-EXPORTS
// =============================================================================
// These modules provide TypeScript implementations for Solidity files with
// complex Yul assembly that cannot be accurately transpiled.
// See transpiler/runtime-replacements.json for configuration.

export { Ownable } from './Ownable';
export {
  EnumerableSetLib,
  AddressSet,
  Bytes32Set,
  Uint256Set,
  Int256Set,
} from './EnumerableSetLib';
export { ECDSA } from './ECDSA';

// =============================================================================
// BATTLE HARNESS RE-EXPORT
// =============================================================================

export {
  BattleHarness,
  createBattleHarness,
  type MonConfig,
  type TeamConfig,
  type AddressConfig,
  type BattleConfig,
  type MoveDecision,
  type TurnInput,
  type MonState,
  type BattleState,
  type ContainerSetupFn,
  // NOTE: SWITCH_MOVE_INDEX and NO_OP_MOVE_INDEX should be imported from
  // transpiled Constants.ts (from src/Constants.sol), not from the runtime.
} from './battle-harness';
