/**
 * EnumerableSetLib - Enumerable set utility functions
 *
 * This is a TypeScript implementation of Solady's EnumerableSetLib pattern. This implementation
 * provides the same interface using JavaScript's native Set.
 *
 * @see transpiler/runtime-replacements.json for configuration
 */

import { Contract } from './index';

// =============================================================================
// SET TYPE CLASSES
// =============================================================================

/**
 * Address set - stores unique string addresses
 */
export class AddressSet {
  private _set: Set<string> = new Set();

  get length(): bigint {
    return BigInt(this._set.size);
  }

  contains(value: string): boolean {
    return this._set.has(value);
  }

  add(value: string): boolean {
    if (this._set.has(value)) return false;
    this._set.add(value);
    return true;
  }

  remove(value: string): boolean {
    return this._set.delete(value);
  }

  values(): string[] {
    return Array.from(this._set);
  }

  at(index: bigint): string {
    const arr = this.values();
    const i = Number(index);
    if (i >= arr.length) throw new Error("IndexOutOfBounds");
    return arr[i];
  }
}

/**
 * Bytes32 set - stores unique bytes32 hex strings
 */
export class Bytes32Set {
  private _set: Set<string> = new Set();

  get length(): bigint {
    return BigInt(this._set.size);
  }

  contains(value: string): boolean {
    return this._set.has(value);
  }

  add(value: string): boolean {
    if (this._set.has(value)) return false;
    this._set.add(value);
    return true;
  }

  remove(value: string): boolean {
    return this._set.delete(value);
  }

  values(): string[] {
    return Array.from(this._set);
  }

  at(index: bigint): string {
    const arr = this.values();
    const i = Number(index);
    if (i >= arr.length) throw new Error("IndexOutOfBounds");
    return arr[i];
  }
}

/**
 * Uint256 set - stores unique bigint values
 */
export class Uint256Set {
  private _set: Set<bigint> = new Set();

  get length(): bigint {
    return BigInt(this._set.size);
  }

  contains(value: bigint): boolean {
    return this._set.has(value);
  }

  add(value: bigint): boolean {
    if (this._set.has(value)) return false;
    this._set.add(value);
    return true;
  }

  remove(value: bigint): boolean {
    return this._set.delete(value);
  }

  values(): bigint[] {
    return Array.from(this._set);
  }

  at(index: bigint): bigint {
    const arr = this.values();
    const i = Number(index);
    if (i >= arr.length) throw new Error("IndexOutOfBounds");
    return arr[i];
  }
}

/**
 * Int256 set - stores unique bigint values (signed)
 */
export class Int256Set {
  private _set: Set<bigint> = new Set();

  get length(): bigint {
    return BigInt(this._set.size);
  }

  contains(value: bigint): boolean {
    return this._set.has(value);
  }

  add(value: bigint): boolean {
    if (this._set.has(value)) return false;
    this._set.add(value);
    return true;
  }

  remove(value: bigint): boolean {
    return this._set.delete(value);
  }

  values(): bigint[] {
    return Array.from(this._set);
  }

  at(index: bigint): bigint {
    const arr = this.values();
    const i = Number(index);
    if (i >= arr.length) throw new Error("IndexOutOfBounds");
    return arr[i];
  }
}

// =============================================================================
// ENUMERABLE SET LIBRARY CLASS
// =============================================================================

/**
 * Enumerable set utility functions.
 * Provides set operations without complex Yul assembly.
 * Based on Solady's EnumerableSetLib pattern.
 */
export class EnumerableSetLib extends Contract {
  // Sentinel value used internally
  static readonly _ZERO_SENTINEL: bigint = BigInt("0xfbb67fda52d4bfb8bf");
}
