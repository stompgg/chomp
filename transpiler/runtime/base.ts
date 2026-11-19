/**
 * Base Contract class and core utilities
 *
 * This file is separate from index.ts to avoid circular dependencies
 * with runtime replacement modules like Ownable, etc.
 *
 * ALL contract classes must extend this Contract — there is only one.
 * index.ts re-exports it; it does NOT define a second Contract class.
 */

import {
  keccak256 as viemKeccak256,
  encodePacked as viemEncodePacked,
  encodeAbiParameters as viemEncodeAbiParameters,
  decodeAbiParameters as viemDecodeAbiParameters,
  toHex,
  hexToBigInt,
} from 'viem';

/** Memoized keccak256 for hex inputs — sim keys (effect ids, mapping slots) repeat massively. */
const KECCAK_CACHE = new Map<string, `0x${string}`>();
export function keccak256(value: `0x${string}` | Uint8Array): `0x${string}` {
  if (typeof value !== 'string') return viemKeccak256(value);
  let h = KECCAK_CACHE.get(value);
  if (h === undefined) {
    if (KECCAK_CACHE.size > 10_000) KECCAK_CACHE.clear();
    h = viemKeccak256(value);
    KECCAK_CACHE.set(value, h);
  }
  return h;
}

// =============================================================================
// INTERNED MAPPING KEYS
// =============================================================================
// Mapping keys transpile to `String(bigintIdx)` — an allocation per access. Indices are
// tiny (mon/slot/effect ids), so a 256-entry table returns the same string alloc-free.

const IK_TABLE: string[] = Array.from({ length: 256 }, (_, i) => String(i));

export function __ik(v: bigint | number): string {
  const n = Number(v);
  return n >= 0 && n < 256 ? IK_TABLE[n] : String(v);
}

// =============================================================================
// LAZY RECORDS (Solidity mappings)
// =============================================================================
// An unwritten mapping key reads as the value type's zero. The record is a plain object whose
// PROTOTYPE is a proxy: only a miss reaches the trap, which materializes the default as an own
// property — every later read of that key is an ordinary property load.

function lazyProto(make: () => unknown): object {
  return new Proxy({}, {
    get(t, k, receiver) {
      // Symbols and Object.prototype names (constructor, toString, …) are never mapping keys.
      if (typeof k !== 'string' || k in t) return Reflect.get(t, k, receiver);
      const v = make();
      Object.defineProperty(receiver, k, { value: v, writable: true, enumerable: true, configurable: true });
      return v;
    },
  });
}

// One prototype per default: a stable factory (`createDefaultFoo`) or a primitive zero.
const LAZY_PROTO_BY_FACTORY = new WeakMap<Function, object>();
const LAZY_PROTO_BY_ZERO = new Map<unknown, object>();

/** Mapping whose missing keys materialize `make()`. `make` must be a stable reference. */
export function __lazyRecord<T>(make: () => T): Record<string, T> {
  let proto = LAZY_PROTO_BY_FACTORY.get(make);
  if (proto === undefined) {
    proto = lazyProto(make);
    LAZY_PROTO_BY_FACTORY.set(make, proto);
  }
  return Object.create(proto);
}

/** Mapping whose missing keys materialize the primitive `zero` (0n, false, a zero hex word). */
export function __lazyZeroRecord<T>(zero: T): Record<string, T> {
  let proto = LAZY_PROTO_BY_ZERO.get(zero);
  if (proto === undefined) {
    proto = lazyProto(() => zero);
    LAZY_PROTO_BY_ZERO.set(zero, proto);
  }
  return Object.create(proto);
}

/** Mapping whose default is built by an inline closure (nested mappings): no sharing. */
export function __lazyRecordOf<T>(make: () => T): Record<string, T> {
  return Object.create(lazyProto(make));
}

// =============================================================================
// FAST ABI ENCODERS
// =============================================================================
// Byte-identical fast paths for the static shapes the generated code hot loops emit
// (uintN / intN / bool / already-lowercase bytes32 & address). Anything else — dynamic
// types, mixed-case hex, unexpected value kinds — falls back to viem wholesale.

