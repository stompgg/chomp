/**
 * Base Contract class and core utilities
 *
 * This file is separate from index.ts to avoid circular dependencies
 * with runtime replacement modules like Ownable, ECDSA, etc.
 */

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
   * Compute a mapping slot for a key.
   * In Solidity: keccak256(abi.encode(key, slot))
   */
  mappingSlot(key: bigint | string, baseSlot: bigint): string {
    // Simplified: just concatenate key and slot as strings
    // In real EVM, this would be keccak256(abi.encode(key, slot))
    return `${baseSlot.toString()}_${key.toString()}`;
  }

  /**
   * Compute a nested mapping slot.
   * In Solidity: keccak256(abi.encode(key2, keccak256(abi.encode(key1, slot))))
   */
  nestedMappingSlot(key1: bigint | string, key2: bigint | string, baseSlot: bigint): string {
    const innerSlot = this.mappingSlot(key1, baseSlot);
    return `${innerSlot}_${key2.toString()}`;
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

export interface EmittedEvent {
  name: string;
  args: Record<string, any>;
  emitter: string; // Contract address that emitted
  data?: any;      // Raw event data
}

/**
 * Captures events emitted during contract execution.
 * Unlike on-chain events, these are stored in memory for testing.
 */
export class EventStream {
  private events: EmittedEvent[] = [];

  emit(name: string, args: Record<string, any>, emitter: string = '', data?: any): void {
    this.events.push({ name, args, emitter, data });
  }

  getAll(): EmittedEvent[] {
    return [...this.events];
  }

  getByName(name: string): EmittedEvent[] {
    return this.events.filter(e => e.name === name);
  }

  getLast(name?: string): EmittedEvent | undefined {
    if (name) {
      const filtered = this.getByName(name);
      return filtered[filtered.length - 1];
    }
    return this.events[this.events.length - 1];
  }

  clear(): void {
    this.events = [];
  }

  get length(): number {
    return this.events.length;
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
// BASE CONTRACT CLASS
// =============================================================================

/**
 * Base class for all transpiled Solidity contracts.
 * Provides storage simulation, event emission, and context (msg, block, tx).
 */
export abstract class Contract {
  // Storage for this contract instance
  protected _storage: Storage = new Storage();

  // Event stream - shared across all contracts for a transaction
  protected _eventStream: EventStream = globalEventStream;

  // Contract's own address
  public _contractAddress: string;

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

  constructor(address?: string) {
    // Use provided address or auto-generate from class name
    this._contractAddress = address ?? contractAddresses.getAddress(this.constructor.name);
  }

  /**
   * Set the message context for this call
   */
  setMsgContext(sender: string, value: bigint = 0n, data: `0x${string}` = '0x'): void {
    this._msg = { sender, value, data };
  }

  /**
   * Set the block context
   */
  setBlockContext(timestamp: bigint, number: bigint): void {
    this._block = { timestamp, number };
  }

  /**
   * Set the transaction context
   */
  setTxContext(origin: string): void {
    this._tx = { origin };
  }

  /**
   * Emit an event
   */
  protected _emitEvent(name: string, ...args: any[]): void {
    // Convert args array to a more structured format
    const argsObj: Record<string, any> = {};
    args.forEach((arg, i) => {
      argsObj[`arg${i}`] = arg;
    });
    this._eventStream.emit(name, argsObj, this._contractAddress);
  }

  /**
   * Get storage slot value
   */
  protected _sload(slot: bigint | string): bigint {
    return this._storage.sload(slot);
  }

  /**
   * Set storage slot value
   */
  protected _sstore(slot: bigint | string, value: bigint): void {
    this._storage.sstore(slot, value);
  }

  /**
   * Get transient storage slot value
   */
  protected _tload(slot: bigint | string): bigint {
    return this._storage.tload(slot);
  }

  /**
   * Set transient storage slot value
   */
  protected _tstore(slot: bigint | string, value: bigint): void {
    this._storage.tstore(slot, value);
  }
}
