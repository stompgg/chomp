/**
 * Shared test mocks and utilities for transpiler tests.
 */

// =============================================================================
// ADDRESS GENERATION
// =============================================================================

let addressCounter = 1;

export function resetAddressCounter(): void {
  addressCounter = 1;
}

export function generateAddress(): string {
  return `0x${(addressCounter++).toString(16).padStart(40, '0')}`;
}

export function setAddress(instance: any): string {
  const addr = generateAddress();
  instance._contractAddress = addr;
  return addr;
}

// =============================================================================
// MOCK CONTRACTS
// =============================================================================

export class MockValidator {
  _contractAddress: string;
  constructor() { this._contractAddress = generateAddress(); }
  validateGameStart(): boolean { return true; }
  validateTeamSize(): bigint[] { return [1n, 6n]; }
  validateSwitch(): boolean { return true; }
  validateSpecificMoveSelection(): boolean { return true; }
  validateTimeout(): string { return '0x0000000000000000000000000000000000000000'; }
  validatePlayerMove(): boolean { return true; }
}

export class MockRuleset {
  _contractAddress = '0x0000000000000000000000000000000000000000';
  getInitialGlobalEffects(): [any[], string[]] { return [[], []]; }
}

export class MockRNGOracle {
  _contractAddress: string;
  private seed: bigint;
  constructor(seed: bigint = 12345n) {
    this._contractAddress = generateAddress();
    this.seed = seed;
  }
  getRNG(): bigint {
    this.seed = (this.seed * 1103515245n + 12345n) % (2n ** 256n);
    return this.seed;
  }
}

export class MockMatchmaker {
  _contractAddress: string;
  constructor() { this._contractAddress = generateAddress(); }
  validateMatch(): boolean { return true; }
}