const UINT_RE = /^u?int(\d*)$/;
const HEX32_RE = /^0x[0-9a-f]{64}$/;
const ADDR_RE = /^0x[0-9a-f]{40}$/;

// Type string → uint/int bit width, or -1 for non-numeric types. The type vocabulary the
// transpiler emits is a tiny fixed set, so this replaces a regex exec per element.
const UINT_WIDTH = new Map<string, number>();
function uintWidth(t: string): number {
  let w = UINT_WIDTH.get(t);
  if (w === undefined) {
    const m = UINT_RE.exec(t);
    w = m === null ? -1 : m[1] === '' ? 256 : Number(m[1]);
    UINT_WIDTH.set(t, w);
  }
  return w;
}

// Effect-hook payloads are overwhelmingly small non-negative words (player/mon indices, enum
// ordinals, small deltas), and each one otherwise pays BigInt boxing + toString + padStart. A
// table of the first 256 encoded 256-bit words answers those without allocating.
const PAD256_SMALL: string[] = Array.from({ length: 256 }, (_, i) =>
  i.toString(16).padStart(64, '0'),
);

/** `v` as a two's-complement `bits`-wide unpadded hex string. */
function padUint(v: bigint | number, bits: number): string {
  if (bits === 256 && v >= 0 && v < 256) {
    const n = Number(v);
    if (Number.isInteger(n)) return PAD256_SMALL[n];
  }
  return BigInt.asUintN(bits, BigInt(v)).toString(16).padStart(bits >> 2, '0');
}

export function encodePacked(types: readonly string[], values: readonly unknown[]): `0x${string}` {
  let out = '0x';
  for (let i = 0; i < types.length; i++) {
    const t = types[i];
    const v = values[i];
    const bits = uintWidth(t);
    if (bits > 0 && (typeof v === 'bigint' || typeof v === 'number')) {
      out += padUint(v, bits);
    } else if (t === 'bytes32' && typeof v === 'string' && HEX32_RE.test(v)) {
      out += v.slice(2);
    } else if (t === 'address' && typeof v === 'string' && ADDR_RE.test(v)) {
      out += v.slice(2);
    } else if (t === 'bool') {
      out += v ? '01' : '00';
    } else {
      return viemEncodePacked(types as never, values as never);
    }
  }
  return out as `0x${string}`;
}

export function encodeAbiParameters(params: unknown, values: readonly unknown[]): `0x${string}` {
  if (!Array.isArray(params)) return viemEncodeAbiParameters(params as never, values as never) as `0x${string}`;
  let out = '0x';
  for (let i = 0; i < params.length; i++) {
    const t = (params[i] as { type?: string })?.type ?? '';
    const v = values[i];
    if (uintWidth(t) > 0 && (typeof v === 'bigint' || typeof v === 'number')) {
      out += padUint(v, 256);
    } else if (t === 'bytes32' && typeof v === 'string' && HEX32_RE.test(v)) {
      out += v.slice(2);
    } else if (t === 'address' && typeof v === 'string' && ADDR_RE.test(v)) {
      out += v.slice(2).padStart(64, '0');
    } else if (t === 'bool') {
      out += v ? PAD256_SMALL[1] : PAD256_SMALL[0];
    } else if (t === 'string' && typeof v === 'string') {
      return encodeWithStrings(params, values);
    } else {
      return viemEncodeAbiParameters(params as never, values as never) as `0x${string}`;
    }
  }
  return out as `0x${string}`;
}

// Tail (length word + right-padded utf8) of a dynamic `string`, keyed by value: the generated
// code only encodes a handful of constant tags ("SLOT_ACTION", "EFFECT", …).
const STRING_TAIL = new Map<string, string>();
function stringTail(v: string): string {
  let tail = STRING_TAIL.get(v);
  if (tail === undefined) {
    const bytes = new TextEncoder().encode(v);
    let hex = '';
    for (let i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, '0');
    tail = padUint(bytes.length, 256) + hex.padEnd(Math.ceil(bytes.length / 32) * 64, '0');
    if (STRING_TAIL.size > 1_000) STRING_TAIL.clear();
    STRING_TAIL.set(v, tail);
  }
  return tail;
}

