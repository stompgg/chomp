/**
 * Seeded RNG + salt — verbatim from munch's sim harness so the team draws, battle rng, and per-turn
 * salt values reproduce munch's stream exactly (identical seed => identical salts => identical battle RNG).
 */
export function makeRng(seed: number): () => number {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function randomSalt(rng: () => number): bigint {
  // 26 hex nibbles -> uint104, matching SignedCommitLib / MonMoves packing.
  let s = '0x';
  for (let i = 0; i < 26; i++) s += Math.floor(rng() * 16).toString(16);
  return BigInt(s);
}
