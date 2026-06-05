/**
 * ECDSA - secp256k1 signature recovery (Solady pattern).
 *
 * Real recovery uses Yul assembly around the `ecrecover` precompile. Like the
 * runtime's `ecrecover` (which throws rather than returning a fabricated signer),
 * recovery is not modeled in local simulation: the only caller is the built-in
 * dual-signed buffer flow (`Engine.submitTurnMoves`), an on-chain-only feature
 * that local battle simulation never exercises. `recoverCalldata` therefore
 * throws loudly instead of returning a plausible-but-wrong address.
 *
 * Transpiled library calls keep static syntax (`ECDSA.recoverCalldata(...)`),
 * matching `runtime_replacement_classes` handling in the codegen; `eCDSA` is
 * exported as an alias so the lowercase-singleton convention also resolves.
 *
 * @see transpiler/transpiler-config.json -> runtimeReplacements
 */

export class ECDSA {
  /** Solidity `recoverCalldata(hash, signature)` — not modeled in simulation. */
  static recoverCalldata(_hash: string, _signature: string): string {
    throw new Error(
      'ECDSA.recoverCalldata called — secp256k1 recovery is not modeled in local ' +
      'simulation (matching the runtime ecrecover convention). The only caller is the ' +
      'on-chain-only dual-signed buffer flow (submitTurnMoves).',
    );
  }

  /**
   * Solidity `recover(...)` — not modeled in simulation. Variadic to cover all
   * Solady overloads: `recover(hash, signature)`, `recover(hash, r, vs)` (compact),
   * and `recover(hash, v, r, s)`.
   */
  static recover(_hash: string, ..._sig: string[]): string {
    return ECDSA.recoverCalldata(_hash, _sig.join(''));
  }
}

/** Lowercase-singleton alias so `eCDSA.recoverCalldata(...)` resolves to the static API. */
export const eCDSA = ECDSA;
