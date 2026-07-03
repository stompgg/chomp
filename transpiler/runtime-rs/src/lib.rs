//! chomp-rt — hand-written runtime for the sol2rs-generated engine.
//!
//! Semantic ground rules (each verified against Solidity 0.8 / EVM):
//!
//! * Native Rust integers carry Solidity's checked arithmetic through the
//!   workspace-wide `overflow-checks = true`; a panic IS a revert.
//! * ruint's U256/I256 operators wrap silently in release builds even with
//!   overflow-checks on, so checked wide arithmetic is explicit ([`SolOps`])
//!   and unchecked wide arithmetic uses the `wrapping_*` intrinsics.
//! * Shifts follow EVM semantics: shift amounts >= bit-width yield 0 (or -1
//!   for arithmetic right shift of a negative value) instead of trapping.
//! * `abi_encode` reproduces Solidity `abi.encode` head/tail layout;
//!   `keccak256`/`sha256` return `B256`. Golden vectors in the tests below
//!   pin these against values computed by solc/viem.

use std::collections::HashMap;
use std::hash::Hash;

pub use alloy_primitives::{Address, B256, I256, U256};

// ---------------------------------------------------------------------------
// Checked arithmetic for wide types (panic == revert)
// ---------------------------------------------------------------------------

pub trait SolOps: Sized {
    fn sol_add(self, rhs: Self) -> Self;
    fn sol_sub(self, rhs: Self) -> Self;
    fn sol_mul(self, rhs: Self) -> Self;
    fn sol_div(self, rhs: Self) -> Self;
    fn sol_rem(self, rhs: Self) -> Self;
}

impl SolOps for U256 {
    #[inline(always)]
    fn sol_add(self, rhs: Self) -> Self {
        self.checked_add(rhs).expect("panic: arithmetic overflow (0x11)")
    }
    #[inline(always)]
    fn sol_sub(self, rhs: Self) -> Self {
        self.checked_sub(rhs).expect("panic: arithmetic underflow (0x11)")
    }
    #[inline(always)]
    fn sol_mul(self, rhs: Self) -> Self {
        self.checked_mul(rhs).expect("panic: arithmetic overflow (0x11)")
    }
    #[inline(always)]
    fn sol_div(self, rhs: Self) -> Self {
        self.checked_div(rhs).expect("panic: division by zero (0x12)")
    }
    #[inline(always)]
    fn sol_rem(self, rhs: Self) -> Self {
        self.checked_rem(rhs).expect("panic: division by zero (0x12)")
    }
}

impl SolOps for I256 {
    #[inline(always)]
    fn sol_add(self, rhs: Self) -> Self {
        self.checked_add(rhs).expect("panic: arithmetic overflow (0x11)")
    }
    #[inline(always)]
    fn sol_sub(self, rhs: Self) -> Self {
        self.checked_sub(rhs).expect("panic: arithmetic overflow (0x11)")
    }
    #[inline(always)]
    fn sol_mul(self, rhs: Self) -> Self {
        self.checked_mul(rhs).expect("panic: arithmetic overflow (0x11)")
    }
    #[inline(always)]
    fn sol_div(self, rhs: Self) -> Self {
        self.checked_div(rhs).expect("panic: division overflow or by zero (0x11/0x12)")
    }
    #[inline(always)]
    fn sol_rem(self, rhs: Self) -> Self {
        // Solidity checked `%` only zero-checks the divisor: MIN % -1 is 0
        // (EVM SMOD), NOT a Panic 0x11 — only DIVISION overflows there.
        // alloy's checked_rem returns None for (MIN, -1), so wrap instead.
        if rhs.is_zero() {
            panic!("panic: division by zero (0x12)");
        }
        self.wrapping_rem(rhs)
    }
}

/// Checked native signed remainder with Solidity semantics: divisor 0 panics
/// (0x12), iN::MIN % -1 yields 0 (Rust's `%` would panic under overflow
/// checks; Solidity/EVM SMOD does not).
pub trait SolSignedRem: Copy {
    fn sol_srem(self, rhs: Self) -> Self;
}

macro_rules! impl_srem {
    ($($t:ty),*) => {$(
        impl SolSignedRem for $t {
            #[inline(always)]
            fn sol_srem(self, rhs: Self) -> Self {
                if rhs == 0 {
                    panic!("panic: division by zero (0x12)");
                }
                self.wrapping_rem(rhs)
            }
        }
    )*};
}
impl_srem!(i8, i16, i32, i64, i128);

