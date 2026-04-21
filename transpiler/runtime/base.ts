/**
 * Base Contract class and core utilities
 *
 * This file is separate from index.ts to avoid circular dependencies
 * with runtime replacement modules like Ownable, etc.
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
// CALL LOG TYPES
// =============================================================================

/**
 * A single cross-contract method call captured by the Contract proxy.
 * Captured calls form a tree: each entry has `children` (sub-calls made
 * during its execution) and `stateChanges` (state variable mutations
 * directly caused by this call, not by sub-calls).
 */
export interface CallEntry {
  /** Address of the calling contract */
  caller: string;
  /** Class name of the calling contract */
  callerName: string;
  /** Address of the target contract */
  target: string;
  /** Class name of the target contract */
  targetName: string;
  /** Method name */
  method: string;
  /** Method arguments (raw — may contain BigInt, contract references, etc.) */
  args: any[];
  /** Return value (raw — carries semantic info like [damage, eventType]) */
  returnValue?: any;
  /** Call depth at time of call (1 = top-level external call into the system) */
  depth: number;
  /** True if this was an internal call (same contract, no msg.sender change) */
  internal?: boolean;
  /** Sub-calls made during this call's execution (in order). */
  children: CallEntry[];
  /** State variable mutations directly attributed to this call (not its children). */
  stateChanges: StateChangeEntry[];
}

/**
 * A single state variable mutation captured by the deep observation proxy.
 * Logged when a mutable storage variable (listed in __stateVars) is written.
 */
export interface StateChangeEntry {
  /** Class name of the contract that owns the state */
  contractName: string;
  /** Full property path from the state variable root, e.g. "p0States.0.staminaDelta" */
  field: string;
  /** Value before the write */
  oldValue: any;
  /** Value after the write */
  newValue: any;
}

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
// DEEP STATE OBSERVATION
// =============================================================================

/**
 * Cache for nested state-tracking proxies. Maps a raw object to its
 * { proxy, path } wrapper so the same object always returns the same proxy.
 */
const _stateProxyCache = new WeakMap<object, Map<string, any>>();

/**
 * Record a state change. Attaches to the innermost active call entry if one
 * exists; otherwise falls back to the orphan _stateChangeLog (if set).
 */
function _recordStateChange(change: StateChangeEntry): void {
  const top = Contract._callStack[Contract._callStack.length - 1];
  if (top) {
    top.stateChanges.push(change);
  } else if (Contract._stateChangeLog) {
    Contract._stateChangeLog.push(change);
  }
}

/**
 * Wrap an object in a recursive Proxy that logs property writes to
 * Contract._stateChangeLog. Used for nested state (structs, arrays)
 * accessed through a contract's __stateVars properties.
 *
 * @param obj          The raw object to wrap
 * @param contractName Class name of the owning contract
 * @param path         Dot-delimited path from the state variable root
 */
