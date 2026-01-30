/**
 * EIP712 - Typed structured data hashing and signing
 *
 * This is a TypeScript implementation of Solady's EIP712 pattern.
 * Provides domain separator computation and typed data hashing for EIP-712.
 *
 * @see transpiler/runtime-replacements.json for configuration
 */

import { keccak256, encodeAbiParameters, concat, toHex } from 'viem';
import { Contract, ADDRESS_ZERO } from './base';

// EIP-712 Domain Type Hash
// keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
const DOMAIN_TYPEHASH = '0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f' as `0x${string}`;

/**
 * Abstract base class for EIP-712 typed structured data hashing and signing.
 * Contracts that need EIP-712 functionality should extend this class and
 * implement _domainNameAndVersion().
 */
export abstract class EIP712 extends Contract {
  private _cachedNameHash: `0x${string}` = '0x0000000000000000000000000000000000000000000000000000000000000000';
  private _cachedVersionHash: `0x${string}` = '0x0000000000000000000000000000000000000000000000000000000000000000';
  private _cachedDomainSeparator: `0x${string}` = '0x0000000000000000000000000000000000000000000000000000000000000000';
  private _cachedChainId: bigint = 1n; // Default to mainnet for simulation

  constructor(address?: string) {
    super(address);
    this._initializeEIP712();
  }

  /**
   * Initialize the cached domain separator values
   */
  private _initializeEIP712(): void {
    const [name, version] = this._domainNameAndVersion();

    // Hash the name and version
    this._cachedNameHash = keccak256(
      encodeAbiParameters([{ type: 'string' }], [name])
    );
    this._cachedVersionHash = keccak256(
      encodeAbiParameters([{ type: 'string' }], [version])
    );

    // Build and cache the domain separator
    this._cachedDomainSeparator = this._buildDomainSeparator();
  }

  /**
   * Override this to return the domain name and version.
   * @returns Tuple of [name, version]
   */
  protected abstract _domainNameAndVersion(): [string, string];

  /**
   * Override this if the domain name and version may change after deployment.
   * Default: false
   */
  protected _domainNameAndVersionMayChange(): boolean {
    return false;
  }

  /**
   * Returns the EIP-712 domain separator.
   */
  protected _domainSeparator(): `0x${string}` {
    if (this._domainNameAndVersionMayChange()) {
      return this._buildDomainSeparator();
    }
    return this._cachedDomainSeparator;
  }

  /**
   * Returns the hash of the fully encoded EIP-712 message for this domain.
   * The hash can be used together with ECDSA.recover to obtain the signer.
   */
  protected _hashTypedData(structHash: `0x${string}` | string): `0x${string}` {
    const domainSeparator = this._domainSeparator();

    // EIP-712: "\x19\x01" ++ domainSeparator ++ structHash
    // The prefix \x19\x01 is used to prevent collision with eth_sign
    const encoded = concat([
      '0x1901' as `0x${string}`,
      domainSeparator,
      structHash as `0x${string}`
    ]);

    return keccak256(encoded);
  }

  /**
   * Build the domain separator from cached or computed values.
   */
  private _buildDomainSeparator(): `0x${string}` {
    let nameHash: `0x${string}`;
    let versionHash: `0x${string}`;

    if (this._domainNameAndVersionMayChange()) {
      const [name, version] = this._domainNameAndVersion();
      nameHash = keccak256(encodeAbiParameters([{ type: 'string' }], [name]));
      versionHash = keccak256(encodeAbiParameters([{ type: 'string' }], [version]));
    } else {
      nameHash = this._cachedNameHash;
      versionHash = this._cachedVersionHash;
    }

    // Domain separator = keccak256(abi.encode(DOMAIN_TYPEHASH, nameHash, versionHash, chainId, address(this)))
    const encoded = encodeAbiParameters(
      [
        { type: 'bytes32' },
        { type: 'bytes32' },
        { type: 'bytes32' },
        { type: 'uint256' },
        { type: 'address' }
      ],
      [
        DOMAIN_TYPEHASH,
        nameHash,
        versionHash,
        this._cachedChainId,
        this._contractAddress as `0x${string}`
      ]
    );

    return keccak256(encoded);
  }

  /**
   * Set the chain ID for domain separator calculation
   */
  setChainId(chainId: bigint): void {
    this._cachedChainId = chainId;
    // Rebuild domain separator with new chain ID
    if (!this._domainNameAndVersionMayChange()) {
      this._cachedDomainSeparator = this._buildDomainSeparator();
    }
  }

  /**
   * EIP-5267: Returns the domain information
   */
  eip712Domain(): {
    fields: string;
    name: string;
    version: string;
    chainId: bigint;
    verifyingContract: string;
    salt: string;
    extensions: bigint[];
  } {
    const [name, version] = this._domainNameAndVersion();
    return {
      fields: '0x0f', // `0b01111` - name, version, chainId, verifyingContract
      name,
      version,
      chainId: this._cachedChainId,
      verifyingContract: this._contractAddress,
      salt: '0x0000000000000000000000000000000000000000000000000000000000000000',
      extensions: []
    };
  }

  /**
   * Helper to hash typed data externally (for use by other contracts)
   * Note: Return type is string for compatibility with transpiled Solidity code
   */
  hashTypedData(structHash: `0x${string}` | string): string {
    return this._hashTypedData(structHash);
  }
}