/** Head/tail form of `encodeAbiParameters` for static words mixed with `string` params. */
function encodeWithStrings(params: readonly unknown[], values: readonly unknown[]): `0x${string}` {
  const headBytes = params.length * 32;
  let head = '';
  let tail = '';
  for (let i = 0; i < params.length; i++) {
    const t = (params[i] as { type?: string })?.type ?? '';
    const v = values[i];
    if (t === 'string' && typeof v === 'string') {
      head += padUint(headBytes + (tail.length >> 1), 256);
      tail += stringTail(v);
    } else if (uintWidth(t) > 0 && (typeof v === 'bigint' || typeof v === 'number')) {
      head += padUint(v, 256);
    } else if (t === 'bytes32' && typeof v === 'string' && HEX32_RE.test(v)) {
      head += v.slice(2);
    } else if (t === 'address' && typeof v === 'string' && ADDR_RE.test(v)) {
      head += v.slice(2).padStart(64, '0');
    } else if (t === 'bool') {
      head += v ? PAD256_SMALL[1] : PAD256_SMALL[0];
    } else {
      return viemEncodeAbiParameters(params as never, values as never) as `0x${string}`;
    }
  }
  return ('0x' + head + tail) as `0x${string}`;
}

const ZEROS52 = '0'.repeat(52);
const TWO_256 = 1n << 256n;
const MAX_INT256 = (1n << 255n) - 1n;

/**
 * `decodeAbiParameters` for payloads that are exactly one word per uintN / intN param (the
 * effect-hook extraData shapes); anything else goes to viem. Mirrors viem's result types:
 * widths ≤ 48 bits decode to `number`, wider to `bigint`, signed as 256-bit two's complement.
 */
export function decodeAbiParameters(params: unknown, data: `0x${string}`): any {
  if (Array.isArray(params) && typeof data === 'string' && data.length === 2 + 64 * params.length) {
    const out: unknown[] = new Array(params.length);
    let i = 0;
    for (; i < params.length; i++) {
      const t = (params[i] as { type?: string })?.type ?? '';
      const bits = uintWidth(t);
      if (bits <= 0) break;
      const at = 2 + 64 * i;
      if (data.startsWith(ZEROS52, at)) {
        // Top 208 bits clear → the value fits 48 bits: exact as a double, never negative.
        const n = parseInt(data.slice(at + 52, at + 64), 16);
        if (n !== n) break;
        out[i] = bits > 48 ? BigInt(n) : n;
      } else {
        let v: bigint;
        try {
          v = BigInt('0x' + data.slice(at, at + 64));
        } catch {
          break;
        }
        if (t.charCodeAt(0) === 105 /* i: intN */ && v > MAX_INT256) v -= TWO_256;
        out[i] = bits > 48 ? v : Number(v);
      }
    }
    if (i === params.length) return out;
  }
  return viemDecodeAbiParameters(params as never, data as never);
}

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
  /** Positional names for `args`, resolved at record time from the target class's
   *  __argNames static. Absent when the class carries no metadata for the method. */
  argNames?: readonly string[];
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
// AMBIENT EXECUTION CONTEXT
// =============================================================================
// The address registry + transient-instance list are global: the contracts they
// hold (moves/effects/abilities) are stateless and engine-agnostic — the Engine
// threads itself into every call

/** Write-only side-channel; the semantics path must never branch on an Observer. */
export interface Observer {
  /** Declare interest in internal (`_`-prefixed) methods; externals are always captured. */
  captures?(method: string): boolean;
  /** Fires once per captured ROOT call, fully populated (sub-calls hang off `children`). */
  onCall?(entry: CallEntry): void;
  /** A tracked mutation outside any captured call (in-call ones attach to the entry). */
  onStateChange?(change: StateChangeEntry): void;
}

interface CallFrame {
  address: string;  // load-bearing: drives msg.sender derivation
  name: string;     // observation only
}

