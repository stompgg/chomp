//! Seeded RNG + salt — port of `sims/src/arena/rng.ts` (mulberry32,
//! verbatim from munch). Same seed => bit-identical float stream => the
//! same team draws, tie-breaks and per-turn salts as the TS arena.

/// mulberry32. Mirrors the JS coercions exactly: all state math is u32
/// wrapping (JS `>>> 0` / `Math.imul`), the output is `u32 / 2^32` — both
/// steps exact in f64.
#[derive(Clone, Copy)]
pub struct JsRng {
    a: u32,
}

impl JsRng {
    pub fn new(seed: u32) -> Self {
        Self { a: seed }
    }

    pub fn next(&mut self) -> f64 {
        self.a = self.a.wrapping_add(0x6d2b79f5);
        let mut t = self.a;
        t = (t ^ (t >> 15)).wrapping_mul(t | 1);
        t ^= t.wrapping_add((t ^ (t >> 7)).wrapping_mul(t | 61));
        ((t ^ (t >> 14)) as f64) / 4294967296.0
    }
}

/// 26 hex nibbles -> uint104 (`randomSalt`). Each nibble is
/// `Math.floor(rng() * 16)` — exact in f64 (rng() = x / 2^32, so the
/// product is a dyadic rational well inside f64 precision).
pub fn random_salt(rng: &mut JsRng) -> u128 {
    let mut s: u128 = 0;
    for _ in 0..26 {
        s = (s << 4) | (rng.next() * 16.0).floor() as u128;
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    // Golden values from the TS reference (bun: makeRng(12345) — the first
    // three draws, and the salt drawn after one draw). Catches any
    // mulberry32 transcription slip without needing a full lockstep run.
    #[test]
    fn matches_ts_golden_stream() {
        let mut r = JsRng::new(12345);
        assert_eq!(r.next(), 0.97972826776094735);
        assert_eq!(r.next(), 0.30675226449966431);
        assert_eq!(r.next(), 0.48420542152598500);

        let mut r2 = JsRng::new(12345);
        r2.next();
        assert_eq!(random_salt(&mut r2), 5692147205139852277246476461845u128);
    }
}