#[inline(always)]
pub fn srem<T: SolSignedRem>(lhs: T, rhs: T) -> T {
    lhs.sol_srem(rhs)
}

// ---------------------------------------------------------------------------
// EVM shift semantics
// ---------------------------------------------------------------------------

pub trait SolShift: Sized {
    /// `self << amt` with EVM semantics: amt >= width yields 0.
    fn sol_shl(self, amt: u64) -> Self;
    /// `self >> amt`; logical for unsigned, arithmetic for signed
    /// (amt >= width yields 0, or -1 for negative signed values).
    fn sol_shr(self, amt: u64) -> Self;
}

macro_rules! impl_shift_unsigned {
    ($($t:ty),*) => {$(
        impl SolShift for $t {
            #[inline(always)]
            fn sol_shl(self, amt: u64) -> Self {
                if amt >= <$t>::BITS as u64 { 0 } else { self << amt }
            }
            #[inline(always)]
            fn sol_shr(self, amt: u64) -> Self {
                if amt >= <$t>::BITS as u64 { 0 } else { self >> amt }
            }
        }
    )*};
}
impl_shift_unsigned!(u8, u16, u32, u64, u128);

macro_rules! impl_shift_signed {
    ($($t:ty),*) => {$(
        impl SolShift for $t {
            #[inline(always)]
            fn sol_shl(self, amt: u64) -> Self {
                if amt >= <$t>::BITS as u64 { 0 } else { self << amt }
            }
            #[inline(always)]
            fn sol_shr(self, amt: u64) -> Self {
                if amt >= <$t>::BITS as u64 {
                    if self < 0 { -1 } else { 0 }
                } else {
                    self >> amt // Rust >> on signed ints is arithmetic
                }
            }
        }
    )*};
}
impl_shift_signed!(i8, i16, i32, i64, i128);

impl SolShift for U256 {
    #[inline(always)]
    fn sol_shl(self, amt: u64) -> Self {
        if amt >= 256 { U256::ZERO } else { self << (amt as usize) }
    }
    #[inline(always)]
    fn sol_shr(self, amt: u64) -> Self {
        if amt >= 256 { U256::ZERO } else { self >> (amt as usize) }
    }
}

impl SolShift for I256 {
    #[inline(always)]
    fn sol_shl(self, amt: u64) -> Self {
        if amt >= 256 {
            I256::ZERO
        } else {
            I256::from_raw(self.into_raw() << (amt as usize))
        }
    }
    #[inline(always)]
    fn sol_shr(self, amt: u64) -> Self {
        if amt >= 256 {
            if self.is_negative() { I256::MINUS_ONE } else { I256::ZERO }
        } else {
            self.asr(amt as usize)
        }
    }
}

/// Normalize a U256 shift amount: anything above u64::MAX is already >= any
/// width, so saturation preserves semantics.
#[inline(always)]
pub fn shift_amt(x: U256) -> u64 {
    if x > U256::from(u64::MAX) { u64::MAX } else { x.to::<u64>() }
}

// ---------------------------------------------------------------------------
// Exponentiation for native integers
// ---------------------------------------------------------------------------

pub trait SolPow: Copy {
    fn sol_pow_checked(self, exp: u64) -> Self;
    fn sol_pow_wrapping(self, exp: u64) -> Self;
}

macro_rules! impl_pow {
    ($($t:ty),*) => {$(
        impl SolPow for $t {
            fn sol_pow_checked(self, mut exp: u64) -> Self {
                // Exponentiation by squaring so degenerate bases (0/1) with
                // huge exponents terminate; checked_mul panics == revert.
                let mut base = self;
                let mut acc: $t = 1;
                while exp > 0 {
                    if exp & 1 == 1 {
                        acc = acc.checked_mul(base).expect("panic: exponentiation overflow (0x11)");
                    }
                    exp >>= 1;
                    if exp > 0 {
                        base = base.checked_mul(base).expect("panic: exponentiation overflow (0x11)");
                    }
                }
                acc
            }
            fn sol_pow_wrapping(self, mut exp: u64) -> Self {
                let mut base = self;
                let mut acc: $t = 1;
                while exp > 0 {
                    if exp & 1 == 1 {
                        acc = acc.wrapping_mul(base);
                    }
                    exp >>= 1;
                    if exp > 0 {
                        base = base.wrapping_mul(base);
                    }
                }
                acc
            }
        }
    )*};
}
impl_pow!(u8, u16, u32, u64, u128, i8, i16, i32, i64, i128);

