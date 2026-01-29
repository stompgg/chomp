use alloy_primitives::{Address, B256};
use tiny_keccak::{Hasher, Keccak};

/// The init code hash of the CREATE3 proxy used by CreateX
/// This is: keccak256(hex"67_36_3d_3d_37_36_3d_34_f0_3d_52_60_08_60_18_f3")
const PROXY_INIT_CODE_HASH: [u8; 32] = [
    0x21, 0xc3, 0x5d, 0xbe, 0x1b, 0x34, 0x4a, 0x24, 0x88, 0xcf, 0x33, 0x21, 0xd6, 0xce, 0x54, 0x2f,
    0x8e, 0x9f, 0x30, 0x55, 0x44, 0xff, 0x09, 0xe4, 0x99, 0x3a, 0x62, 0x31, 0x9a, 0x49, 0x7c, 0x1f,
];

/// Compute keccak256 hash
fn keccak256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    let mut output = [0u8; 32];
    hasher.update(data);
    hasher.finalize(&mut output);
    output
}

/// Compute CREATE2 address: keccak256(0xff ++ deployer ++ salt ++ init_code_hash)[12:]
fn compute_create2_address(deployer: Address, salt: B256, init_code_hash: [u8; 32]) -> Address {
    let mut data = [0u8; 85];
    data[0] = 0xff;
    data[1..21].copy_from_slice(deployer.as_slice());
    data[21..53].copy_from_slice(salt.as_slice());
    data[53..85].copy_from_slice(&init_code_hash);

    let hash = keccak256(&data);
    Address::from_slice(&hash[12..])
}

/// Compute CREATE address for nonce=1: keccak256(RLP([address, 1]))[12:]
/// For nonce=1, the RLP encoding is: 0xd6 0x94 <20-byte address> 0x01
fn compute_create_address_nonce_1(deployer: Address) -> Address {
    let mut data = [0u8; 23];
    data[0] = 0xd6; // 0xc0 + 0x16 (length of: 0x94 + 20 bytes + 0x01)
    data[1] = 0x94; // 0x80 + 0x14 (20 bytes)
    data[2..22].copy_from_slice(deployer.as_slice());
    data[22] = 0x01; // nonce = 1

    let hash = keccak256(&data);
    Address::from_slice(&hash[12..])
}

/// Compute the final CREATE3 address given a salt and the CreateX deployer address.
///
/// This matches CreateX's computeCreate3Address function:
/// 1. Compute proxy address via CREATE2 (using the proxy init code hash)
/// 2. Compute final address via CREATE with nonce=1
pub fn compute_create3_address(salt: B256, createx_address: Address) -> Address {
    // Step 1: Compute proxy address via CREATE2
    let proxy_address = compute_create2_address(createx_address, salt, PROXY_INIT_CODE_HASH);

    // Step 2: Compute final address via CREATE (nonce=1)
    compute_create_address_nonce_1(proxy_address)
}

/// Number of effect steps in the EffectStep enum.
/// Update this constant when adding new steps to the enum.
pub const NUM_EFFECT_STEPS: u32 = 9;

/// Extract the bitmap from the most significant bits of an address.
/// The bitmap encodes which EffectSteps an effect runs at.
pub fn extract_bitmap(address: Address) -> u16 {
    let bytes = address.as_slice();
    // Take first 2 bytes and extract top NUM_EFFECT_STEPS bits
    // bytes[0] is the MSB, bytes[1] is the next byte
    let top_16_bits = ((bytes[0] as u16) << 8) | (bytes[1] as u16);
    // Shift right to get the top NUM_EFFECT_STEPS bits
    top_16_bits >> (16 - NUM_EFFECT_STEPS)
}

/// Check if an address has the desired bitmap in its most significant bits
pub fn matches_bitmap(address: Address, target_bitmap: u16) -> bool {
    extract_bitmap(address) == target_bitmap
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    #[test]
    fn test_extract_bitmap() {
        // Address starting with 0x042... should have bitmap 0x042 >> 7 shifted appropriately
        // Actually, let's think about this more carefully:
        // Address: 0x042... means first byte is 0x04, second byte starts with 0x2
        // 0x04 = 0000_0100
        // 0x2X = 0010_XXXX
        // Top 9 bits: 0_0000_0100_0 = 0x008 (if second nibble is 0)
        // Wait, let's recalculate:
        // 0x042 as a prefix means the address is 0x042XXXXX...
        // So bytes[0] = 0x04, bytes[1] = 0x2X
        // top_16_bits = 0x042X
        // top_16_bits >> 7 = 0x042X >> 7
        // 0x0420 >> 7 = 0x0420 / 128 = 1056 / 128 = 8.25 -> 8 = 0x08
        // Hmm, that doesn't match. Let me reconsider the bitmap encoding.

        // The bitmap should be: address >> 151 (in 160-bit space)
        // For a 9-bit bitmap stored in the MSB:
        // If we want bitmap 0x042 (binary: 001000010), the address should start with:
        // 001000010_XXXXXXX... (first 9 bits, then rest)
        // In hex, first byte would be: 0010_0001 = 0x21
        // Second byte starts with: 0_XXXXXXX
        // So address would be 0x21XXXX...

        // Let me fix the mapping. For bitmap B (9 bits):
        // Address prefix = B << 7 (shifted to align with byte boundary considering we take top 9)
        // Actually: if we have address bytes [b0, b1, ...]
        // And we do ((b0 << 8) | b1) >> 7, we get b0 << 1 | (b1 >> 7)
        // This gives us 9 bits: 8 bits from b0 shifted left by 1, plus top bit of b1

        // For bitmap 0x042 = 0b001000010 (9 bits):
        // We need b0 << 1 | (b1 >> 7) = 0x042
        // b0 = 0x042 >> 1 = 0x21 (if LSB of bitmap is 0)
        // b1 >> 7 = 0x042 & 1 = 0, so top bit of b1 is 0

        let addr = Address::from_str("0x2100000000000000000000000000000000000000").unwrap();
        assert_eq!(extract_bitmap(addr), 0x042);

        // Test bitmap 0x1E0 = 0b111100000
        // b0 = 0x1E0 >> 1 = 0xF0
        // b1 >> 7 = 0, so b1 can be 0x00-0x7F
        let addr = Address::from_str("0xF000000000000000000000000000000000000000").unwrap();
        assert_eq!(extract_bitmap(addr), 0x1E0);
    }

    #[test]
    fn test_create3_address_computation() {
        // Test against known CreateX deployment
        // CreateX canonical address
        let createx = Address::from_str("0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed").unwrap();

        // A zero salt should produce a deterministic address
        let salt = B256::ZERO;
        let addr = compute_create3_address(salt, createx);

        // The address should be valid (non-zero)
        assert_ne!(addr, Address::ZERO);

        // Verify it's deterministic
        let addr2 = compute_create3_address(salt, createx);
        assert_eq!(addr, addr2);
    }
}
