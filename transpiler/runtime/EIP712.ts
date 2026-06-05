/**
 * EIP712 - EIP-712 typed-data domain separation and digest hashing (Solady pattern).
 *
 * The on-chain `EIP712` base builds the domain separator and the
 * `\x19\x01`-prefixed digest in Yul assembly. The only code path that reaches it
 * is the built-in dual-signed buffer flow (`Engine.submitTurnMoves` /
 * `submitTurnMovesAndExecute`), which is an on-chain-only feature — local battle
 * simulation drives `execute`/`executeWithMoves` directly and never stages signed
 * turns. So, matching the runtime `ecrecover` convention, `_hashTypedData` throws
 * loudly rather than shipping a subtly-wrong digest that would typecheck and
 * silently mislead.
 *
 * This class exists so `import { EIP712 } from './lib/EIP712'` resolves; the
 * methods Engine actually uses are spliced in via the `mixin` field of this
 * file's entry in transpiler-config.json.
 *
 * @see transpiler/transpiler-config.json -> runtimeReplacements
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