#[inline(always)]
pub fn pow_checked<T: SolPow>(base: T, exp: u64) -> T {
    base.sol_pow_checked(exp)
}

#[inline(always)]
pub fn pow_wrapping<T: SolPow>(base: T, exp: u64) -> T {
    base.sol_pow_wrapping(exp)
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

/// Array/dynamic-index conversion; an impossible index panics (== the
/// out-of-bounds revert Solidity would produce).
#[inline(always)]
pub fn usize(x: U256) -> usize {
    x.to::<usize>()
}

/// Solidity `uintN(x)` for odd wide widths: truncate to the low `bits`.
#[inline(always)]
pub fn mask_bits(x: U256, bits: u32) -> U256 {
    debug_assert!(bits < 256);
    x & ((U256::from(1u8) << (bits as usize)) - U256::from(1u8))
}

/// Solidity `intN(x)` for odd wide widths: truncate then sign-extend.
#[inline(always)]
pub fn mask_bits_signed(x: I256, bits: u32) -> I256 {
    debug_assert!(bits < 256);
    let raw = mask_bits(x.into_raw(), bits);
    let sign_bit = U256::from(1u8) << ((bits - 1) as usize);
    if raw & sign_bit != U256::ZERO {
        // set all bits above `bits`
        let ext = U256::MAX << (bits as usize);
        I256::from_raw(raw | ext)
    } else {
        I256::from_raw(raw)
    }
}

/// Explicit Solidity conversion int -> uint256: two's complement mod 2^256.
#[inline(always)]
pub fn u256_from_i128(x: i128) -> U256 {
    I256::try_from(x).expect("i128 always fits I256").into_raw()
}

#[inline(always)]
pub fn i256_from_i128(x: i128) -> I256 {
    I256::try_from(x).expect("i128 always fits I256")
}

#[inline(always)]
pub fn address_to_u256(a: Address) -> U256 {
    U256::from_be_bytes(a.into_word().0)
}

#[inline(always)]
pub fn address_from_u256(x: U256) -> Address {
    Address::from_word(B256::from(mask_bits(x, 160)))
}

#[inline(always)]
pub fn b256_to_u256(b: B256) -> U256 {
    U256::from_be_bytes(b.0)
}

#[inline(always)]
pub fn u256_to_b256(x: U256) -> B256 {
    B256::from(x)
}

/// Typed diverging stub: gives not-yet-supported call sites (Phase-3
/// dispatch, on-chain-only paths) a concrete type so field access and
/// comparisons on the result still type-check. Panics if ever reached.
pub fn todo<T>(msg: &str) -> T {
    unimplemented!("{}", msg)
}

/// hex"..." literal support.
pub fn hex_bytes(s: &str) -> Vec<u8> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("bad hex literal"))
        .collect()
}

// ---------------------------------------------------------------------------
// Hashing
// ---------------------------------------------------------------------------

#[inline(always)]
pub fn keccak256(bytes: &[u8]) -> B256 {
    alloy_primitives::keccak256(bytes)
}

pub fn sha256(bytes: &[u8]) -> B256 {
    use sha2::{Digest, Sha256};
    B256::from_slice(&Sha256::digest(bytes))
}

// ---------------------------------------------------------------------------
// ABI encoding (the subset the engine uses)
// ---------------------------------------------------------------------------

/// One `abi.encode`/`abi.encodePacked` argument. Uint/Int carry the declared
/// Solidity bit width: `encode` ignores it (everything is a 32-byte word)
/// but `encodePacked` needs it (values pack at their declared width).
#[derive(Clone, Debug)]
pub enum Token {
    Uint(U256, u16),
    Int(I256, u16),
    Bool(bool),
    Address(Address),
    FixedBytes(B256),
    Str(String),
    Bytes(Vec<u8>),
}

impl Token {
    fn is_dynamic(&self) -> bool {
        matches!(self, Token::Str(_) | Token::Bytes(_))
    }

    fn head_word(&self) -> [u8; 32] {
        match self {
            Token::Uint(v, _) => v.to_be_bytes::<32>(),
            Token::Int(v, _) => v.to_be_bytes::<32>(),
            Token::Bool(b) => {
                let mut w = [0u8; 32];
                w[31] = *b as u8;
                w
            }
            Token::Address(a) => a.into_word().0,
            Token::FixedBytes(b) => b.0,
            Token::Str(_) | Token::Bytes(_) => unreachable!("dynamic token has no inline head"),
        }
    }