/** Scoped to one execution (≈ one transaction). */
export interface CallContext {
  /** top = the currently-EXECUTING contract; its caller (msg.sender) is the frame below. */
  callerStack: CallFrame[];
  /** 0→1 = transaction boundary → reset all transient storage. */
  callDepth: number;
  /** pure side-channel; never read by the semantics path. */
  observers: Observer[];
  /** innermost open entry receives state changes; emptied per transaction. */
  entryStack: CallEntry[];
}

let currentCall: CallContext = { callerStack: [], callDepth: 0, observers: [], entryStack: [] };

// address → contract instance, for Contract.at() lookups.
const _addressRegistry = new Map<string, Contract>();
// uint160-word → registered instance, for the packed move/ability/effect slots the engine
// resolves every action. Dropped whole on any registry mutation; stubs are never cached.
const _atByWord = new Map<bigint, Contract>();
// Contracts with transient storage, reset at each transaction boundary.
let _transientInstances: Contract[] = [];

/** Reset transient storage on every transient-bearing instance (at depth 0→1). */
function resetAllTransient(): void {
  for (const instance of _transientInstances) {
    (instance as any)._resetTransient();
  }
}

/**
 * Establish a transaction: push `sender` as the bottom frame and cross depth 0→1
 * (transient reset). The seam that establishes execution context. `observers` scope
 * to this tx — thread one array across sequential txs (setMove, setMove, execute) to
 * accumulate all their roots.
 */
export function runAsTransaction<T>(
  sender: string,
  observers: Observer[],
  fn: () => T,
): T {
  const prevCall = currentCall;
  currentCall = {
    callerStack: [{ address: sender, name: 'External' }],
    callDepth: 0,
    observers,
    entryStack: [],
  };
  currentCall.callDepth++;            // 0→1 boundary
  resetAllTransient();
  try {
    return fn();
  } finally {
    currentCall = prevCall;
  }
}

/** Run `fn` without crossing a tx boundary, so transient state (tempRNG, buffered
 *  packed moves, write-context transients) survives. */
export function runNested<T>(fn: () => T): T {
  currentCall.callDepth++;            // stays > 0: no transient reset
  try {
    return fn();
  } finally {
    currentCall.callDepth--;
  }
}

/** `'_'` — the internal-method prefix, compared by code point rather than `startsWith`. */
const UNDERSCORE = 95;

/** True if any attached observer wants to capture this internal method. */
function _captureInternal(method: string): boolean {
  const obs = currentCall.observers;
  for (let i = 0; i < obs.length; i++) {
    if (obs[i].captures?.(method)) return true;
  }
  return false;
}

/** Standard call-tree observer: accumulates root CallEntries + orphan state
 *  changes. Caller supplies the internal-method subscription set. */
export class CallTreeObserver implements Observer {
  readonly roots: CallEntry[] = [];
  readonly orphanStateChanges: StateChangeEntry[] = [];

  constructor(private readonly captured: ReadonlySet<string>) {}

  captures(method: string): boolean {
    return this.captured.has(method);
  }

  onCall(entry: CallEntry): void {
    this.roots.push(entry);
  }

  onStateChange(change: StateChangeEntry): void {
    this.orphanStateChanges.push(change);
  }
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
 * Record a state change. Attaches to the innermost open call entry if one
 * exists; otherwise offers it to observers as an orphan change.
 */
function _recordStateChange(change: StateChangeEntry): void {
  const stack = currentCall.entryStack;
  const top = stack[stack.length - 1];
  if (top) {
    top.stateChanges.push(change);
    return;
  }
  const obs = currentCall.observers;
  for (let i = 0; i < obs.length; i++) {
    obs[i].onStateChange?.(change);
  }
}

/**
 * Wrap an object in a recursive Proxy that records property writes via
 * _recordStateChange (to the innermost open call entry, or to observers as an
 * orphan). Used for nested state (structs, arrays) accessed through a contract's
 * __stateVars properties.
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
      // Recursively wrap nested objects (structs, arrays) for deep tracking,
      // gated on the same single signal as entry creation: an observer is attached.
      if (value !== null && typeof value === 'object'
          && currentCall.observers.length > 0) {
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
  /** Mutable storage variable names — overridden per contract by the transpiler.
   *  Used by the state-change tracking proxy to filter which property writes to log. */
  static readonly __stateVars: Set<string> = new Set();

