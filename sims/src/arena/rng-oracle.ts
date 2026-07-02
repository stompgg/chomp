import { encodeAbiParameters, keccak256 } from 'viem';

/**
 * Memoized drop-in for the engine's inline (zero-oracle) RNG.
 *
 * When `config.rngOracle` is the zero address the engine derives each turn's rng inline as
 * `keccak256(abi.encode(uint104 p0Salt, uint104 p1Salt))` (Engine.ts). The forward model replays ~10
 * candidate turns per real turn, and in the arena those forks use CONSTANT salts (plain greedy passes
 * `0n`), so the identical `(source0, source1)` pair recurs every fork — yet the inline path re-runs the
 * full keccak + ABI-encode + hex round-trip each time (~15% of arena CPU per the profile).
 *
 * Installing this as a NON-zero `rngOracle` routes the engine through `getRNG` instead, which reproduces
 * the inline formula EXACTLY (same uint104 masking, same keccak) but caches on the salt pair. Repeated
 * fork salts become cache hits; real turns draw fresh 104-bit salts (misses) and compute the identical
 * value — so battle outcomes are byte-identical to the inline path.
 *
 * Must be a CLASS instance, not a plain object: the fork's `cloneState` deep-copies plain objects but
 * shares class instances by reference, so a plain-object oracle would be re-copied (and its cache lost)
 * on every fork. The cache is module-level so it stays warm across every game in a worker.
 */

// keccak256(abi.encode(uint104,uint104)) is a pure function of the salt pair, so one process-wide cache
// is valid for every battle/fork.
const rngCache = new Map<string, bigint>();
const MASK_104 = (1n << 104n) - 1n;

// Any non-zero address works — it only has to differ from the zero address so the engine takes the
// oracle branch rather than the inline branch.
const ORACLE_ADDRESS = '0x0000000000000000000000000000000000005a17';

export class MemoizedInlineRngOracle {
  _contractAddress = ORACLE_ADDRESS;

  getRNG(source0: string, source1: string): bigint {
    const key = source0 + source1;
    let v = rngCache.get(key);
    if (v === undefined) {
      const p0 = BigInt(source0) & MASK_104;
      const p1 = BigInt(source1) & MASK_104;
      v = BigInt(keccak256(encodeAbiParameters([{ type: 'uint104' }, { type: 'uint104' }], [p0, p1])));
      rngCache.set(key, v);
    }
    return v;
  }
}
