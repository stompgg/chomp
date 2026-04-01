/**
 * Base Contract class and core utilities
 *
 * This file is separate from index.ts to avoid circular dependencies
 * with runtime replacement modules like Ownable, ECDSA, etc.
 *
 * ALL contract classes must extend this Contract — there is only one.
 * index.ts re-exports it; it does NOT define a second Contract class.
 *
 * Storage, EventStream, globalEventStream, and ADDRESS_ZERO also live here
 * as the single source of truth. index.ts re-exports them.
 */

import { keccak256, encodePacked, toHex, hexToBigInt } from 'viem';

// =============================================================================
// CONSTANTS
// =============================================================================

export const ADDRESS_ZERO = '0x0000000000000000000000000000000000000000';

// =============================================================================
// STORAGE SIMULATION
// =============================================================================

/**
 * Simulates Solidity's persistent storage.
 * Each contract instance has its own storage that persists across calls.
 */
export class Storage {
  private slots: Map<string, bigint> = new Map();
  private transientSlots: Map<string, bigint> = new Map();

  /**
   * Read from a storage slot (SLOAD equivalent)
   */
  sload(slot: bigint | string): bigint {
    const key = typeof slot === 'string' ? slot : slot.toString();
    return this.slots.get(key) ?? 0n;
  }

  /**
   * Write to a storage slot (SSTORE equivalent)
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
   * Read from transient storage (TLOAD equivalent - EIP-1153)
   */
  tload(slot: bigint | string): bigint {
    const key = typeof slot === 'string' ? slot : slot.toString();
    return this.transientSlots.get(key) ?? 0n;
  }

  /**
   * Write to transient storage (TSTORE equivalent - EIP-1153)
   */
  tstore(slot: bigint | string, value: bigint): void {
    const key = typeof slot === 'string' ? slot : slot.toString();
    if (value === 0n) {
      this.transientSlots.delete(key);
    } else {
      this.transientSlots.set(key, value);
    }
  }

  /**
   * Clear all transient storage (called at end of transaction)
   */
  clearTransient(): void {
    this.transientSlots.clear();
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

  /**
   * Get all storage slots (for debugging)
   */
  getAllSlots(): Map<string, bigint> {
    return new Map(this.slots);
  }

  /**
   * Clear all storage
   */
  clear(): void {
    this.slots.clear();
    this.transientSlots.clear();
  }
}

// =============================================================================
// EVENT STREAM
// =============================================================================

export interface EventLog {
  name: string;
  args: Record<string, any>;
  timestamp: number;
  emitter?: string;
  data?: any[];
}

/**
 * Virtual event stream that stores all emitted events for inspection/testing
 */
export class EventStream {
  private events: EventLog[] = [];

  emit(name: string, args: Record<string, any> = {}, emitter?: string, data?: any[]): void {
    this.events.push({ name, args, timestamp: Date.now(), emitter, data });
  }

  getAll(): EventLog[] {
    return [...this.events];
  }

  getByName(name: string): EventLog[] {
    return this.events.filter(e => e.name === name);
  }

  getLast(n: number = 1): EventLog[] {
    return this.events.slice(-n);
  }

  filter(predicate: (event: EventLog) => boolean): EventLog[] {
    return this.events.filter(predicate);
  }

  clear(): void {
    this.events = [];
  }

  get length(): number {
    return this.events.length;
  }

  has(name: string): boolean {
    return this.events.some(e => e.name === name);
  }

  get latest(): EventLog | undefined {
    return this.events[this.events.length - 1];
  }
}

// =============================================================================
// CONTRACT ADDRESS MANAGEMENT
// =============================================================================

/**
 * Global registry for contract addresses.
 * Allows configuring addresses for contracts when they need actual addresses
 * (e.g., for storage keys, hashing, encoding).
 */
class ContractAddressRegistry {
  private addresses: Map<string, string> = new Map();
  private counter: bigint = 1n;

  /**
   * Set a specific address for a contract class
   */
  setAddress(className: string, address: string): void {
    this.addresses.set(className, address.toLowerCase());
  }

  /**
   * Set multiple addresses at once
   */
  setAddresses(mapping: Record<string, string>): void {
    for (const [className, address] of Object.entries(mapping)) {
      this.setAddress(className, address);
    }
  }

  /**
   * Get the address for a contract class, auto-generating if not set
   */
  getAddress(className: string): string {
    if (this.addresses.has(className)) {
      return this.addresses.get(className)!;
    }
    // Auto-generate a deterministic address from class name
    const generated = this.generateAddress(className);
    this.addresses.set(className, generated);
    return generated;
  }