  /** Per-method positional argument names — overridden per contract by the
   *  transpiler. Lets consumers (e.g. battle-action-mapper) read CallEntry.args
   *  by name instead of by index, so engine arg reorders surface as compile
   *  errors at call sites. */
  static readonly __argNames: Readonly<Record<string, readonly string[]>> = {};

  /** Contract class name — overridden per contract by the transpiler (used for
   *  address→class resolution). Declared here so the per-contract `override` is valid. */
  static readonly __className: string = '';

  // =========================================================================
  // ADDRESS RESOLUTION
  // =========================================================================

  /**
   * Resolve a value (contract object, uint256/string address) to a contract
   * instance via the global registry. Unregistered addresses return a stub
   * carrying only _contractAddress (sentinels/tombstones used for identity).
   */
  static at(value: any): any {
    if (value && typeof value === 'object' && '_contractAddress' in value) {
      return value;
    }
    let address: string;
    if (typeof value === 'bigint') {
      const hit = _atByWord.get(value);
      if (hit !== undefined) return hit;
      address = bigintToAddress(value);
    } else if (typeof value === 'string') {
      address = value;
    } else {
      throw new Error(`Contract.at: cannot resolve ${typeof value}`);
    }
    const normalized = address.toLowerCase();
    const instance = _addressRegistry.get(normalized);
    if (instance) {
      if (typeof value === 'bigint') {
        if (_atByWord.size > 4_096) _atByWord.clear();
        _atByWord.set(value, instance);
      }
      return instance;
    }
    // Return a lightweight stub for unregistered addresses (e.g. sentinel/tombstone).
    // Only _contractAddress is set — calling methods on it will fail, which is correct
    // since these addresses are only used for identity comparisons.
    return { _contractAddress: normalized };
  }

  /** Clear the registry + transient-instance tracking (between battles/tests). */
  static clearRegistry(): void {
    _addressRegistry.clear();
    _atByWord.clear();
    _transientInstances = [];
    currentCall = { callerStack: [], callDepth: 0, observers: [], entryStack: [] };
  }

  // Storage for this contract instance
  protected _storage: Storage = new Storage();

  // Event stream - shared across all contracts for a transaction
  protected _eventStream: EventStream = globalEventStream;