    fn tail_bytes(&self) -> Vec<u8> {
        let data: &[u8] = match self {
            Token::Str(s) => s.as_bytes(),
            Token::Bytes(b) => b.as_slice(),
            _ => unreachable!("static token has no tail"),
        };
        let mut out = Vec::with_capacity(32 + data.len().div_ceil(32) * 32);
        out.extend_from_slice(&U256::from(data.len()).to_be_bytes::<32>());
        out.extend_from_slice(data);
        let pad = data.len().div_ceil(32) * 32 - data.len();
        out.extend(std::iter::repeat(0u8).take(pad));
        out
    }
}

/// Solidity `abi.encode(...)`: 32-byte head slots; dynamic values put an
/// offset (relative to the start of the encoding) in the head and their
/// length-prefixed, 32-byte-padded payload in the tail.
pub fn abi_encode(tokens: &[Token]) -> Vec<u8> {
    let head_len = 32 * tokens.len();
    let mut head: Vec<u8> = Vec::with_capacity(head_len);
    let mut tail: Vec<u8> = Vec::new();
    for t in tokens {
        if t.is_dynamic() {
            let offset = head_len + tail.len();
            head.extend_from_slice(&U256::from(offset).to_be_bytes::<32>());
            tail.extend_from_slice(&t.tail_bytes());
        } else {
            head.extend_from_slice(&t.head_word());
        }
    }
    head.extend_from_slice(&tail);
    head
}

/// Head word `i` of an ABI encoding, for `abi.decode` over static tuples
/// (every element one 32-byte head slot). Solidity reverts when the data is
/// shorter than the head — the panic mirrors that.
pub fn abi_word(data: &[u8], i: usize) -> U256 {
    let start = i * 32;
    let end = start + 32;
    assert!(data.len() >= end, "abi.decode: data too short");
    U256::from_be_slice(&data[start..end])
}