  /**
   * Generate a deterministic address from a string
   */
  private generateAddress(seed: string): string {
    // Simple hash-like function for deterministic addresses
    let hash = 0n;
    for (let i = 0; i < seed.length; i++) {
      hash = (hash * 31n + BigInt(seed.charCodeAt(i))) & ((1n << 160n) - 1n);
    }
    // Add counter to ensure uniqueness for same-named classes
    hash = (hash + this.counter++) & ((1n << 160n) - 1n);
    return '0x' + hash.toString(16).padStart(40, '0');
  }

  /**
   * Check if an address is set for a class
   */
  hasAddress(className: string): boolean {
    return this.addresses.has(className);
  }

  /**
   * Clear all addresses
   */
  clear(): void {
    this.addresses.clear();
    this.counter = 1n;
  }
}

export const contractAddresses = new ContractAddressRegistry();

// =============================================================================
// GLOBAL EVENT STREAM
// =============================================================================

export const globalEventStream = new EventStream();

// =============================================================================
// ADDRESS CONVERSION (inlined to avoid circular deps with index.ts)
// =============================================================================

function uint160(value: bigint): bigint {
  return value & ((1n << 160n) - 1n);
}

function bigintToAddress(value: bigint): string {
  return '0x' + uint160(value).toString(16).padStart(40, '0');
}

// =============================================================================
// BASE CONTRACT CLASS
// =============================================================================

/**
 * Base class for all transpiled Solidity contracts.
 * Provides storage simulation, event emission, context (msg, block, tx),
 * address registry for Contract.at() lookups, and YUL assembly helpers.
 */
export abstract class Contract {
  /** Static registry: address → contract instance, for Contract.at() lookups */
  private static _addressRegistry: Map<string, Contract> = new Map();

  /**
   * Temporary debug: trace specific proxy-intercepted method calls.
   * Set to an array of method names to trace (e.g., ['removeStatBoosts', 'addStatBoosts']).
   * Logs msg.sender, args, and events emitted during the call.
   */
  static _debugTraceMethods: Set<string> | null = null;
  static _debugLog: any[] = [];

  /**
   * Temporary debug: wrap methods on a contract's PROTOTYPE so both proxy and
   * raw-instance calls are intercepted. Call _disableRawTracing to restore.
   */
  private static _tracedOriginals: Map<string, Function> = new Map();

  static _enableRawTracing(instance: any, methodNames: string[]): void {
    const proto = Object.getPrototypeOf(instance);
    const safe = (v: any, depth = 0): any => {
      if (v === null || v === undefined) return v;
      if (typeof v === 'bigint') return v.toString();
      if (typeof v === 'function') return undefined;
      if (typeof v !== 'object') return v;
      if ('_contractAddress' in v) return `[${v.constructor?.name} ${v._contractAddress}]`;
      if (depth > 2) return '[deep]';
      if (Array.isArray(v)) return v.map(i => safe(i, depth + 1));
      const o: Record<string, any> = {};
      for (const k of Object.keys(v)) {
        if (k.startsWith('_')) continue;
        o[k] = safe(v[k], depth + 1);
      }
      return o;
    };
    for (const name of methodNames) {
      const original = proto[name];
      if (typeof original !== 'function') continue;
      Contract._tracedOriginals.set(`${proto.constructor.name}.${name}`, original);
      proto[name] = function (this: any, ...args: any[]) {
        if (Contract._debugTraceMethods) {
          Contract._debugLog.push({ call: name, on: this.constructor.name, args: safe(args) });
        }
        const result = original.apply(this, args);
        if (Contract._debugTraceMethods && result !== undefined) {
          try {
            Contract._debugLog.push({ ret: name, value: safe(result) });
          } catch { Contract._debugLog.push({ ret: name, value: '[err]' }); }
        }
        return result;
      };
    }
  }

  static _disableRawTracing(): void {
    for (const [key, original] of Contract._tracedOriginals) {
      const [className, methodName] = key.split('.');
      // Find the prototype via the registry
      for (const instance of Contract._addressRegistry.values()) {
        if (instance.constructor.name === className) {
          Object.getPrototypeOf(instance)[methodName] = original;
          break;
        }
      }
    }
    Contract._tracedOriginals.clear();
  }

  /**
   * Tracks the address of the currently executing contract.
   * Used to propagate msg.sender on cross-contract calls (matching Solidity semantics).
   */
  static _currentCaller: string = ADDRESS_ZERO;

  /**
   * Tracks nesting depth of external contract calls.
   * Used to detect transaction boundaries for transient storage reset.
   * Depth 0→1 = new transaction = reset all transient storage.
   */
  static _callDepth: number = 0;