function _wrapForStateTracking(obj: any, contractName: string, path: string): any {
  if (obj === null || obj === undefined || typeof obj !== 'object') return obj;

  // Check cache: same object + same path → same proxy
  let pathMap = _stateProxyCache.get(obj);
  if (!pathMap) {
    pathMap = new Map();
    _stateProxyCache.set(obj, pathMap);
  }
  const cached = pathMap.get(path);
  if (cached) return cached;

  const proxy = new Proxy(obj, {
    get(target, prop, receiver) {
      const value = Reflect.get(target, prop, receiver);
      if (typeof prop === 'symbol') return value;
      // Recursively wrap nested objects (structs, arrays) for deep tracking
      if (value !== null && typeof value === 'object'
          && (Contract._callStack.length > 0 || Contract._stateChangeLog)) {
        const childPath = path ? `${path}.${String(prop)}` : String(prop);
        return _wrapForStateTracking(value, contractName, childPath);
      }
      return value;
    },
    set(target, prop, newValue, receiver) {
      if (typeof prop !== 'symbol') {
        const fieldPath = path ? `${path}.${String(prop)}` : String(prop);
        const oldValue = Reflect.get(target, prop, target);
        if (oldValue !== newValue) {
          _recordStateChange({
            contractName,
            field: fieldPath,
            oldValue,
            newValue,
          });
        }
      }
      return Reflect.set(target, prop, newValue, target);
    },
  });
  pathMap.set(path, proxy);
  return proxy;
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

  /** Mutable storage variable names — overridden per contract by the transpiler.
   *  Used by the state-change tracking proxy to filter which property writes to log. */
  static readonly __stateVars: Set<string> = new Set();



  // =========================================================================
  // CALL LOGGING
  // =========================================================================

  /**
   * When non-null, the proxy logs every cross-contract call as a tree of
   * CallEntry nodes. Top-level entries are external calls into the system;
   * each entry's `children` holds sub-calls made during its execution.
   * Set before executeTurn(), read after, cleared between turns.
   */
  static _turnCallLog: CallEntry[] | null = null;

  /**
   * Stack of currently-executing call entries. The innermost (top) entry
   * receives any state variable mutations that happen during its execution.
   * Sub-calls push themselves onto this stack so the proxy can attribute
   * mutations to the right call.
   */
  static _callStack: CallEntry[] = [];

  /**
   * Fallback log for state changes that happen outside any tracked call
   * (e.g., during construction, or when _turnCallLog is null).
   * Set before executeTurn() to enable orphan tracking.
   */
  static _stateChangeLog: StateChangeEntry[] | null = null;

  /**
   * Tracks the address of the currently executing contract.
   * Used to propagate msg.sender on cross-contract calls (matching Solidity semantics).
   */
  static _currentCaller: string = ADDRESS_ZERO;
  static _currentCallerName: string = 'External';

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
    const prevAddr = this._address;
    this._address = addr;
    // Remove stale registry entry for the previous address (if we were the
    // current holder). Prevents the registry from accumulating entries for
    // intermediate addresses, e.g. when an address is overwritten by
    // registerOnchainAddresses.
    if (prevAddr !== ADDRESS_ZERO && prevAddr !== addr) {
      const prevLower = prevAddr.toLowerCase();
      const current = Contract._addressRegistry.get(prevLower);
      if (current === (this._proxy ?? this) || current === this) {
        Contract._addressRegistry.delete(prevLower);
      }
    }
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
    // If the first arg is an explicit address string, use it. Otherwise leave
    // _address at ADDRESS_ZERO; callers (e.g. registerOnchainAddresses) will
    // set the real address after construction. This avoids populating the
    // static _addressRegistry with stale auto-generated entries.
    if (typeof args[0] === 'string') {
      this._contractAddress = args[0];
    }

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
      // Also logs state variable mutations to the innermost active call.
      set(target, prop, value, receiver) {
        if (typeof prop !== 'symbol') {
          const stateVars = (self.constructor as any).__stateVars as Set<string> | undefined;
          if (stateVars?.has(prop as string)) {
            const oldValue = Reflect.get(target, prop, target);
            if (oldValue !== value) {
              _recordStateChange({
                contractName: self.constructor.name,
                field: prop as string,
                oldValue,
                newValue: value,
              });
            }
          }
        }
        return Reflect.set(target, prop, value, target);
      },
      get(target, prop, receiver) {
        const value = Reflect.get(target, prop, receiver);
        if (typeof prop === 'symbol') return value;
        // Wrap state variable objects in deep observation proxy for nested tracking.
        // Active whenever there's a current call or _stateChangeLog is set.
        if (typeof value !== 'function' && value !== null && typeof value === 'object'
            && (Contract._callStack.length > 0 || Contract._stateChangeLog)) {
          const stateVars = (self.constructor as any).__stateVars as Set<string> | undefined;
          if (stateVars?.has(prop as string)) {
            return _wrapForStateTracking(value, self.constructor.name, prop as string);
          }
        }
        if (typeof value !== 'function') return value;
        const propStr = prop as string;

        // State-changing methods that the call log must always capture,
        // even for internal calls and `_` prefixed internal variants.
        // Internal *Internal variants are preferred over public wrappers since
        // they catch both the public-API path AND direct internal callers
        // (e.g. _inlineStandardAttack bypasses public dispatchStandardAttack).
        const LOGGED_METHODS = ['_dealDamageInternal', '_emitMonMove', 'updateMonState', '_addEffectInternal', '_dispatchStandardAttackInternal', '_calculateDamage', 'removeEffect'];
        const forceLog = Contract._turnCallLog && LOGGED_METHODS.includes(propStr);

        // Skip private/internal helpers — except force-logged methods
        if (propStr.startsWith('_') && !forceLog) return value;

        return function (this: any, ...callArgs: any[]) {
          const isInternal = Contract._currentCaller === self._contractAddress;

          // Capture caller context BEFORE the call (these are the values seen FROM
          // the caller's perspective, before we update _currentCaller for this call).
          const preCallCaller = Contract._currentCaller;
          const preCallCallerName = Contract._currentCallerName;

          // Create the call entry up front so any state changes during execution
          // can attach to it. Only created if logging is active.
          const entry: CallEntry | null = Contract._turnCallLog ? {
            caller: preCallCaller,
            callerName: preCallCallerName,
            target: self._contractAddress,
            targetName: self.constructor.name,
            method: propStr,
            args: callArgs,
            depth: Contract._callDepth + (isInternal ? 0 : 1),
            internal: isInternal,
            children: [],
            stateChanges: [],
          } : null;

          if (entry) Contract._callStack.push(entry);

          // External-only setup: msg.sender, transient reset, depth tracking
          let prevSender: string | undefined;
          if (!isInternal) {
            const isTopLevel = Contract._callDepth === 0;
            Contract._callDepth++;
            if (isTopLevel) {
              Contract._resetAllTransient();
            }
            prevSender = target._msg.sender;
            target._msg.sender = Contract._currentCaller;
            Contract._currentCaller = self._contractAddress;
            Contract._currentCallerName = self.constructor.name;
          }

          try {
            const result = value.apply(proxy, callArgs);
            if (entry) entry.returnValue = result;
            return result;
          } finally {
            if (!isInternal) {
              target._msg.sender = prevSender!;
              Contract._currentCaller = preCallCaller;
              Contract._currentCallerName = preCallCallerName;
              Contract._callDepth--;
            }
            if (entry) {
              Contract._callStack.pop();
              // Attach to parent's children, or push to top-level log if root
              const parent = Contract._callStack[Contract._callStack.length - 1];
              if (parent) {
                parent.children.push(entry);
              } else {
                Contract._turnCallLog!.push(entry);
              }
            }
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
    if (typeof key === 'string') return key;
    // bigint keys (e.g. Solady's magic _OWNER_SLOT constants) would otherwise
    // crash JSON.stringify. Canonicalize to 0x-prefixed hex so that identical
    // slot values always produce the same string key regardless of source.
    if (typeof key === 'bigint') return '0x' + key.toString(16);
    return JSON.stringify(key);
  }

  protected _storageRead(key: any): bigint {
    return this._storage.sload(this._yulStorageKey(key));
  }

  protected _storageWrite(key: any, value: bigint): void {
    this._storage.sstore(this._yulStorageKey(key), value);
  }
}
