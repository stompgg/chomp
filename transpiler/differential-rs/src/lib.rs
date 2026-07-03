//! Vector-file model + helpers for the differential tests.
//!
//! Fixture format (JSON): one file per suite,
//! `{"suite": "<name>", "vectors": [{"inputs": [...], "outputs": [...]} |
//! {"inputs": [...], "reverts": true}, ...]}`.
//! All numbers are decimal strings (bigint-safe on the TS side); bytes32
//! values are 0x-prefixed hex; booleans are JSON bools.

#![allow(non_snake_case)]

use serde::Deserialize;
use std::path::{Path, PathBuf};

pub use chomp_rt::{Address, B256, I256, U256};

pub mod mock_engine;

#[derive(Deserialize, Debug)]
pub struct Suite {
    pub suite: String,
    pub vectors: Vec<Vector>,
}

#[derive(Deserialize, Debug)]
pub struct Vector {
    #[serde(default)]
    pub inputs: Vec<serde_json::Value>,
    #[serde(default)]
    pub outputs: Vec<serde_json::Value>,
    #[serde(default)]
    pub reverts: bool,
    /// Optional human-readable tag for failure messages.
    #[serde(default)]
    pub tag: String,
}

pub fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures")
}

pub fn load_suite(name: &str) -> Suite {
    let path = fixtures_dir().join(format!("{name}.json"));
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read fixture {}: {e}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("cannot parse fixture {}: {e}", path.display()))
}

// ---------------------------------------------------------------------------
// Value decoding helpers
// ---------------------------------------------------------------------------

pub fn as_u256(v: &serde_json::Value) -> U256 {
    match v {
        serde_json::Value::String(s) => {
            if let Some(hexs) = s.strip_prefix("0x") {
                U256::from_str_radix(hexs, 16).expect("bad hex u256")
            } else {
                U256::from_str_radix(s, 10).expect("bad dec u256")
            }
        }
        serde_json::Value::Number(n) => U256::from(n.as_u64().expect("number too big for JSON")),
        _ => panic!("expected numeric value, got {v:?}"),
    }
}

pub fn as_i256(v: &serde_json::Value) -> I256 {
    match v {
        serde_json::Value::String(s) => {
            let (neg, digits) = match s.strip_prefix('-') {
                Some(d) => (true, d),
                None => (false, s.as_str()),
            };
            let mag = U256::from_str_radix(digits, 10).expect("bad dec i256");
            let val = I256::try_from(mag).expect("i256 magnitude overflow");
            if neg { -val } else { val }
        }
        serde_json::Value::Number(n) => {
            I256::try_from(n.as_i64().expect("number too big for JSON")).unwrap()
        }
        _ => panic!("expected numeric value, got {v:?}"),
    }
}

pub fn as_u64(v: &serde_json::Value) -> u64 {
    as_u256(v).to::<u64>()
}

pub fn as_u32(v: &serde_json::Value) -> u32 {
    as_u256(v).to::<u32>()
}

pub fn as_u8(v: &serde_json::Value) -> u8 {
    as_u256(v).to::<u8>()
}

pub fn as_i32(v: &serde_json::Value) -> i32 {
    i32::try_from(as_i256(v)).expect("i32 overflow in fixture")
}

pub fn as_bool(v: &serde_json::Value) -> bool {
    v.as_bool().expect("expected bool")
}

pub fn as_b256(v: &serde_json::Value) -> B256 {
    let s = v.as_str().expect("expected hex string");
    let hexs = s.strip_prefix("0x").expect("bytes32 must be 0x-prefixed");
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&hexs[2 * i..2 * i + 2], 16).expect("bad bytes32 hex");
    }
    B256::new(out)
}

pub fn as_address(v: &serde_json::Value) -> Address {
    let s = v.as_str().expect("expected address hex string");
    let hexs = s.strip_prefix("0x").expect("address must be 0x-prefixed");
    let mut out = [0u8; 20];
    for i in 0..20 {
        out[i] = u8::from_str_radix(&hexs[2 * i..2 * i + 2], 16).expect("bad address hex");
    }
    Address::new(out)
}

/// Run one vector body catching panics, asserting revert expectations.
/// (AssertUnwindSafe: bodies only touch per-vector state that is discarded
/// on panic, so unwind safety is not a correctness concern here.)
pub fn run_vector<F: FnOnce()>(suite: &str, index: usize, vector: &Vector, body: F) {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(body));
    match (vector.reverts, result) {
        (false, Ok(())) => {}
        (true, Err(_)) => {}
        (false, Err(e)) => panic!(
            "{suite}[{index}]{}: engine panicked but oracle did not: {e:?}",
            tag(vector)
        ),
        (true, Ok(())) => panic!(
            "{suite}[{index}]{}: oracle reverted but engine did not",
            tag(vector)
        ),
    }
}

fn tag(v: &Vector) -> String {
    if v.tag.is_empty() { String::new() } else { format!(" ({})", v.tag) }
}