  /**
   * Raw (unwrapped) instances of contracts that have transient storage.
   * Populated in the constructor when _resetTransient exists on the prototype.
   */
  private static _transientInstances: any[] = [];

  /**
   * Reset transient storage on all registered contracts.
   * Called automatically at transaction boundaries (when _callDepth goes 0→1).
   * This matches Solidity semantics where transient storage is cleared per transaction.
   */
  static _resetAllTransient(): void {
    for (const instance of Contract._transientInstances) {
      instance._resetTransient();
    }
  }

  /**
   * Resolve a value to a contract instance.
   * - If value is already a contract object, return it directly.
   * - If value is a bigint (uint256 address), look up by address in the registry.
   * - If value is a string address, look up directly.
   * Returns a stub with only _contractAddress for unregistered addresses
   * (e.g. sentinels/tombstones that are only used for identity comparisons).
   */
  static at(value: any): any {
    if (value && typeof value === 'object' && '_contractAddress' in value) {
      return value;
    }
    let address: string;
    if (typeof value === 'bigint') {
      address = bigintToAddress(value);
    } else if (typeof value === 'string') {
      address = value;
    } else {
      throw new Error(`Contract.at: cannot resolve ${typeof value}`);
    }
    const normalized = address.toLowerCase();
    const instance = Contract._addressRegistry.get(normalized);
    if (instance) {
      return instance;
    }
    // Return a lightweight stub for unregistered addresses (e.g. sentinel/tombstone).
    // Only _contractAddress is set — calling methods on it will fail, which is correct
    // since these addresses are only used for identity comparisons.
    return { _contractAddress: normalized };
  }

  /**
   * Clear the address registry and transient instance tracking (useful between tests)
   */
  static clearRegistry(): void {
    Contract._addressRegistry.clear();
    Contract._transientInstances = [];
    Contract._callDepth = 0;
  }

  // Storage for this contract instance
  protected _storage: Storage = new Storage();

  // Event stream - shared across all contracts for a transaction
  protected _eventStream: EventStream = globalEventStream;

  /**
   * Contract address for address(this) pattern.
   * Setting this auto-registers the instance in the static address registry.
   */
  private _address: string = ADDRESS_ZERO;
  /** Reference to the Proxy wrapping this instance (set by constructor) */
  private _proxy: any = null;

  get _contractAddress(): string {
    return this._address;
  }

  set _contractAddress(addr: string) {
    this._address = addr;
    if (addr !== ADDRESS_ZERO) {
      // Register the Proxy (not the raw instance) so Contract.at() returns
      // the msg.sender-propagating wrapper
      Contract._addressRegistry.set(addr.toLowerCase(), this._proxy ?? this);
    }
  }

  // Message context (msg.sender, msg.value, msg.data)
  public _msg: {
    sender: string;
    value: bigint;
    data: `0x${string}`;
  } = {
    sender: ADDRESS_ZERO,
    value: 0n,
    data: '0x' as `0x${string}`,
  };

  // Block context
  public _block: {
    timestamp: bigint;
    number: bigint;
  } = {
    timestamp: BigInt(Math.floor(Date.now() / 1000)),
    number: 0n,
  };

  // Transaction context
  public _tx: {
    origin: string;
  } = {
    origin: ADDRESS_ZERO,
  };

