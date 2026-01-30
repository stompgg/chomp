/**
 * Ownable - Simple single owner authorization mixin
 *
 * This is a TypeScript implementation of Solady's Ownable pattern.
 * This implementation provides the same
 * interface with TypeScript-native semantics.
 *
 * @see transpiler/runtime-replacements.json for configuration
 */

import { Contract, ADDRESS_ZERO } from './base';

/**
 * Simple single owner authorization mixin.
 * Provides ownership functionality without complex Yul assembly.
 * Based on Solady's Ownable pattern.
 */
export abstract class Ownable extends Contract {
  private _owner: string = ADDRESS_ZERO;
  private _pendingOwnerExpiry: Map<string, bigint> = new Map();

  /**
   * Override to return true to make _initializeOwner prevent double-initialization
   */
  protected _guardInitializeOwner(): boolean {
    return false;
  }

  /**
   * Initializes the owner directly without authorization guard
   */
  protected _initializeOwner(newOwner: string): void {
    if (this._guardInitializeOwner() && this._owner !== ADDRESS_ZERO) {
      throw new Error("AlreadyInitialized");
    }
    this._owner = newOwner;
  }

  /**
   * Internal setter for owner
   */
  protected _setOwner(newOwner: string): void {
    const oldOwner = this._owner;
    this._owner = newOwner;
    this._emitEvent('OwnershipTransferred', { oldOwner, newOwner });
  }

  /**
   * Reverts if not called by owner
   */
  protected _checkOwner(): void {
    if (this._msg.sender !== this._owner) {
      throw new Error("Unauthorized");
    }
  }

  /**
   * Returns the validity duration for ownership handover
   */
  protected _ownershipHandoverValidFor(): bigint {
    return 48n * 3600n;
  }

  /**
   * Transfer ownership to a new owner
   */
  transferOwnership(newOwner: string): void {
    this._checkOwner();
    if (newOwner === ADDRESS_ZERO) {
      throw new Error("NewOwnerIsZeroAddress");
    }
    this._setOwner(newOwner);
  }

  /**
   * Renounce ownership (set owner to zero address)
   */
  renounceOwnership(): void {
    this._checkOwner();
    this._setOwner(ADDRESS_ZERO);
  }

  /**
   * Request ownership handover
   */
  requestOwnershipHandover(): void {
    const expires = this._block.timestamp + this._ownershipHandoverValidFor();
    this._pendingOwnerExpiry.set(this._msg.sender, expires);
    this._emitEvent('OwnershipHandoverRequested', { pendingOwner: this._msg.sender });
  }

  /**
   * Cancel ownership handover request
   */
  cancelOwnershipHandover(): void {
    this._pendingOwnerExpiry.delete(this._msg.sender);
    this._emitEvent('OwnershipHandoverCanceled', { pendingOwner: this._msg.sender });
  }

  /**
   * Complete ownership handover to pending owner
   */
  completeOwnershipHandover(pendingOwner: string): void {
    this._checkOwner();
    const expires = this._pendingOwnerExpiry.get(pendingOwner);
    if (!expires || this._block.timestamp > expires) {
      throw new Error("NoHandoverRequest");
    }
    this._pendingOwnerExpiry.delete(pendingOwner);
    this._setOwner(pendingOwner);
  }

  /**
   * Get current owner
   */
  owner(): string {
    return this._owner;
  }

  /**
   * Get expiry timestamp for pending owner's handover request
   */
  ownershipHandoverExpiresAt(pendingOwner: string): bigint {
    return this._pendingOwnerExpiry.get(pendingOwner) ?? 0n;
  }
}