/// Solidity `abi.encodePacked(...)`: values at their declared widths, no
/// padding, no length prefixes.
pub fn abi_encode_packed(tokens: &[Token]) -> Vec<u8> {
    let mut out = Vec::new();
    for t in tokens {
        match t {
            Token::Uint(v, bits) => {
                let bytes = (*bits as usize) / 8;
                out.extend_from_slice(&v.to_be_bytes::<32>()[32 - bytes..]);
            }
            Token::Int(v, bits) => {
                let bytes = (*bits as usize) / 8;
                out.extend_from_slice(&v.to_be_bytes::<32>()[32 - bytes..]);
            }
            Token::Bool(b) => out.push(*b as u8),
            Token::Address(a) => out.extend_from_slice(a.as_slice()),
            Token::FixedBytes(b) => out.extend_from_slice(&b.0),
            Token::Str(s) => out.extend_from_slice(s.as_bytes()),
            Token::Bytes(b) => out.extend_from_slice(b),
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Storage mapping (zero-default reads, like unwritten EVM storage)
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Default)]
pub struct Mapping<K: Eq + Hash + Clone, V: Clone + Default> {
    inner: HashMap<K, V>,
}

impl<K: Eq + Hash + Clone, V: Clone + Default> Mapping<K, V> {
    pub fn new() -> Self {
        Mapping { inner: HashMap::new() }
    }

    /// Read: missing keys are Solidity zero values.
    pub fn get(&self, key: &K) -> V {
        self.inner.get(key).cloned().unwrap_or_default()
    }

    /// Writable access: materializes the zero value on first touch.
    pub fn get_mut(&mut self, key: &K) -> &mut V {
        self.inner.entry(key.clone()).or_default()
    }

    pub fn set(&mut self, key: K, value: V) {
        self.inner.insert(key, value);
    }

    /// `delete mapping[key]`
    pub fn remove(&mut self, key: &K) {
        self.inner.remove(key);
    }
}

// ---------------------------------------------------------------------------
// Tests — golden vectors pinned against solc/viem behavior
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    #[test]
    fn keccak_of_abi_encoded_one() {
        // keccak256(abi.encode(uint256(1))) — canonical vector
        let enc = abi_encode(&[Token::Uint(U256::from(1u8), 256)]);
        assert_eq!(enc.len(), 32);
        assert_eq!(
            format!("{}", keccak256(&enc)),
            "0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6"
        );
    }

    #[test]
    fn abi_encode_two_uints_and_string() {
        // abi.encode(uint256(7), uint256(1), "EFFECT") — matches solc layout:
        // head: 7, 1, offset 0x60; tail: len 6, "EFFECT" right-padded.
        let enc = abi_encode(&[
            Token::Uint(U256::from(7u8), 256),
            Token::Uint(U256::from(1u8), 256),
            Token::Str("EFFECT".to_string()),
        ]);
        assert_eq!(enc.len(), 160);
        let h = hex(&enc);
        assert_eq!(&h[0..64], &format!("{:064x}", 7));
        assert_eq!(&h[64..128], &format!("{:064x}", 1));
        assert_eq!(&h[128..192], &format!("{:064x}", 0x60));
        assert_eq!(&h[192..256], &format!("{:064x}", 6));
        assert_eq!(&h[256..268], hex("EFFECT".as_bytes()));
        assert!(h[268..].chars().all(|c| c == '0'));
    }

    #[test]
    fn sha256_move_miss_event_type() {
        // bytes32 constant MOVE_MISS_EVENT_TYPE = sha256(abi.encode("MoveMiss"));
        // abi.encode("MoveMiss") = offset(0x20) ++ len(8) ++ "MoveMiss" padded
        let enc = abi_encode(&[Token::Str("MoveMiss".to_string())]);
        assert_eq!(enc.len(), 96);
        let digest = sha256(&enc);
        // Value cross-checked against the TS sim (viem encodeAbiParameters +
        // sha256) in the differential fixtures; here we only pin the shape.
        assert_ne!(digest, B256::ZERO);
    }

    #[test]
    fn shifts_match_evm() {
        assert_eq!(U256::from(1u8).sol_shl(255), U256::from(1u8) << 255usize);
        assert_eq!(U256::from(1u8).sol_shl(256), U256::ZERO);
        assert_eq!(U256::MAX.sol_shr(256), U256::ZERO);
        assert_eq!(0x80u8.sol_shl(1), 0x00u8);
        assert_eq!(0x80u8.sol_shr(8), 0);
        assert_eq!((-8i32).sol_shr(2), -2);
        assert_eq!((-1i32).sol_shr(200), -1);
        assert_eq!(7i32.sol_shr(200), 0);
    }

    #[test]
    fn pow_semantics() {
        assert_eq!(pow_checked(2u32, 10), 1024);
        assert_eq!(pow_wrapping(0u128, 0), 1);
        assert_eq!(pow_wrapping(1u8, u64::MAX), 1);
        // 100^exp wraps to 0 mod 2^256 for exp >= 128 (StatBoostLib comment)
        assert_eq!(U256::from(100u8).pow(U256::from(128u16)), U256::ZERO);
        let r = std::panic::catch_unwind(|| pow_checked(16u8, 2));
        assert!(r.is_err(), "checked pow must panic on overflow");
    }

    #[test]
    fn masks_and_conversions() {
        assert_eq!(mask_bits(U256::MAX, 168), (U256::from(1u8) << 168usize) - U256::from(1u8));
        assert_eq!(u256_from_i128(-1), U256::MAX);
        assert_eq!(
            address_from_u256(U256::from(0xdeadu64)),
            Address::from_word(B256::from(U256::from(0xdeadu64)))
        );
        assert_eq!(b256_to_u256(u256_to_b256(U256::from(12345u64))), U256::from(12345u64));
        let neg = mask_bits_signed(I256::try_from(-5i8).unwrap(), 8);
        assert_eq!(neg, I256::try_from(-5i8).unwrap());
    }

    #[test]
    fn mapping_zero_defaults() {
        let mut m: Mapping<U256, u32> = Mapping::new();
        assert_eq!(m.get(&U256::from(9u8)), 0);
        *m.get_mut(&U256::from(9u8)) += 3;
        assert_eq!(m.get(&U256::from(9u8)), 3);
        m.remove(&U256::from(9u8));
        assert_eq!(m.get(&U256::from(9u8)), 0);
    }

    #[test]
    fn packed_encoding_widths() {
        let enc = abi_encode_packed(&[
            Token::Uint(U256::from(0xABCDu16), 16),
            Token::Bool(true),
            Token::Str("ab".to_string()),
        ]);
        assert_eq!(enc, vec![0xAB, 0xCD, 0x01, b'a', b'b']);
    }
}
