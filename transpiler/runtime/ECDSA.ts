/**
 * ECDSA - runtime stand-in for Solady's (Yul-assembly) secp256k1 recovery. Like the runtime
 * `ecrecover`, recovery isn't modeled in local sim: the only caller is the on-chain-only dual-signed
 * buffer flow (submitTurnMoves), so `recoverCalldata` throws rather than return a wrong signer. Calls
 * keep static syntax (`ECDSA.recoverCalldata(...)`); `eCDSA` is an alias for the lowercase convention.
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
