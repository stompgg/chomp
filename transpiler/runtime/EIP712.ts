/**
 * EIP712 - runtime stand-in for the Solady (Yul-assembly) EIP-712 base. The only caller is the
 * built-in dual-signed buffer flow (submitTurnMoves), which is on-chain-only and never runs in local
 * simulation, so `_hashTypedData` throws rather than ship a subtly-wrong digest (matches `ecrecover`).
 * Exists so `import { EIP712 } from './lib/EIP712'` resolves; the methods Engine uses are spliced in
 * via the `mixin` field of this file's transpiler-config.json runtimeReplacements entry.
 */

import { Contract } from './base';

export abstract class EIP712 extends Contract {
  /** Subclasses return `[name, version]` for the EIP-712 domain. */
  protected abstract _domainNameAndVersion(): [string, string];

  /**
   * Solidity `_hashTypedData(structHash)` — not modeled in simulation.
   *
   * See the file header: the dual-signed buffer flow is on-chain only.
   */
  protected _hashTypedData(_structHash: string): string {
    throw new Error(
      'EIP712._hashTypedData called — the built-in dual-signed buffer flow ' +
      '(submitTurnMoves) is an on-chain-only feature and is not modeled in local simulation.',
    );
  }
}