  /**
   * Contract address for address(this) pattern.
   * Setting this auto-registers the instance in the global address registry.
   */
  private _address: string = ADDRESS_ZERO;
  /** The Proxy wrapping this instance (set by constructor). Generated code emits `this._proxy`
   *  wherever Solidity lets `this` escape as a value, since methods may run on the raw instance. */
  protected _proxy: any = null;

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
      const current = _addressRegistry.get(prevLower);
      if (current === (this._proxy ?? this) || current === this) {
        _addressRegistry.delete(prevLower);
        _atByWord.clear();
      }
    }
    if (addr !== ADDRESS_ZERO) {
      // Register the Proxy (not the raw instance) so Contract.at() returns
      // the msg.sender-propagating wrapper
      _addressRegistry.set(addr.toLowerCase(), (this._proxy ?? this) as Contract);
      _atByWord.clear();
    }
  }

  // msg.sender DERIVED, not stored: the immediate caller is the frame below the
  // executing contract (callerStack top), i.e. at(-2). value/data unused. No stored
  // _msg → can't desync from the stack.
  get _msg(): { sender: string; value: bigint; data: `0x${string}` } {
    const stack = currentCall.callerStack;
    const sender = stack[stack.length - 2]?.address ?? ADDRESS_ZERO;
    return { sender, value: 0n, data: '0x' as `0x${string}` };
  }

  // Block context (per-instance; the harness advances the engine's clock per turn).
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
    // registry with stale auto-generated entries.
    if (typeof args[0] === 'string') {
      this._contractAddress = args[0];
    }

    // Register for transient reset. Done before proxy wrapping so we store the raw
    // instance (resetAllTransient calls _resetTransient directly).
    if (typeof (this as any)._resetTransient === 'function') {
      _transientInstances.push(this);
    }

    // Wrap instance in a Proxy that propagates msg.sender on cross-contract calls.
    // In Solidity, when contract A calls contract B, msg.sender in B = A's address.
    // Internal calls (same contract) don't change msg.sender.
    // The proxy also tracks call depth to auto-reset transient storage at transaction
    // boundaries (depth 0→1), matching Solidity's per-transaction semantics.
    const self = this;
    // Mangle-stable identity for everything the observation layer records:
    // __className survives production minification; constructor.name does not.
    const className = (self.constructor as any).__className || self.constructor.name;
    // Each class's __argNames static covers only its OWN declared methods (the
    // override shadows the base's) — inherited methods resolve by walking up.
    const argNamesOf = (method: string): readonly string[] | undefined => {
      for (let c: any = self.constructor; c; c = Object.getPrototypeOf(c)) {
        if (Object.prototype.hasOwnProperty.call(c, '__argNames')) {
          const names = (c.__argNames as Readonly<Record<string, readonly string[]>>)[method];
          if (names) return names;
        }
      }
      return undefined;
    };
    // Method wrappers close over (propStr, value, self, className) — all stable for a given
    // prop, so they are made once instead of per access. `fn` guards the entry against a method
    // being swapped on the instance (the CPU search shims `_freeStorageKey` this way).
    const wrapCache = new Map<string, { fn: Function; wrapped: Function }>();
    // Unobserved `_` methods entered through the proxy: same caching, but no call semantics.
    const directCache = new Map<string, { fn: Function; direct: Function }>();
    // The frame this contract pushes as callee; rebuilt only when its address changes.
    let ownFrame: CallFrame = { address: ADDRESS_ZERO, name: className };
    const proxy = new Proxy(this, {
      // Ensure property writes through the proxy go to the target (not the proxy object).
      // This is critical because external calls use `this = proxy` inside methods,
      // so `this.field = x` must write to the target's storage.
      // Also records state variable mutations to the innermost open call entry,
      // gated on the single observation signal (an observer is attached).
      set(target, prop, value, receiver) {
        if (typeof prop !== 'symbol' && currentCall.observers.length > 0) {
          const stateVars = (self.constructor as any).__stateVars as Set<string> | undefined;
          if (stateVars?.has(prop as string)) {
            const oldValue = Reflect.get(target, prop, target);
            if (oldValue !== value) {
              _recordStateChange({
                contractName: className,
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
        // The hottest read on a contract reference (identity compares, address packing).
        if (prop === '_contractAddress') return self._address;
        // One read of the observation signal serves every branch below — this trap is the
        // hottest path in a forked search, where nothing is ever attached.
        const observed = currentCall.observers.length > 0;
        // Unobserved, the only accessor (`_msg`) is receiver-independent, so skip Reflect.get.
        const value = observed ? Reflect.get(target, prop, receiver) : (target as any)[prop];
        if (typeof prop === 'symbol') return value;
        if (typeof value !== 'function') {
          // State variable objects only need the deep tracking proxy while an observer is attached.
          if (observed && value !== null && typeof value === 'object') {
            const stateVars = (self.constructor as any).__stateVars as Set<string> | undefined;
            if (stateVars?.has(prop as string)) {
              return _wrapForStateTracking(value, className, prop as string);
            }
          }
          return value;
        }
        const propStr = prop as string;

        // Internal/library (`_`) methods never change msg.sender or depth, so they
        // only need the wrapper when an observer wants to capture them; else fast-path
        // the raw fn (the historical no-wrap path).
        const isUnderscore = propStr.charCodeAt(0) === UNDERSCORE;
        if (isUnderscore) {
          if (observed) {
            if (!_captureInternal(propStr)) return value;
          } else {
            // Nothing can observe this call, so run it on the raw instance: every `this.x` below
            // it then skips this trap. Receiver is picked at call time in case the fn is held.
            const d = directCache.get(propStr);
            if (d !== undefined && d.fn === value) return d.direct;
            const direct = function (this: any, ...callArgs: any[]) {
              return value.apply(currentCall.observers.length > 0 ? proxy : self, callArgs);
            };
            directCache.set(propStr, { fn: value, direct });
            return direct;
          }
        }

        const cached = wrapCache.get(propStr);
        if (cached !== undefined && cached.fn === value) return cached.wrapped;

        const wrapped = function (this: any, ...callArgs: any[]) {
          const call = currentCall;

          // ── SEMANTICS ── a function of call *type* only, identical with or without
          // observers. Stack top = executing contract; a self-call or any `_` method
          // preserves msg.sender → internal.
          const stack = call.callerStack;
          const topFrame = stack[stack.length - 1];
          const address = self._address;
          const isInternal = isUnderscore || (topFrame !== undefined && topFrame.address === address);

          const preDepth = call.callDepth;
          if (!isInternal) {
            if (ownFrame.address !== address) ownFrame = { address, name: className };
            stack.push(ownFrame);
            if (++call.callDepth === 1) resetAllTransient();
          }

          // ── OBSERVATION ── the ONLY code that reads call.observers. It builds the
          // call tree but can never feed back into the semantics above.
          let entry: CallEntry | null = null;
          let isRootEntry = false;
          if (call.observers.length > 0) {
            entry = {
              caller: topFrame?.address ?? ADDRESS_ZERO,
              callerName: topFrame?.name ?? 'External',
              target: address,
              targetName: className,
              method: propStr,
              args: callArgs,
              argNames: argNamesOf(propStr),
              depth: preDepth + (isInternal ? 0 : 1),
              internal: isInternal,
              children: [],
              stateChanges: [],
            };
            const parent = call.entryStack[call.entryStack.length - 1];
            if (parent) parent.children.push(entry);
            else isRootEntry = true;
            call.entryStack.push(entry);
          }

          try {
            // Observed calls keep the proxy as `this` (state tracking + internal capture ride
            // its traps); unobserved ones run on the raw instance and never re-enter the traps.
            const result = value.apply(entry !== null ? proxy : self, callArgs);
            if (entry) entry.returnValue = result;
            return result;
          } finally {
            if (!isInternal) {
              call.callDepth--;
              stack.pop();
            }
            if (entry) {
              call.entryStack.pop();
              // Root entries (children already linked) are offered to observers.
              if (isRootEntry) {
                for (let i = 0; i < call.observers.length; i++) {
                  call.observers[i].onCall?.(entry);
                }
              }
            }
          }
        };
        wrapCache.set(propStr, { fn: value, wrapped });
        return wrapped;
      },
    });
    this._proxy = proxy;
    return proxy as this;
  }

  // =========================================================================
  // CONTEXT SETTERS
  // =========================================================================

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
    if (key !== null && typeof key === 'object') return (key as any)[YUL_SLOT_WORD] ?? 0n;
    return this._storage.sload(this._yulStorageKey(key));
  }

  protected _storageWrite(key: any, value: bigint): void {
    if (key !== null && typeof key === 'object') {
      (key as any)[YUL_SLOT_WORD] = value;
      return;
    }
    this._storage.sstore(this._yulStorageKey(key), value);
  }

  /**
   * Fork support: `dst` is a structural clone of `src`, but the word is symbol-keyed so
   * `Object.keys` cloning drops it — without this, a fork's struct reads a ZERO packed word
   * (lost effect compact data / monState top bits). Copy it onto the clone: reads agree,
   * writes stay isolated from the live battle.
   */
  cloneYulSlotWord(src: any, dst: any): void {
    if (src === null || typeof src !== 'object' || dst === null || typeof dst !== 'object') return;
    const w = (src as any)[YUL_SLOT_WORD];
    if (w !== undefined && w !== 0n) (dst as any)[YUL_SLOT_WORD] = w;
    // A pooled/reused dst may carry a stale word from its previous life — reads treat 0n as
    // absent, so zeroing (not deleting) keeps the clone faithful without a shape change.
    else if ((dst as any)[YUL_SLOT_WORD] !== undefined) (dst as any)[YUL_SLOT_WORD] = 0n;
  }
}

/** Key for the yul slot word — a symbol, so it can't collide with a field name. */
const YUL_SLOT_WORD = Symbol('yulSlotWord');
