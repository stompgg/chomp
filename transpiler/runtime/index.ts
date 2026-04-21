/**
 * Solidity to TypeScript Runtime Library
 *
 * This library provides the runtime support for transpiled Solidity code,
 * including storage simulation, bit manipulation, and type utilities.
 */

import { keccak256, encodePacked, encodeAbiParameters, parseAbiParameters, toHex, hexToBigInt, sha256 as viemSha256 } from 'viem';

// Note: Contract, Storage, EventStream, and globalEventStream are defined in ./base
// and re-exported here. Runtime replacement modules (Ownable, etc.) import
// directly from ./base to avoid circular dependencies.

// =============================================================================
// HASH FUNCTIONS
// =============================================================================

/**
 * SHA-256 hash function (returns hex string with 0x prefix)
 * Uses viem's sha256 which works in both Node.js and browsers
 */
export function sha256(data: `0x${string}` | string): `0x${string}` {
  // Ensure input has 0x prefix for viem
  const hexData = data.startsWith('0x') ? data as `0x${string}` : `0x${data}` as `0x${string}`;
  return viemSha256(hexData);
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

/**
 * Solidity `ecrecover(hash, v, r, s)` — not modeled.
 *
 * Throws rather than returning a fake "recovered" address. A pseudo-recovery
 * (e.g. keccak-of-inputs, last-20-bytes) would typecheck, run deterministically,
 * and look plausible in tests — which is exactly the wrong-but-silent failure
 * mode the runtime avoids. If you need real recovery, add a runtime
 * replacement that wraps viem's `recoverAddress` (async) from a harness-level
 * awaiter, or use `@noble/curves/secp256k1.recoverPublicKey` for sync.
 */
export function ecrecover(
  _hash: `0x${string}` | string,
  _v: bigint,
  _r: `0x${string}` | string,
  _s: `0x${string}` | string,
): `0x${string}` {
  throw new Error(
    'ecrecover called — not modeled in simulation. Real secp256k1 recovery is ' +
    'not shipped in the runtime; add a runtime replacement for the contract ' +
    'that calls it, or substitute your own `ecrecover` binding.',
  );
}

/**
 * Solidity `selfdestruct(recipient)` — not modeled.
 *
 * Throws loudly rather than silently being a no-op, so code that depends on
 * destruction semantics (e.g. "redeploy at the same address") fails fast. If
 * your simulation genuinely needs a zombie contract to stay alive, override
 * this with a runtime replacement that records the call and continues.
 */
export function selfdestruct(_recipient: string): never {
  throw new Error(
    'selfdestruct called — not modeled in simulation. The contract would stay ' +
    'alive in this harness; override the caller via a runtime replacement if ' +
    'your test depends on the destruction effect.',
  );
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
// RE-EXPORTS FROM BASE (single source of truth)
// =============================================================================

export { Storage, EventStream, ADDRESS_ZERO, globalEventStream, contractAddresses } from './base';
export type { EventLog } from './base';
import { ADDRESS_ZERO } from './base';

// =============================================================================
// TYPE HELPERS
// =============================================================================

/**
 * Address utilities
 */
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
// CONTRACT BASE CLASS (re-exported from base.ts — single Contract class)
// =============================================================================

export { Contract } from './base';

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