  constructor(...args: any[]) {
    // If the first arg is a string, use it as the address; otherwise auto-generate.
    // Transpiled constructors may pass non-address args (e.g. dependencies) which
    // propagate up the chain — we ignore non-string first args.
    const address = typeof args[0] === 'string' ? args[0] : undefined;
    this._contractAddress = address ?? contractAddresses.getAddress(this.constructor.name);

    // Register for transient reset if this contract has transient vars.
    // Done here (before proxy wrapping) so we store the raw instance,
    // allowing _resetAllTransient to call _resetTransient without going through the proxy.
    if (typeof (this as any)._resetTransient === 'function') {
      Contract._transientInstances.push(this);
    }

    // Wrap instance in a Proxy that propagates msg.sender on cross-contract calls.
    // In Solidity, when contract A calls contract B, msg.sender in B = A's address.
    // Internal calls (same contract) don't change msg.sender.
    // The proxy also tracks call depth to auto-reset transient storage at transaction
    // boundaries (depth 0→1), matching Solidity's per-transaction semantics.
    const self = this;
    const proxy = new Proxy(this, {
      // Ensure property writes through the proxy go to the target (not the proxy object).
      // This is critical because external calls use `this = proxy` inside methods,
      // so `this.field = x` must write to the target's storage.
      set(target, prop, value, receiver) {
        return Reflect.set(target, prop, value, target);
      },
      get(target, prop, receiver) {
        const value = Reflect.get(target, prop, receiver);
        if (typeof value !== 'function' || typeof prop === 'symbol') return value;
        // Skip private/internal helpers and property accessors
        const propStr = prop as string;
        if (propStr.startsWith('_')) return value;

        return function (this: any, ...callArgs: any[]) {
          // Internal call: same contract is already executing, don't change msg.sender
          if (Contract._currentCaller === self._contractAddress) {
            return value.apply(proxy, callArgs);
          }
          // External call: propagate msg.sender
          // Reset transient storage at transaction boundary (first external entry)
          const isTopLevel = Contract._callDepth === 0;
          Contract._callDepth++;
          if (isTopLevel) {
            Contract._resetAllTransient();
          }
          const prevSender = target._msg.sender;
          const prevCaller = Contract._currentCaller;
          target._msg.sender = Contract._currentCaller;
          Contract._currentCaller = self._contractAddress;

          // Debug tracing: capture state when entering a traced method
          const tracing = Contract._debugTraceMethods?.has(propStr);
          if (tracing) {
            const eventsBefore = globalEventStream.length;
            Contract._debugLog.push({
              enter: propStr,
              contract: self.constructor.name,
              address: self._contractAddress,
              msgSender: target._msg.sender,
              currentCaller: Contract._currentCaller,
              callDepth: Contract._callDepth,
              args: callArgs.map(a => typeof a === 'bigint' ? a.toString() : typeof a === 'object' && a?._contractAddress ? `[${a.constructor?.name} ${a._contractAddress}]` : a),
            });
            try {
              const result = value.apply(proxy, callArgs);
              const eventsAfter = globalEventStream.length;
              Contract._debugLog.push({
                exit: propStr,
                eventsEmitted: eventsAfter - eventsBefore,
                newEvents: globalEventStream.getAll().slice(eventsBefore).map(e => ({ name: e.name, data: e.data })),
              });
              return result;
            } finally {
              target._msg.sender = prevSender;
              Contract._currentCaller = prevCaller;
              Contract._callDepth--;
            }
          }

          try {
            return value.apply(proxy, callArgs);
          } finally {
            target._msg.sender = prevSender;
            Contract._currentCaller = prevCaller;
            Contract._callDepth--;
          }
        };
      },
    });
    this._proxy = proxy;
    return proxy as this;
  }

  // =========================================================================
  // CONTEXT SETTERS
  // =========================================================================

  setMsgSender(sender: string): void {
    this._msg.sender = sender;
  }

  setMsgContext(sender: string, value: bigint = 0n, data: `0x${string}` = '0x'): void {
    this._msg = { sender, value, data };
  }

  setBlockTimestamp(timestamp: bigint): void {
    this._block.timestamp = timestamp;
  }

  setBlockContext(timestamp: bigint, number: bigint): void {
    this._block = { timestamp, number };
  }

  setTxContext(origin: string): void {
    this._tx = { origin };
  }

  // =========================================================================
  // EVENT STREAM
  // =========================================================================

  setEventStream(stream: EventStream): void {
    this._eventStream = stream;
  }

  getEventStream(): EventStream {
    return this._eventStream;
  }

  protected _emitEvent(name: string, ...args: any[]): void {
    const argsObj: Record<string, any> = {};
    args.forEach((arg, i) => {
      if (typeof arg === 'object' && arg !== null && !Array.isArray(arg)) {
        Object.assign(argsObj, arg);
      } else {
        argsObj[`arg${i}`] = arg;
      }
    });
    this._eventStream.emit(name, argsObj, this._contractAddress, args);
  }

  // =========================================================================
  // STORAGE HELPERS
  // =========================================================================

  protected _sload(slot: bigint | string): bigint {
    return this._storage.sload(slot);
  }

  protected _sstore(slot: bigint | string, value: bigint): void {
    this._storage.sstore(slot, value);
  }

  protected _tload(slot: bigint | string): bigint {
    return this._storage.tload(slot);
  }

  protected _tstore(slot: bigint | string, value: bigint): void {
    this._storage.tstore(slot, value);
  }

  // =========================================================================
  // YUL/ASSEMBLY HELPERS (used by transpiled inline assembly)
  // =========================================================================

  protected _yulStorageKey(key: any): string {
    return typeof key === 'string' ? key : JSON.stringify(key);
  }

  protected _storageRead(key: any): bigint {
    return this._storage.sload(this._yulStorageKey(key));
  }

  protected _storageWrite(key: any, value: bigint): void {
    this._storage.sstore(this._yulStorageKey(key), value);
  }
}
